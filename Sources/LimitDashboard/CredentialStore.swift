import CryptoKit
import Foundation
import Security

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

    /// A status-line harvest is rewritten every few seconds while a session is
    /// rendering, so a sample this recent is the provider's current state.
    static let statusLineLiveWindow: TimeInterval = 5 * 60
    static let statusLineSnapshotLifetime: TimeInterval = 60 * 60
    /// How long to wait for Claude Code's renewal to reach the Keychain after
    /// `auth status` has already exited.
    static let renewalSettleWindow: TimeInterval = 8
    /// Claude Code refuses to renew a credential that has already expired — a
    /// cold start gates on validity and answers "Not logged in" without ever
    /// attempting the exchange. The only reliable moment to renew is therefore
    /// shortly *before* expiry, while the stored session is still accepted.
    static let proactiveRenewalMargin: TimeInterval = 15 * 60
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
        detail: String? = nil,
        note: String? = nil,
        now: Date = Date()
    ) -> AccountSnapshot? {
        guard let url = claudeStateURL(for: slot) else { return nil }

        guard
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        // Claude Code deletes this block whenever it considers itself signed
        // out, so its absence must not silence the status-line harvest — that
        // source keeps reporting as long as any session is running.
        let cached = root["cachedUsageUtilization"] as? [String: Any]
        let utilization = cached?["utilization"] as? [String: Any] ?? [:]
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

        if let cached, !cacheMatchesClaudeIdentity(root: root, cached: cached) {
            return AccountSnapshot.quotaUnavailable(
                slot,
                identity: registryIdentity.preferredDisplay ?? slot.localLabel,
                plan: plan,
                detail: "This signed-in account has no matching local quota snapshot. A cache belonging to another account was ignored."
            )
        }

        let cachedFetchedAt: Date?
        if let milliseconds = cached?["fetchedAtMs"] as? Double {
            cachedFetchedAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        } else {
            cachedFetchedAt = nil
        }

        var windows: [UsageWindow] = []
        if let fiveHour = usageWindow(
            from: utilization["five_hour"],
            id: "five-hour",
            title: "5-hour",
            sourceFetchedAt: cachedFetchedAt,
            now: now
        ) {
            windows.append(fiveHour)
        }
        if let sevenDay = usageWindow(
            from: utilization["seven_day"],
            id: "seven-day",
            title: "7-day",
            sourceFetchedAt: cachedFetchedAt,
            now: now
        ) {
            windows.append(sevenDay)
        }
        let fableUsage = fableUsageWindow(
            from: utilization,
            sourceFetchedAt: cachedFetchedAt,
            now: now
        )

        var fetchedAt = cachedFetchedAt
        var sourceName = "Local quota snapshot"
        let currentAccountID = account?["accountUuid"] as? String
        if
            let stateModifiedAt,
            let statusLine = localClaudeRateLimits(
                for: slot,
                stateModifiedAt: stateModifiedAt,
                currentAccountID: currentAccountID,
                now: now
            )
        {
            windows = mergeClaudeWindows(
                cached: windows,
                statusLine: statusLine
            )
            fetchedAt = statusLine.harvestedAt
            sourceName = "Claude Code status line"
        } else if
            let stateModifiedAt,
            let historicalStatusLine = localClaudeRateLimits(
                for: slot,
                stateModifiedAt: stateModifiedAt,
                currentAccountID: currentAccountID,
                maximumAge: nil,
                now: now
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
                sourceName = "Claude Code status line"
            }
        } else if hasFreshClaudeRateLimitCandidate(for: slot, now: now) {
            // A recent sample exists for this slot but the registry proves it
            // belonged to a different account, so neither it nor the cache it
            // would have replaced can be attributed to the account shown here.
            return AccountSnapshot.quotaUnavailable(
                slot,
                identity: registryIdentity.preferredDisplay ?? slot.localLabel,
                plan: plan,
                detail: "A recent local quota sample belongs to a different account. Cached percentages were not shown."
            )
        }

        guard !windows.isEmpty else {
            return AccountSnapshot.quotaUnavailable(
                slot,
                identity: registryIdentity.preferredDisplay ?? slot.localLabel,
                plan: plan,
                detail: "Every known quota window for this account has reset. Waiting for a new snapshot.",
                refreshedAt: fetchedAt
            )
        }

        let snapshotState = claudeSnapshotState(
            fetchedAt: fetchedAt,
            now: now
        )

        let baseDetail: String = if let detail {
            detail
        } else if let fetchedAt {
            switch snapshotState {
            case .live:
                "\(sourceName) · current"
            default:
                "\(sourceName) · read \(snapshotAge(fetchedAt, now: now)) ago"
            }
        } else {
            "\(sourceName) · source time unavailable"
        }
        // The note explains why the live provider reading was unavailable, so an
        // aged card says what to do about it instead of only how old it is.
        let snapshotDetail = note.map { "\(baseDetail) · \($0)" } ?? baseDetail

        let providerAccountID = (account?["accountUuid"] as? String)
            ?? (cached?["accountUuid"] as? String)

        return AccountSnapshot(
            id: slot.id,
            slot: slot,
            identity: registryIdentity.preferredDisplay ?? slot.localLabel,
            plan: plan,
            state: snapshotState,
            windows: windows,
            fableUsage: fableUsage,
            providerAccountID: providerAccountID,
            detail: snapshotDetail,
            refreshedAt: fetchedAt,
            duplicatePeer: nil
        )
    }

    /// Whether to query Claude's usage endpoint directly.
    ///
    /// Off by default. When enabled, the provider layer uses the bounded
    /// curl_cffi transport bundled with the app. While disabled the app reads no
    /// Claude Keychain item and makes no Claude request; the status-line harvest
    /// remains the best available source.
    static var claudeProviderQueriesEnabled: Bool {
        ProcessInfo.processInfo.environment["LIMIT_DASHBOARD_CLAUDE_API"] == "1"
    }

    private func loadClaude(
        _ slot: AccountSlot,
        now: Date = Date()
    ) -> LoadedCredential {
        let identity = readClaudeIdentity(slot)
        guard Self.claudeProviderQueriesEnabled else {
            return .failed(
                slot,
                identity,
                "This signed-in account has no local quota snapshot yet."
            )
        }
        guard let credential = claudeKeychainCredential(for: slot, identity: identity) else {
            return .failed(
                slot,
                identity,
                "no stored session to query the provider with"
            )
        }
        if credential.isUsable(now: now) {
            // Renew while renewal is still possible: once this token expires,
            // no cold-started helper can bring it back, and the dashboard is
            // left waiting for the user to open the account by hand.
            if
                let expiresAt = credential.expiresAt,
                expiresAt.timeIntervalSince(now) < Self.proactiveRenewalMargin,
                renewClaudeSession(for: slot, currentExpiry: expiresAt),
                let renewed = claudeKeychainCredential(for: slot, identity: identity),
                renewed.isUsable(now: now)
            {
                return .claude(slot, renewed)
            }
            return .claude(slot, credential)
        }

        // The reading may simply be the memoised copy from before Claude Code
        // renewed — using this account renews it, and that write is invisible
        // until the remembered copy is dropped. Re-read once against the
        // Keychain before concluding anything is wrong.
        if let configDirectory = claudeConfigDirectory(for: slot) {
            KeychainCache.shared.invalidate(
                Self.claudeKeychainService(forConfigDirectory: configDirectory)
            )
            if
                let current = claudeKeychainCredential(for: slot, identity: identity),
                current.isUsable(now: now)
            {
                return .claude(slot, current)
            }
        }

        // The token has expired. Claude Code is asked anyway — today's CLI
        // refuses this case, but the attempt is free and a future version may
        // handle it — and letting the tool that owns the credential renew it
        // keeps this app out of the write path entirely.
        if
            renewClaudeSession(for: slot, currentExpiry: credential.expiresAt),
            let renewed = claudeKeychainCredential(for: slot, identity: identity),
            renewed.isUsable(now: now)
        {
            return .claude(slot, renewed)
        }

        // This app does not exchange the refresh token.
        //
        // It did once, under the same lock Claude Code uses and with write-back,
        // and it still signed every account out. The refresh token is a single
        // server-side lineage: exchanging it retires the previous one for every
        // holder, so a copy written back a moment later is already too late for
        // any process that read the credential in between — and Claude Code
        // keeps long-lived sessions in memory. Writing credentials at all is
        // therefore left to the tool that owns them.
        let expiredFor = credential.expiresAt.map {
            " \(snapshotAge($0, now: now)) ago"
        } ?? ""
        return .failed(
            slot,
            identity,
            "signed-in session expired\(expiredFor) and could not be renewed · open this account once"
        )
    }

    /// Asks Claude Code to renew the session for one config directory.
    ///
    /// Stage one is `auth status`: it makes no model call, so it costs no
    /// quota. Stage two — reached only when stage one landed nothing — sends a
    /// single minimal Haiku prompt through Claude Code itself, because a real
    /// API call is the one context in which Claude Code exercises its own
    /// refresh-and-persist path. Whether anything is actually exchanged stays
    /// entirely Claude Code's decision, so a token that does not need renewing
    /// is left untouched. Both stages together are one throttled attempt.
    private func renewClaudeSession(
        for slot: AccountSlot,
        currentExpiry: Date?
    ) -> Bool {
        guard
            let configDirectory = claudeConfigDirectory(for: slot),
            SessionRenewalThrottle.shared.beginAttempt(for: configDirectory),
            let binary = Self.claudeBinaryURL()
        else {
            return false
        }
        let service = Self.claudeKeychainService(forConfigDirectory: configDirectory)

        // Only ever `status`. `login`/`logout` would change the sign-in state.
        let statusRan = runClaudeHelper(
            binary: binary,
            arguments: ["auth", "status"],
            configDirectory: configDirectory,
            timeout: 20
        )
        if statusRan, settleForRenewedCredential(service: service, laterThan: currentExpiry) {
            return true
        }

        // The prompt asks for one word from the smallest model, and `--max-turns
        // 1` keeps it a single exchange. This is indistinguishable from the user
        // typing into a session, so the renewal it triggers is the same one
        // normal use performs — no client this app controls touches the tokens.
        // `--setting-sources project` keeps the user's global hooks out of this
        // run: a helper spawned by the dashboard must never trigger the side
        // effects — notification sounds, git syncs, their Keychain and privacy
        // prompts — that the user's own sessions opt into. (`--bare` is not an
        // option: it skips credential loading and reports "Not logged in" even
        // for a valid session.)
        let ackRan = runClaudeHelper(
            binary: binary,
            arguments: [
                "-p", "ONLY reply with ack",
                "--model", "haiku",
                "--max-turns", "1",
                "--setting-sources", "project",
            ],
            configDirectory: configDirectory,
            timeout: 45
        )
        if ackRan, settleForRenewedCredential(service: service, laterThan: currentExpiry) {
            return true
        }

        // Nothing landed in time. A renewal may still complete afterwards, so
        // when either stage ran the caller re-reads once and the next poll
        // picks up any late write.
        KeychainCache.shared.invalidate(service)
        return statusRan || ackRan
    }

    private func runClaudeHelper(
        binary: URL,
        arguments: [String],
        configDirectory: String,
        timeout: TimeInterval
    ) -> Bool {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = configDirectory
        process.environment = environment
        // An app launched from Finder runs with "/" as its working directory,
        // and the helper treats its working directory as a project to inspect.
        // Its own config directory is a contained place to stand instead.
        process.currentDirectoryURL = URL(
            fileURLWithPath: configDirectory,
            isDirectory: true
        )
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        // A wedged helper must not hold the refresh cycle open indefinitely.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        _ = try? output.fileHandleForReading.readToEnd()
        return process.terminationStatus == 0
    }

    /// Waits for Claude Code's asynchronous credential write to land.
    ///
    /// The helper prints and exits before its renewal has been written, so
    /// reading the moment it returns finds the old token, concludes the
    /// renewal failed, and then declines to try again until the throttle
    /// clears — leaving an account stale for the whole interval even though
    /// it was renewed a second later. Success requires an expiry strictly
    /// after the one renewal started from: during a pre-expiry renewal the
    /// old token is itself still valid, so "any future expiry" would report
    /// the unchanged credential as a fresh one.
    private func settleForRenewedCredential(
        service: String,
        laterThan baseline: Date?
    ) -> Bool {
        let settleDeadline = Date().addingTimeInterval(Self.renewalSettleWindow)
        while Date() < settleDeadline {
            usleep(200_000)
            KeychainCache.shared.invalidate(service)
            if let secret = keychainSecret(service: service),
               let root = try? JSONSerialization.jsonObject(with: secret) as? [String: Any],
               let oauth = root["claudeAiOauth"] as? [String: Any],
               let expiresAtMs = oauth["expiresAt"] as? Double {
                let expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1_000)
                if expiresAt > Date(), expiresAt > (baseline ?? .distantPast) {
                    return true
                }
            }
        }
        KeychainCache.shared.invalidate(service)
        return false
    }

    private static func claudeBinaryURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    /// The Keychain service name Claude Code uses for a config directory. The
    /// default directory keeps the bare name; every other one is suffixed with
    /// the first eight hex digits of the SHA-256 of its absolute path.
    static func claudeKeychainService(forConfigDirectory path: String) -> String {
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .path
        guard path != defaultDirectory else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "Claude Code-credentials-\(digest.prefix(8))"
    }

    func claudeConfigDirectory(for slot: AccountSlot) -> String? {
        guard let stateURL = claudeStateURL(for: slot) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Slot one's registry is the root `~/.claude.json`, but its config
        // directory — and therefore its Keychain item — is `~/.claude`.
        if stateURL.deletingLastPathComponent().path == home.path {
            return home.appendingPathComponent(".claude", isDirectory: true).path
        }
        return stateURL.deletingLastPathComponent().path
    }

    private func claudeKeychainCredential(
        for slot: AccountSlot,
        identity: LocalIdentity
    ) -> ClaudeCredential? {
        guard
            let configDirectory = claudeConfigDirectory(for: slot),
            let secret = keychainSecret(
                service: Self.claudeKeychainService(
                    forConfigDirectory: configDirectory
                )
            ),
            let root = try? JSONSerialization.jsonObject(with: secret)
                as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            !accessToken.isEmpty
        else {
            return nil
        }

        let expiresAt = (oauth["expiresAt"] as? Double)
            .map { Date(timeIntervalSince1970: $0 / 1_000) }
        let account = claudeAccount(for: slot)
        return ClaudeCredential(
            accessToken: accessToken,
            expiresAt: expiresAt,
            identity: identity,
            plan: claudePlan(from: account),
            providerAccountID: account?["accountUuid"] as? String,
            refreshToken: oauth["refreshToken"] as? String
        )
    }

    private func claudeAccount(for slot: AccountSlot) -> [String: Any]? {
        guard
            let url = claudeStateURL(for: slot),
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return nil
        }
        return root["oauthAccount"] as? [String: Any]
    }

    private func keychainSecret(service: String) -> Data? {
        // A remembered lookup — including a remembered refusal — is returned
        // without querying again, so the panel is never raised twice.
        if let remembered = KeychainCache.shared.remembered(for: service) {
            return remembered.data
        }
        // Read through /usr/bin/security rather than SecItemCopyMatching.
        //
        // Claude Code's items carry a partition list of `apple-tool:` only, and
        // one of their ACL entries names /usr/bin/security directly. A request
        // from this app matches neither: the certificate is self-signed, so
        // there is no Team ID for the partition to admit, and "Always Allow"
        // cannot record a grant that would ever satisfy it — which is why the
        // authorization panel returned on every launch. Apple's own tool is
        // already inside the item's access list, so this path reads the same
        // secret through an entry macOS has granted, without asking again and
        // without modifying anything in the login keychain.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // The service name is not secret; the secret only ever comes back on
        // stdout and is never placed in arguments, environment, or a log.
        process.arguments = [
            "find-generic-password",
            "-s", service,
            "-a", NSUserName(),
            "-w",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            KeychainCache.shared.storeFailure(for: service)
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            KeychainCache.shared.storeFailure(for: service)
            return nil
        }
        // `-w` prints the secret followed by a newline.
        let secret = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else {
            KeychainCache.shared.storeFailure(for: service)
            return nil
        }
        let secretData = Data(secret.utf8)
        KeychainCache.shared.store(secretData, for: service)
        return secretData
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
                    || registryIdentityContinuity(
                        for: slot,
                        currentAccountID: currentAccountID,
                        from: harvestedAt,
                        through: stateModifiedAt
                    ) != .contradicted
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

        // The age reported to the UI has to belong to the samples that actually
        // supplied these values. Taking the newest harvest across every file
        // would let an unrelated sample — one rejected for an expired window, or
        // one carrying a lower reading — make this reading look current.
        guard
            let harvestedAt = [fiveHour?.harvestedAt, sevenDay?.harvestedAt]
                .compactMap({ $0 })
                .max()
        else {
            return nil
        }
        return ClaudeStatusLineRateLimits(
            fiveHour: fiveHour?.window,
            sevenDay: sevenDay?.window,
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

    enum RegistryIdentityContinuity {
        /// A retained backup predates the harvest and names the current account.
        case proven
        /// Nothing on disk reaches back far enough to decide, and nothing
        /// contradicts the sample either.
        case unproven
        /// The registry demonstrably belonged to a different account across the
        /// harvest instant, so the sample cannot describe this account.
        case contradicted
    }

    /// Answers whether the account signed into this config directory changed
    /// between a sample's harvest and the current registry state.
    ///
    /// Claude rewrites `.claude.json` constantly for reasons unrelated to
    /// identity, so whole-file modification time proves nothing on its own; the
    /// retained backups are the only account-change evidence available. Those
    /// backups rotate, so evidence older than the retained set simply does not
    /// exist. This reports absence of evidence as `unproven` rather than as an
    /// account change: demanding positive proof made every observation older
    /// than the oldest retained backup permanently unusable, which is what left
    /// accounts pinned to a days-old reading with no way to recover.
    private func registryIdentityContinuity(
        for slot: AccountSlot,
        currentAccountID: String?,
        from harvestedAt: Date,
        through stateModifiedAt: Date
    ) -> RegistryIdentityContinuity {
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
            return .unproven
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

        // A backup written at or after the harvest that names a different
        // account proves the registry was not this account across that instant.
        let contradictedAfterHarvest = observations
            .filter { $0.date > harvestedAt }
            .contains { $0.accountID != currentAccountID }
        if contradictedAfterHarvest {
            return .contradicted
        }

        guard
            let preceding = observations
                .filter({ $0.date <= harvestedAt })
                .max(by: { $0.date < $1.date })
        else {
            // The backups have rotated past the harvest. Nothing on either side
            // disagrees with the sample, so it stays usable.
            return .unproven
        }
        // The registry held another account immediately before the harvest and
        // holds this one now, so the switch straddles the harvest instant.
        return preceding.accountID == currentAccountID ? .proven : .contradicted
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

    private struct SelectedStatusLineWindow {
        let window: UsageWindow
        let harvestedAt: Date
    }

    /// The status line writes one file per session, so several files can describe
    /// the same account at different vintages. Within one reset window usage only
    /// climbs, so the highest reading is the most advanced one — that is the
    /// documented way to combine these files.
    private func selectStatusLineWindow(
        samples: [ClaudeStatusLineSample],
        used: KeyPath<ClaudeStatusLineSample, Double>,
        reset: KeyPath<ClaudeStatusLineSample, TimeInterval>,
        id: String,
        title: String,
        now: Date
    ) -> SelectedStatusLineWindow? {
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

        // Ties on the reading itself are common while an account is idle. The
        // newest file that carries the winning value is the honest age for it.
        let harvestedAt = currentWindow
            .filter { $0[keyPath: used] == selected[keyPath: used] }
            .map(\.harvestedAt)
            .max() ?? selected.harvestedAt

        return SelectedStatusLineWindow(
            window: UsageWindow(
                id: id,
                title: title,
                usedPercent: selected[keyPath: used],
                resetAt: Date(timeIntervalSince1970: selected[keyPath: reset])
            ),
            harvestedAt: Date(timeIntervalSince1970: harvestedAt)
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

    private func snapshotAge(_ capturedAt: Date, now: Date) -> String {
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

    /// Classifies how current a quota reading is, independently of how often the
    /// dashboard polls. Polling an unchanged source does not make it newer.
    func claudeSnapshotState(
        fetchedAt: Date?,
        now: Date = Date()
    ) -> AccountState {
        guard let fetchedAt else { return .stale }
        let age = now.timeIntervalSince(fetchedAt)
        if age <= Self.statusLineLiveWindow { return .live }
        if age <= Self.statusLineSnapshotLifetime { return .cached }
        return .stale
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

    func usageWindow(
        from raw: Any?,
        id: String,
        title: String,
        sourceFetchedAt: Date? = nil,
        now: Date = Date()
    ) -> UsageWindow? {
        guard let object = raw as? [String: Any], let used = object["utilization"] as? Double else {
            return nil
        }
        let resetAt = (object["resets_at"] as? String).flatMap(Self.parseISO8601)
        if let resetAt {
            return resetAt > now
                ? UsageWindow(id: id, title: title, usedPercent: used, resetAt: resetAt)
                : nil
        }
        // Claude omits `resets_at` when no window is currently open, so the
        // reading carries no expiry of its own. Such a window can only be
        // trusted while the file it came from is still current; otherwise a
        // long-finished window keeps rendering as though it were live.
        guard Self.isCurrent(sourceFetchedAt, now: now) else { return nil }
        return UsageWindow(id: id, title: title, usedPercent: used, resetAt: nil)
    }

    private static func isCurrent(_ fetchedAt: Date?, now: Date) -> Bool {
        guard let fetchedAt else { return false }
        let age = now.timeIntervalSince(fetchedAt)
        return age >= -60 && age <= statusLineSnapshotLifetime
    }

    func fableUsageWindow(
        from utilization: [String: Any],
        sourceFetchedAt: Date? = nil,
        now: Date = Date()
    ) -> UsageWindow? {
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

        let resetAt = (selected["resets_at"] as? String)
            .flatMap(Self.parseISO8601)
        if let resetAt {
            guard resetAt > now else { return nil }
        } else {
            guard Self.isCurrent(sourceFetchedAt, now: now) else { return nil }
        }
        return UsageWindow(
            id: "fable-weekly",
            title: "Fable usage",
            usedPercent: percent,
            resetAt: resetAt
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

/// Remembers Keychain lookups for the life of the process.
///
/// Reading another application's Keychain item raises a system authorization
/// panel. The dashboard re-reads its sources every few seconds, so without this
/// a single refusal — or simply an unanswered panel — would queue a fresh prompt
/// on every poll. A refusal is remembered far longer than a success, so saying
/// no once is respected rather than asked again moments later.
final class KeychainCache: @unchecked Sendable {
    static let shared = KeychainCache()

    struct Remembered {
        let data: Data?
    }

    private static let successLifetime: TimeInterval = 5 * 60
    private static let failureLifetime: TimeInterval = 30 * 60

    private struct Entry {
        let data: Data?
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Returns a box when this service was already looked up and the result is
    /// still current. A box holding `nil` is a remembered failure or refusal and
    /// must not trigger another query.
    func remembered(for service: String, now: Date = Date()) -> Remembered? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[service], entry.expiresAt > now else {
            return nil
        }
        return Remembered(data: entry.data)
    }

    func store(_ data: Data, for service: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        entries[service] = Entry(
            data: data,
            expiresAt: now.addingTimeInterval(Self.successLifetime)
        )
    }

    func storeFailure(for service: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        entries[service] = Entry(
            data: nil,
            expiresAt: now.addingTimeInterval(Self.failureLifetime)
        )
    }

    func invalidate(_ service: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: service)
    }
}

/// Spaces out session-renewal attempts.
///
/// The dashboard polls every few seconds. Without this, an account whose session
/// cannot be renewed would spawn a helper process on every single poll.
final class SessionRenewalThrottle: @unchecked Sendable {
    static let shared = SessionRenewalThrottle()

    static let interval: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var lastAttempt: [String: Date] = [:]

    /// Records and permits an attempt only when one is not already recent.
    func beginAttempt(for key: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let previous = lastAttempt[key],
           now.timeIntervalSince(previous) < Self.interval {
            return false
        }
        lastAttempt[key] = now
        return true
    }
}
