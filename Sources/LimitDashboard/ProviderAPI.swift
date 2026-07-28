import Foundation

struct ProviderAPI {
    private struct CodexUsageResponse: Decodable {
        struct Window: Decodable {
            let usedPercent: Double
            let resetAt: Double?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAt = "reset_at"
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

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "The provider returned an invalid response."
            case .http(let code, let message):
                message.isEmpty ? "Provider request failed (HTTP \(code))." : message
            case .decoding:
                "The provider changed its usage response format."
            }
        }
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    func fetchCodex(slot: AccountSlot, credential: CodexCredential) async throws -> AccountSnapshot {
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let data = try await request(
            url,
            bearer: credential.accessToken,
            headers: ["ChatGPT-Account-ID": credential.accountID]
        )

        let response: CodexUsageResponse
        do {
            response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        } catch {
            throw RequestError.decoding
        }

        var windows: [UsageWindow] = []
        if let primary = response.rateLimit?.primaryWindow {
            windows.append(
                UsageWindow(
                    id: "primary",
                    title: windowTitle(primary),
                    usedPercent: primary.usedPercent,
                    resetAt: primary.resetAt.map(Date.init(timeIntervalSince1970:))
                )
            )
        }
        if let secondary = response.rateLimit?.secondaryWindow {
            windows.append(
                UsageWindow(
                    id: "secondary",
                    title: windowTitle(secondary),
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
            refreshedAt: Date(),
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

    private func friendlyPlan(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "claude_", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func windowTitle(_ window: CodexUsageResponse.Window) -> String {
        guard let resetAt = window.resetAt else { return "Usage" }
        let seconds = max(0, resetAt - Date().timeIntervalSince1970)
        if seconds >= 6 * 24 * 60 * 60 { return "Weekly" }
        if seconds >= 4 * 60 * 60 { return "5-hour" }
        return "Usage"
    }
}
