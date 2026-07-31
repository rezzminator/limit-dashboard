import Foundation

struct ClaudeUsageTransport: Sendable {
    struct Response: Equatable, Sendable {
        let statusCode: Int
        let data: Data
    }

    enum TransportError: LocalizedError, Equatable {
        case helperMissing
        case interpreterMissing
        case timedOut
        case processFailed(String)
        case malformedOutput

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                "The bundled Claude quota helper is unavailable."
            case .interpreterMissing:
                "The harvester curl_cffi runtime is unavailable."
            case .timedOut:
                "The Claude quota request timed out."
            case .processFailed(let reason):
                "The Claude quota transport failed (\(reason))."
            case .malformedOutput:
                "The Claude quota transport returned an unexpected result."
            }
        }
    }

    private static let processTimeout: TimeInterval = 30

    func fetch(accessToken: String) throws -> Response {
        let helperURL = try helperLocation()
        let pythonURL = try pythonLocation()
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [helperURL.path]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // curl_cffi diagnostics are deliberately discarded. They are not needed
        // by the UI and must never accidentally echo request details.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw TransportError.processFailed("could_not_start")
        }

        let request = try JSONSerialization.data(
            withJSONObject: ["access_token": accessToken]
        )
        input.fileHandleForWriting.write(request)
        input.fileHandleForWriting.closeFile()

        let deadline = Date().addingTimeInterval(Self.processTimeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            throw TransportError.timedOut
        }

        let payload = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            if let envelope = try? decodeEnvelope(payload),
               let reason = envelope.error {
                throw TransportError.processFailed(reason)
            }
            throw TransportError.processFailed("helper_exited")
        }
        return try decode(payload)
    }

    func decode(_ data: Data) throws -> Response {
        let envelope = try decodeEnvelope(data)
        guard
            envelope.schemaVersion == 1,
            envelope.error == nil,
            let statusCode = envelope.status,
            (100...599).contains(statusCode),
            let body = Data(base64Encoded: envelope.bodyBase64)
        else {
            throw TransportError.malformedOutput
        }
        return Response(statusCode: statusCode, data: body)
    }

    private func decodeEnvelope(_ data: Data) throws -> Envelope {
        do {
            return try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw TransportError.malformedOutput
        }
    }

    private func helperLocation() throws -> URL {
        if let bundled = Bundle.main.url(
            forResource: "claude_usage_fetch",
            withExtension: "py"
        ) {
            return bundled
        }
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let development = sourceRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("claude_usage_fetch.py", isDirectory: false)
        guard FileManager.default.fileExists(atPath: development.path) else {
            throw TransportError.helperMissing
        }
        return development
    }

    private func pythonLocation() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let override = environment["LIMIT_DASHBOARD_CURL_CFFI_PYTHON"].map {
            URL(fileURLWithPath: $0)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            override,
            home
                .appendingPathComponent("work/harvester-web-mcp", isDirectory: true)
                .appendingPathComponent(".venv/bin/python", isDirectory: false),
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3"),
        ].compactMap { $0 }

        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw TransportError.interpreterMissing
        }
        return executable
    }

    private struct Envelope: Decodable {
        let schemaVersion: Int
        let status: Int?
        let bodyBase64: String
        let error: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case status
            case bodyBase64 = "body_base64"
            case error
        }
    }
}
