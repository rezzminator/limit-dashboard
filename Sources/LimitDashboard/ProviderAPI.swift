import Foundation

struct ProviderAPI {
    private struct CodexUsageResponse: Decodable {
        struct Window: Decodable {
            let usedPercent: Double
            let resetAt: Double?
            let limitWindowSeconds: Double?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAt = "reset_at"
                case limitWindowSeconds = "limit_window_seconds"
            }
        }

        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?

            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }

        let planType: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
        }
    }

    enum RequestError: LocalizedError {
        case invalidResponse
        case http(Int, String)
        case decoding
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "The provider returned an invalid response."
            case .http(let code, let message):
                message.isEmpty ? "Provider request failed (HTTP \(code))." : message
            case .decoding:
                "The provider changed its usage response format."
            case .transport(let message):
                message
            }
        }
    }

    private let session: URLSession
    private let claudeTransport: ClaudeUsageTransport

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
        claudeTransport = ClaudeUsageTransport()
    }

    func fetchCodex(slot: AccountSlot, credential: CodexCredential) async throws -> AccountSnapshot {
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let data = try await request(
            url,
            bearer: credential.accessToken,
            headers: ["ChatGPT-Account-ID": credential.accountID]
        )
        return try decodeCodexSnapshot(data, slot: slot, credential: credential)
    }

    /// Turns the raw Codex usage body into a snapshot. Kept separate from the
    /// network call so the window mapping can be checked against a fixture.
    func decodeCodexSnapshot(
        _ data: Data,
        slot: AccountSlot,
        credential: CodexCredential,
        now: Date = Date()
    ) throws -> AccountSnapshot {
        let response: CodexUsageResponse
        do {
            response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        } catch {
            throw RequestError.decoding
        }

        // The window's length is read from `limit_window_seconds`, not assumed
        // from its position. Codex now returns its weekly (604800s) limit as the
        // primary window with no secondary; hardcoding "5-hour" here mislabeled a
        // slow weekly quota as a fast one, so the history line looked stuck.
        var windows: [UsageWindow] = []
        if let primary = response.rateLimit?.primaryWindow {
            windows.append(
                UsageWindow(
                    id: "primary",
                    title: codexWindowTitle(seconds: primary.limitWindowSeconds),
                    usedPercent: primary.usedPercent,
                    resetAt: primary.resetAt.map(Date.init(timeIntervalSince1970:))
                )
            )
        }
        if let secondary = response.rateLimit?.secondaryWindow {
            windows.append(
                UsageWindow(
                    id: "secondary",
                    title: codexWindowTitle(seconds: secondary.limitWindowSeconds),
                    usedPercent: secondary.usedPercent,
                    resetAt: secondary.resetAt.map(Date.init(timeIntervalSince1970:))
                )
            )
        }

        return AccountSnapshot(
            id: slot.id,
            slot: slot,
            identity: credential.identity.preferredDisplay
                ?? "Account \(CredentialStore.stableIdentifier(credential.accountID))",
            plan: friendlyPlan(response.planType ?? "Codex"),
            state: .live,
            windows: windows,
            fableUsage: nil,
            providerAccountID: credential.accountID,
            detail: nil,
            refreshedAt: now,
            duplicatePeer: nil
        )
    }

    /// Reads the account's own quota straight from the provider, which is the
    /// only way an account that is not currently running can report anything.
    /// The endpoint returns the same payload Claude Code caches under
    /// `cachedUsageUtilization.utilization`, so the local parsing is reused.
    func fetchClaude(
        slot: AccountSlot,
        credential: ClaudeCredential,
        store: CredentialStore = CredentialStore()
    ) async throws -> AccountSnapshot {
        // `/api/oauth/*` is served by the claude.ai origin, not by the model API
        // host. The helper fixes that destination internally so the bearer cannot
        // be sent anywhere else.
        let transportResponse: ClaudeUsageTransport.Response
        do {
            transportResponse = try claudeTransport.fetch(
                accessToken: credential.accessToken
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? "The Claude quota transport is unavailable."
            throw RequestError.transport(message)
        }
        let data = transportResponse.data
        guard (200..<300).contains(transportResponse.statusCode) else {
            throw RequestError.http(
                transportResponse.statusCode,
                safeProviderMessage(data, code: transportResponse.statusCode)
            )
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw RequestError.decoding
        }
        // Accept the payload either bare or wrapped, so a future envelope change
        // degrades to the local snapshot rather than showing wrong numbers.
        let utilization: [String: Any]
        if root["five_hour"] != nil || root["seven_day"] != nil || root["limits"] != nil {
            utilization = root
        } else if let nested = root["utilization"] as? [String: Any] {
            utilization = nested
        } else {
            throw RequestError.decoding
        }

        let now = Date()
        var windows: [UsageWindow] = []
        if let fiveHour = store.usageWindow(
            from: utilization["five_hour"],
            id: "five-hour",
            title: "5-hour",
            sourceFetchedAt: now,
            now: now
        ) {
            windows.append(fiveHour)
        }
        if let sevenDay = store.usageWindow(
            from: utilization["seven_day"],
            id: "seven-day",
            title: "7-day",
            sourceFetchedAt: now,
            now: now
        ) {
            windows.append(sevenDay)
        }

        let identity = credential.identity.preferredDisplay
            ?? slot.configuredEmail
            ?? slot.localLabel
        guard !windows.isEmpty else {
            return AccountSnapshot.quotaUnavailable(
                slot,
                identity: identity,
                plan: credential.plan,
                detail: "The provider reports no open quota window for this account.",
                refreshedAt: now
            )
        }

        return AccountSnapshot(
            id: slot.id,
            slot: slot,
            identity: identity,
            plan: credential.plan,
            state: .live,
            windows: windows,
            fableUsage: store.fableUsageWindow(
                from: utilization,
                sourceFetchedAt: now,
                now: now
            ),
            providerAccountID: credential.providerAccountID,
            detail: "Provider confirmed",
            refreshedAt: now,
            duplicatePeer: nil
        )
    }

    private func request(
        _ url: URL,
        bearer: String,
        headers: [String: String]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LimitDashboard/1.0 macOS", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RequestError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RequestError.http(http.statusCode, safeProviderMessage(data, code: http.statusCode))
        }
        return data
    }

    private func safeProviderMessage(_ data: Data, code: Int) -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = root["error"] as? [String: Any],
            let message = error["message"] as? String
        else {
            return code == 401
                ? "The local session was rejected. Sign in again in the provider app."
                : "Provider request failed (HTTP \(code))."
        }

        let lowered = message.lowercased()
        if lowered.contains("authentication") || lowered.contains("credential") || code == 401 {
            return "The local session was rejected. Sign in again in the provider app."
        }
        return String(message.prefix(160))
    }

    /// Names a Codex window by its actual length rather than its position in the
    /// response. The two common lengths get familiar names; anything else is
    /// stated in whole days/hours/minutes so a new window shape is still honest.
    private func codexWindowTitle(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Limit" }
        let total = Int(seconds.rounded())
        switch total {
        case 18_000:
            return "5-hour"
        case 604_800:
            return "Weekly"
        default:
            if total % 86_400 == 0 { return "\(total / 86_400)-day" }
            if total % 3_600 == 0 { return "\(total / 3_600)-hour" }
            if total % 60 == 0 { return "\(total / 60)-min" }
            return "\(total)-sec"
        }
    }

    private func friendlyPlan(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "claude_", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

}
