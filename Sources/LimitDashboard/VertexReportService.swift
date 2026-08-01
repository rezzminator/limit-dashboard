import Foundation

/// One authenticated Vertex source. Each account keeps its own gcloud config
/// directory, so signing in to a second project cannot disturb the first: the
/// helper reads whichever credentials `CLOUDSDK_CONFIG` points at.
struct VertexAccount: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    /// Home-relative gcloud config directory. `nil` uses the machine default.
    let configDirectory: String?
    /// Explicit project. `nil` uses that config's active project.
    let project: String?

    var resolvedConfigDirectory: String? {
        configDirectory.map {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent($0, isDirectory: true)
                .path
        }
    }

    /// Accounts come from `~/.config/limit-dashboard/vertex_accounts.json` when
    /// that file exists, so a checkout of this repository names nobody's
    /// projects. Without the file, the machine's default gcloud identity is the
    /// one account.
    static let configured: [VertexAccount] = loadConfigured()

    static func loadConfigured(
        from url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".config/limit-dashboard/vertex_accounts.json"
            )
    ) -> [VertexAccount] {
        struct Stored: Decodable {
            let id: String
            let label: String
            let configDirectory: String?
            let project: String?
        }
        if
            let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode([Stored].self, from: data),
            !stored.isEmpty
        {
            return stored.map {
                VertexAccount(
                    id: $0.id,
                    label: $0.label,
                    configDirectory: $0.configDirectory,
                    project: $0.project
                )
            }
        }
        return [
            VertexAccount(
                id: "vertex-default",
                label: "Personal",
                configDirectory: nil,
                project: nil
            )
        ]
    }
}

/// A single account's outcome. A failing account reports its own reason and
/// never removes the account that did report.
struct VertexAccountReport: Identifiable, Equatable, Sendable {
    let account: VertexAccount
    let report: VertexReport?
    let error: String?

    var id: String { account.id }
}

struct VertexTokenTotals: Equatable, Sendable {
    let inputNotMarkedExplicitCache: Int64
    let explicitCacheServedInput: Int64
    let explicitCacheMetricReported: Bool
    let output: Int64
    let total: Int64
    let implicitCacheStatus: String

    var input: Int64 {
        inputNotMarkedExplicitCache + explicitCacheServedInput
    }
}

struct VertexReport: Equatable, Sendable {
    let project: String
    let chartStart: Date
    let chartEnd: Date
    let chartBucketSeconds: Int
    let summaryStart: Date
    let summaryEnd: Date
    let series: ChartSeries
    let estimatedEUR: Double?
    let totals: VertexTokenTotals
    let pricingSource: String
    let pricingWarnings: [String]

    var hasChartActivity: Bool {
        series.points.contains { $0.value > 0 }
    }
}

enum VertexReportError: LocalizedError {
    case scriptMissing
    case processFailed(String)
    case malformedOutput

    var errorDescription: String? {
        switch self {
        case .scriptMissing:
            "The bundled Vertex report helper is unavailable."
        case .processFailed(let detail):
            "Vertex report unavailable: \(detail)"
        case .malformedOutput:
            "The local Vertex report returned an unexpected result."
        }
    }
}

struct VertexReportService: Sendable {
    static let refreshInterval: TimeInterval = 15 * 60
    /// Applied while any account is failing, so re-authenticating one is
    /// reflected quickly instead of being hidden behind the full interval.
    static let retryInterval: TimeInterval = 60
    static let dashboardArguments = [
        "--chart-last", "30d",
        "--chart-interval", "1d",
        "--summary-last", "30d",
        "--timezone", "local",
        "--json",
    ]

    func fetch(
        account: VertexAccount = VertexAccount.configured[0]
    ) throws -> VertexReport {
        let scriptURL = try scriptLocation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        var arguments = [scriptURL.path] + Self.dashboardArguments
        if let project = account.project {
            arguments += ["--project", project]
        }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            existingPath,
        ].joined(separator: ":")
        // Selects this account's own gcloud credentials. The default account
        // inherits whatever the machine already uses, so its behavior is
        // unchanged by a second sign-in.
        if let configDirectory = account.resolvedConfigDirectory {
            environment["CLOUDSDK_CONFIG"] = configDirectory
        }
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw VertexReportError.processFailed("Python could not start.")
        }
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let safeDetail = String(decoding: errorOutput, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init)?
                .prefix(240)
            throw VertexReportError.processFailed(
                safeDetail.map(String.init) ?? "the read-only helper failed."
            )
        }
        return try decode(output)
    }

    func decode(_ data: Data) throws -> VertexReport {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw VertexReportError.malformedOutput
        }
        guard payload.schemaVersion == 2,
              payload.series.unit == "tokens",
              payload.estimateKind == "public_list_price_estimate_not_invoice",
              payload.chartWindow.bucketSeconds >= 60,
              let chartStart = parseDate(payload.chartWindow.start),
              let chartEnd = parseDate(payload.chartWindow.end),
              let summaryStart = parseDate(payload.summaryWindow.start),
              let summaryEnd = parseDate(payload.summaryWindow.end) else {
            throw VertexReportError.malformedOutput
        }

        let points = try payload.series.points.map { point -> ChartPoint in
            guard let timestamp = parseDate(point.timestamp) else {
                throw VertexReportError.malformedOutput
            }
            return ChartPoint(
                seriesID: payload.series.id,
                timestamp: timestamp,
                value: point.value
            )
        }
        return VertexReport(
            project: payload.project,
            chartStart: chartStart,
            chartEnd: chartEnd,
            chartBucketSeconds: payload.chartWindow.bucketSeconds,
            summaryStart: summaryStart,
            summaryEnd: summaryEnd,
            series: ChartSeries(
                id: payload.series.id,
                label: payload.series.label,
                unit: .tokens,
                points: points
            ),
            estimatedEUR: payload.estimatedEUR,
            totals: VertexTokenTotals(
                inputNotMarkedExplicitCache:
                    payload.tokenTotals.inputNotMarkedExplicitCache,
                explicitCacheServedInput:
                    payload.tokenTotals.explicitCacheServedInput,
                explicitCacheMetricReported:
                    payload.tokenTotals.explicitCacheMetricReported,
                output: payload.tokenTotals.output,
                total: payload.tokenTotals.total,
                implicitCacheStatus: payload.tokenTotals.implicitCacheStatus
            ),
            pricingSource: payload.pricingSource,
            pricingWarnings: payload.pricingWarnings
        )
    }

    private func scriptLocation() throws -> URL {
        if let bundled = Bundle.main.url(
            forResource: "vertex_ai_report",
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
            .appendingPathComponent("vertex_ai_report.py", isDirectory: false)
        guard FileManager.default.fileExists(atPath: development.path) else {
            throw VertexReportError.scriptMissing
        }
        return development
    }

    private func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.date(from: value)
    }

    private struct Payload: Decodable {
        struct WindowPayload: Decodable {
            let start: String
            let end: String
            let bucketSeconds: Int?

            enum CodingKeys: String, CodingKey {
                case start
                case end
                case bucketSeconds = "bucket_seconds"
            }
        }

        struct ChartWindowPayload: Decodable {
            let start: String
            let end: String
            let bucketSeconds: Int

            enum CodingKeys: String, CodingKey {
                case start
                case end
                case bucketSeconds = "bucket_seconds"
            }
        }

        struct SeriesPayload: Decodable {
            struct PointPayload: Decodable {
                let timestamp: String
                let value: Double
            }

            let id: String
            let label: String
            let unit: String
            let points: [PointPayload]
        }

        struct TokenTotalsPayload: Decodable {
            let inputNotMarkedExplicitCache: Int64
            let explicitCacheServedInput: Int64
            let explicitCacheMetricReported: Bool
            let output: Int64
            let total: Int64
            let implicitCacheStatus: String

            enum CodingKeys: String, CodingKey {
                case inputNotMarkedExplicitCache = "input_not_marked_explicit_cache"
                case explicitCacheServedInput = "explicit_cache_served_input"
                case explicitCacheMetricReported = "explicit_cache_metric_reported"
                case output
                case total
                case implicitCacheStatus = "implicit_cache_status"
            }
        }

        let schemaVersion: Int
        let project: String
        let chartWindow: ChartWindowPayload
        let summaryWindow: WindowPayload
        let series: SeriesPayload
        let tokenTotals: TokenTotalsPayload
        let estimatedEUR: Double?
        let estimateKind: String
        let pricingSource: String
        let pricingWarnings: [String]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case project
            case chartWindow = "chart_window"
            case summaryWindow = "summary_window"
            case series
            case tokenTotals = "token_totals"
            case estimatedEUR = "estimated_eur"
            case estimateKind = "estimate_kind"
            case pricingSource = "pricing_source"
            case pricingWarnings = "pricing_warnings"
        }
    }
}
