import CryptoKit
import Foundation

struct ClaudeStatusLineRateLimits: Sendable, Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let harvestedAt: Date
}

struct CredentialStore: Sendable {
    private struct ClaudeStatusLineSample: Decodable, Sendable {
        let accountSlot: Int
        let fiveHourUsed: Double
        let sevenDayUsed: Double
        let fiveHourResetsAt: TimeInterval
        let sevenDayResetsAt: TimeInterval
        let harvestedAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case accountSlot = "acct"
            case fiveHourUsed = "five_hour_used"
            case sevenDayUsed = "seven_day_used"
            case fiveHourResetsAt = "five_hour_resets_at"
            case sevenDayResetsAt = "seven_day_resets_at"
            case harvestedAt = "ts"
        }
    }

    private struct CodexEnvelope: Decodable {
        struct Tokens: Decodable {
            let accessToken: String
            let accountID: String
            let idToken: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountID = "account_id"
                case idToken = "id_token"
            }
        }

        let tokens: Tokens
    }

    private static let statusLineSnapshotLifetime: TimeInterval = 60 * 60
    private let claudeRateLimitsDirectory: URL
    private let claudeBackupsDirectoryOverride: URL?

    init(
        claudeRateLimitsDirectory: URL = URL(
            fileURLWithPath: "/tmp/cc-rate-limits",
            isDirectory: true
        ),
        claudeBackupsDirectory: URL? = nil
    ) {
        self.claudeRateLimitsDirectory = claudeRateLimitsDirectory
        claudeBackupsDirectoryOverride = claudeBackupsDirectory
    }

    func load(_ slot: AccountSlot) -> LoadedCredential {
        switch slot.provider {
        case .claude:
            return loadClaude(slot)
        case .codex:
            return loadCodex(slot)
        }
    }

    func cachedClaudeSnapshot(
        for slot: AccountSlot,
        identity: LocalIdentity,
        detail: String? = nil
    ) -> AccountSnapshot? {
        guard let url = claudeStateURL(for: slot) else { return nil }

        guard
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cached = root["cachedUsageUtilization"] as? [String: Any],
            let utilization = cached["utilization"] as? [String: Any]
        else {
            return nil
        }
        let stateModifiedAt = (
            try? url.resourceValues(forKeys: [.contentModificationDateKey])
        )?.contentModificationDate

        let account = root["oauthAccount"] as? [String: Any]
        let registryIdentity = LocalIdentity(
            email: account?["emailAddress"] as? String ?? identity.email ?? slot.configuredEmail,
            displayName: account?["displayName"] as? String ?? identity.displayName,
            organizationName: account?["organizationName"] as? String ?? identity.organizationName
        )
        let plan = claudePlan(from: account)

        guard cacheMatchesClaudeIdentity(root: root, cached: cached) else {
            return AccountSnapshot.quotaUnavailable(
                slot,
                identity: registryIdentity.preferredDisplay ?? slot.localLabel,
                plan: plan,
                detail: "This signed-in account has no matching local quota snapshot. A cache belonging to another account was ignored."
            )
        }

        var windows: [UsageWindow] = []
        if let fiveHour = usageWindow(from: utilization["five_hour"], id: "five-hour", title: "5-hour") {
            windows.append(fiveHour)
        }
        if let sevenDay = usageWindow(from: utilization["seven_day"], id: "seven-day", title: "7-day") {
            windows.append(sevenDay)
        }
        guard !windows.isEmpty else { return nil }
        let fableUsage = fableUsageWindow(from: utilization)

        let cachedFetchedAt: Date?
        if let milliseconds = cached["fetchedAtMs"] as? Double {
            cachedFetchedAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        } else {
            cachedFetchedAt = nil
        }
        var fetchedAt = cachedFetchedAt
        var snapshotDetail = detail
        if
            let stateModifiedAt,
            let statusLine = localClaudeRateLimits(
                for: slot,
                stateModifiedAt: stateModifiedAt,
                currentAccountID: account?["accountUuid"] as? String
            )
        {
            windows = mergeClaudeWindows(
                cached: windows,
                statusLine: statusLine
            )
            fetchedAt = statusLine.harvestedAt
            snapshotDetail = "Claude Code status-line quota snapshot"
        } else if hasFreshClaudeRateLimitCandidate(for: slot) {
            return AccountSnapshot.quotaUnavailable(
                slot,
                identity: registryIdentity.preferredDisplay ?? slot.localLabel,
                plan: plan,
                detail: "A fresh local quota sample exists, but its account association could not be proven. Older cached percentages were not shown."
            )
        } else if
            let stateModifiedAt,
            let historicalStatusLine = localClaudeRateLimits(
                for: slot,
                stateModifiedAt: stateModifiedAt,
                currentAccountID: account?["accountUuid"] as? String,
                maximumAge: nil
            ),
            historicalStatusLine.harvestedAt > (cachedFetchedAt ?? .distantPast)
        {
            let merged = mergeClaudeWindows(
                cached: windows,
                statusLine: historicalStatusLine,
                requireMonotonicActiveWindow: true
            )
            if merged != windows {
                windows = merged
                fetchedAt = historicalStatusLine.harvestedAt
                snapshotDetail = "5-hour/7-day snapshot · \(snapshotAge(historicalStatusLine.harvestedAt)) old"
            }
        }

        if
            snapshotDetail == nil,
            let fetchedAt,
            Date().timeIntervalSince(fetchedAt) > Self.statusLineSnapshotLifetime
        {
            snapshotDetail = "Local quota snapshot · \(snapshotAge(fetchedAt)) old"
        }

        let providerAccountID = (account?["accountUuid"] as? String)
            ?? (cached["accountUuid"] as? String)

        return AccountSnapshot(
            id: slot.id,
            slot: slot,
            identity: registryIdentity.preferredDisplay ?? slot.localLabel,
            plan: plan,
            state: .cached,
            windows: windows,
            fableUsage: fableUsage,
            providerAccountID: providerAccountID,
            detail: snapshotDetail,
            refreshedAt: fetchedAt,
            duplicatePeer: nil
        )
    }

    private func loadClaude(_ slot: AccountSlot) -> LoadedCredential {
        let identity = readClaudeIdentity(slot)
        return .failed(
            slot,
            identity,
            "This signed-in account has no local quota snapshot yet."
        )
    }

    private func loadCodex(_ slot: AccountSlot) -> LoadedCredential {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let envelope = try JSONDecoder().decode(CodexEnvelope.self, from: data)
            guard !envelope.tokens.accessToken.isEmpty, !envelope.tokens.accountID.isEmpty else {
                return .failed(slot, nil, "The Codex session is incomplete.")
            }

            let claims = envelope.tokens.idToken.flatMap(jwtClaims)
            let email = claims?["email"] as? String
            let displayName = claims?["name"] as? String
            let identity = LocalIdentity(
                email: email,
                displayName: displayName,
                organizationName: nil
            )

            return .codex(
                slot,
                CodexCredential(
                    accessToken: envelope.tokens.accessToken,
                    accountID: envelope.tokens.accountID,
                    identity: identity
                )
            )
        } catch CocoaError.fileReadNoSuchFile {
            return .failed(slot, nil, "No local Codex sign-in was found.")
        } catch {
            return .failed(slot, nil, "The local Codex session could not be read.")
        }
    }

    private func readClaudeIdentity(_ slot: AccountSlot) -> LocalIdentity {
        guard let url = claudeStateURL(for: slot) else {
            return LocalIdentity(email: slot.configuredEmail, displayName: nil, organizationName: nil)
        }

        guard
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = root["oauthAccount"] as? [String: Any]
        else {
            return LocalIdentity(email: slot.configuredEmail, displayName: nil, organizationName: nil)
        }

        let email = account["emailAddress"] as? String
        return LocalIdentity(
            email: email ?? slot.configuredEmail,
            displayName: account["displayName"] as? String,
            organizationName: account["organizationName"] as? String
        )
    }

    func claudeStateURL(for slot: AccountSlot) -> URL? {
        guard let relativePath = slot.claudeStatePath else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativePath)
    }

    func cacheMatchesClaudeIdentity(
        root: [String: Any],
        cached: [String: Any]
    ) -> Bool {
        guard
            let account = root["oauthAccount"] as? [String: Any],
            let registryID = account["accountUuid"] as? String,
            !registryID.isEmpty,
            let cachedID = cached["accountUuid"] as? String,
            !cachedID.isEmpty
        else {
            return true
        }
        return registryID == cachedID
    }

    func localClaudeRateLimits(
        for slot: AccountSlot,
        stateModifiedAt: Date,
        currentAccountID: String? = nil,
        maximumAge: TimeInterval? = Self.statusLineSnapshotLifetime,
        now: Date = Date()
    ) -> ClaudeStatusLineRateLimits? {
        guard slot.provider == .claude else { return nil }
        let expectedSlot = slot.position + 1
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: claudeRateLimitsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        let decoder = JSONDecoder()
        let samples = files.compactMap { file -> ClaudeStatusLineSample? in
            let expectedPrefix = "acct-\(expectedSlot)."
            guard
                file.lastPathComponent.hasPrefix(expectedPrefix),
                file.pathExtension == "json",
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true,
                let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
                let sample = try? decoder.decode(
                    ClaudeStatusLineSample.self,
                    from: data
                ),
                sample.accountSlot == expectedSlot,
                (0...100).contains(sample.fiveHourUsed),
                (0...100).contains(sample.sevenDayUsed)
            else {
                return nil
            }

            let harvestedAt = Date(timeIntervalSince1970: sample.harvestedAt)
            let age = now.timeIntervalSince(harvestedAt)
            guard
                age >= -60,
                maximumAge.map({ age <= $0 }) ?? true,
                harvestedAt >= stateModifiedAt
                    || registryIdentityWasContinuous(
                        for: slot,
                        currentAccountID: currentAccountID,
                        from: harvestedAt,
                        through: stateModifiedAt
                    )
            else {
                return nil
            }
            return sample
        }

        let fiveHour = selectStatusLineWindow(
            samples: samples,
            used: \.fiveHourUsed,
            reset: \.fiveHourResetsAt,
            id: "five-hour",
            title: "5-hour",
            now: now
        )
        let sevenDay = selectStatusLineWindow(
            samples: samples,
            used: \.sevenDayUsed,
            reset: \.sevenDayResetsAt,
            id: "seven-day",
            title: "7-day",
            now: now
        )
        guard fiveHour != nil || sevenDay != nil else { return nil }

        let harvestedAt = samples
            .map { Date(timeIntervalSince1970: $0.harvestedAt) }
            .max() ?? now
        return ClaudeStatusLineRateLimits(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            harvestedAt: harvestedAt
        )
    }

    func hasFreshClaudeRateLimitCandidate(
        for slot: AccountSlot,
        now: Date = Date()
    ) -> Bool {
        guard slot.provider == .claude else { return false }
        let expectedSlot = slot.position + 1
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: claudeRateLimitsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return false
        }
        let decoder = JSONDecoder()
        return files.contains { file in
            let expectedPrefix = "acct-\(expectedSlot)."
            guard
                file.lastPathComponent.hasPrefix(expectedPrefix),
                file.pathExtension == "json",
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true,
                let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
                let sample = try? decoder.decode(
                    ClaudeStatusLineSample.self,
                    from: data
                ),
                sample.accountSlot == expectedSlot,
                (0...100).contains(sample.fiveHourUsed),
                (0...100).contains(sample.sevenDayUsed)
            else {
                return false
            }
            let harvestedAt = Date(timeIntervalSince1970: sample.harvestedAt)
            let age = now.timeIntervalSince(harvestedAt)
            let hasActiveWindow =
                Date(timeIntervalSince1970: sample.fiveHourResetsAt) > now
                || Date(timeIntervalSince1970: sample.sevenDayResetsAt) > now
            return age >= -60
                && age <= Self.statusLineSnapshotLifetime
                && hasActiveWindow
        }
    }

    private func registryIdentityWasContinuous(
        for slot: AccountSlot,
        currentAccountID: String?,
        from harvestedAt: Date,
        through stateModifiedAt: Date
    ) -> Bool {
        guard
            let currentAccountID,
            !currentAccountID.isEmpty,
            let backupsDirectory = claudeBackupsURL(for: slot),
            let files = try? FileManager.default.contentsOfDirectory(
                at: backupsDirectory,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey,
                ],
                options: []
            )
        else {
            return false
        }

        var observations: [(date: Date, accountID: String)] = []
        for file in files
        where file.lastPathComponent.hasPrefix(".claude.json.backup.") {
            guard
                let values = try? file.resourceValues(
                    forKeys: [
                        .contentModificationDateKey,
                        .isRegularFileKey,
                    ]
                ),
                values.isRegularFile == true,
                let modifiedAt = values.contentModificationDate,
                modifiedAt <= stateModifiedAt,
                let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
                let root = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let account = root["oauthAccount"] as? [String: Any],
                let accountID = account["accountUuid"] as? String,
                !accountID.isEmpty
            else {
                continue
            }
            observations.append((modifiedAt, accountID))
        }

        guard
            let preceding = observations
                .filter({ $0.date <= harvestedAt })
                .max(by: { $0.date < $1.date }),
            preceding.accountID == currentAccountID
        else {
            return false
        }
        return observations
            .filter { $0.date > harvestedAt }
            .allSatisfy { $0.accountID == currentAccountID }
    }

    private func claudeBackupsURL(for slot: AccountSlot) -> URL? {
        if let claudeBackupsDirectoryOverride {
            return claudeBackupsDirectoryOverride
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if slot.position == 0 {
            return home
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("backups", isDirectory: true)
        }
        guard let stateURL = claudeStateURL(for: slot) else { return nil }
        return stateURL
            .deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
    }

    private func selectStatusLineWindow(
        samples: [ClaudeStatusLineSample],
        used: KeyPath<ClaudeStatusLineSample, Double>,
        reset: KeyPath<ClaudeStatusLineSample, TimeInterval>,
        id: String,
        title: String,
        now: Date
    ) -> UsageWindow? {
        let active = samples.filter {
            Date(timeIntervalSince1970: $0[keyPath: reset]) > now
        }
        guard
            let latestReset = active.map({ $0[keyPath: reset] }).max()
        else {
            return nil
        }

        let currentWindow = active.filter {
            abs($0[keyPath: reset] - latestReset) < 1
        }
        guard
            let selected = currentWindow.max(by: {
                let left = $0[keyPath: used]
                let right = $1[keyPath: used]
                if left != right { return left < right }
                return $0.harvestedAt < $1.harvestedAt
            })
        else {
            return nil
        }

        return UsageWindow(
            id: id,
            title: title,
            usedPercent: selected[keyPath: used],
            resetAt: Date(timeIntervalSince1970: selected[keyPath: reset])
        )
    }

    func mergeClaudeWindows(
        cached: [UsageWindow],
        statusLine: ClaudeStatusLineRateLimits,
        requireMonotonicActiveWindow: Bool = false
    ) -> [UsageWindow] {
        var byID = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
        if let fiveHour = statusLine.fiveHour {
            byID[fiveHour.id] = preferredClaudeWindow(
                cached: byID[fiveHour.id],
                observed: fiveHour,
                requireMonotonicActiveWindow: requireMonotonicActiveWindow
            )
        }
        if let sevenDay = statusLine.sevenDay {
            byID[sevenDay.id] = preferredClaudeWindow(
                cached: byID[sevenDay.id],
                observed: sevenDay,
                requireMonotonicActiveWindow: requireMonotonicActiveWindow
            )
        }
        return ["five-hour", "seven-day"].compactMap { byID[$0] }
    }

    private func preferredClaudeWindow(
        cached: UsageWindow?,
        observed: UsageWindow,
        requireMonotonicActiveWindow: Bool
    ) -> UsageWindow {
        guard
            requireMonotonicActiveWindow,
            let cached,
            let cachedReset = cached.resetAt,
            let observedReset = observed.resetAt
        else {
            return observed
        }

        let resetTolerance: TimeInterval = 2
        if observedReset < cachedReset.addingTimeInterval(-resetTolerance) {
            return cached
        }
        let sameWindow =
            abs(observedReset.timeIntervalSince(cachedReset)) <= resetTolerance
        if sameWindow,
           observed.normalizedUsedPercent < cached.normalizedUsedPercent {
            return cached
        }
        return observed
    }

    private func snapshotAge(_ capturedAt: Date, now: Date = Date()) -> String {
        let totalMinutes = max(
            0,
            Int(now.timeIntervalSince(capturedAt) / 60)
        )
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func claudePlan(from account: [String: Any]?) -> String {
        guard let organizationType = account?["organizationType"] as? String else {
            return "Claude"
        }
        return organizationType
            .replacingOccurrences(of: "claude_", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func usageWindow(from raw: Any?, id: String, title: String) -> UsageWindow? {
        guard let object = raw as? [String: Any], let used = object["utilization"] as? Double else {
            return nil
        }
        let resetAt = (object["resets_at"] as? String).flatMap(Self.parseISO8601)
        return UsageWindow(id: id, title: title, usedPercent: used, resetAt: resetAt)
    }

    func fableUsageWindow(from utilization: [String: Any]) -> UsageWindow? {
        guard let limits = utilization["limits"] as? [[String: Any]] else {
            return nil
        }

        let candidates = limits.filter { limit in
            guard
                (limit["kind"] as? String) == "weekly_scoped",
                let scope = limit["scope"] as? [String: Any],
                let model = scope["model"] as? [String: Any],
                let displayName = model["display_name"] as? String
            else {
                return false
            }
            return displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Fable") == .orderedSame
        }

        let selected = candidates.first { $0["is_active"] as? Bool == true }
            ?? candidates.first
        guard let selected, let percent = number(selected["percent"]) else {
            return nil
        }

        return UsageWindow(
            id: "fable-weekly",
            title: "Fable usage",
            usedPercent: percent,
            resetAt: (selected["resets_at"] as? String).flatMap(Self.parseISO8601)
        )
    }

    private func number(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }

    private func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        guard
            let data = Data(base64Encoded: encoded),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    static func stableIdentifier(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(5).map { String(format: "%02x", $0) }.joined()
    }

    static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }
}
