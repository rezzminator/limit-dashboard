import CryptoKit
import Foundation

struct CredentialStore: Sendable {
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

        let fetchedAt: Date?
        if let milliseconds = cached["fetchedAtMs"] as? Double {
            fetchedAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        } else {
            fetchedAt = nil
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
            detail: detail,
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
