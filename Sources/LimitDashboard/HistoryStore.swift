import Foundation
import SQLite3

enum ChartUnit: String, Hashable, Sendable {
    case percentUsed
    case tokens
}

struct ChartPoint: Identifiable, Hashable, Sendable {
    let seriesID: String
    let timestamp: Date
    let value: Double

    var id: String {
        "\(seriesID):\(timestamp.timeIntervalSince1970)"
    }
}

struct ChartSeries: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let unit: ChartUnit
    let points: [ChartPoint]
}

enum HistoryStoreError: LocalizedError {
    case openFailed
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .openFailed:
            "Local history database could not be opened."
        case .sqlite(let message):
            "Local history database error: \(message)"
        }
    }
}

struct HistoryStore: Sendable {
    static let chartWindow: TimeInterval = 24 * 60 * 60
    static let chartBucketSeconds = 5 * 60
    // Codex reports one weekly window, which moves a couple of points per day.
    // Read over its own quota period it shows a real climb and its reset; read
    // over 24 hours it is a flat line, which is why it gets its own chart.
    static let codexChartWindow: TimeInterval = 7 * 24 * 60 * 60
    static let codexChartBucketSeconds = 30 * 60
    static let retentionWindow: TimeInterval = 90 * 24 * 60 * 60

    let databaseURL: URL

    init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
            return
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.databaseURL = base
            .appendingPathComponent("LimitDashboard", isDirectory: true)
            .appendingPathComponent("quota-history.sqlite3", isDirectory: false)
    }

    func record(_ snapshots: [AccountSnapshot], at capturedAt: Date) throws {
        let measurements = snapshots.flatMap { snapshot -> [Measurement] in
            // Without the provider's own observation time there is no honest
            // place for the reading on a time axis. Substituting the poll time
            // would invent a measurement that says the source was read now.
            guard let sourceCapturedAt = snapshot.refreshedAt else { return [] }
            var values = snapshot.windows.enumerated().map { index, window in
                Measurement(
                    slotID: snapshot.slot.id,
                    metricID: window.id,
                    sourceCapturedAt: sourceCapturedAt,
                    isPrimary: index == 0,
                    usedPercent: window.normalizedUsedPercent,
                    remainingPercent: window.remainingPercent
                )
            }
            if let fable = snapshot.fableUsage {
                values.append(
                    Measurement(
                        slotID: snapshot.slot.id,
                        metricID: fable.id,
                        sourceCapturedAt: sourceCapturedAt,
                        isPrimary: false,
                        usedPercent: fable.normalizedUsedPercent,
                        remainingPercent: fable.remainingPercent
                    )
                )
            }
            return values
        }
        try withDatabase { database in
            try execute(database, "BEGIN IMMEDIATE")
            do {
                // Rows are keyed by the provider's own observation time, so a
                // repeated poll of an unchanged source rewrites its own row
                // instead of drawing a flat line forward. Nothing else is
                // deleted here: a slot whose newest readable source is older
                // than rows already on file — the normal case once a session
                // ends and only an older cache remains — must not take genuine
                // newer history down with it.
                let insert = """
                    INSERT INTO quota_snapshots (
                        slot_id,
                        metric_id,
                        captured_at,
                        minute_bucket,
                        is_primary,
                        used_percent,
                        remaining_percent
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(slot_id, metric_id, minute_bucket) DO UPDATE SET
                        captured_at = excluded.captured_at,
                        is_primary = excluded.is_primary,
                        used_percent = excluded.used_percent,
                        remaining_percent = excluded.remaining_percent
                    """
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, insert, -1, &statement, nil) == SQLITE_OK,
                      let statement else {
                    throw sqliteError(database)
                }
                defer { sqlite3_finalize(statement) }

                for measurement in measurements {
                    let sourceSeconds =
                        measurement.sourceCapturedAt.timeIntervalSince1970
                    let minuteBucket = Int64(sourceSeconds / 60) * 60
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(measurement.slotID, to: 1, statement: statement, database: database)
                    try bind(measurement.metricID, to: 2, statement: statement, database: database)
                    sqlite3_bind_double(statement, 3, sourceSeconds)
                    sqlite3_bind_int64(statement, 4, minuteBucket)
                    sqlite3_bind_int(statement, 5, measurement.isPrimary ? 1 : 0)
                    sqlite3_bind_double(statement, 6, measurement.usedPercent)
                    sqlite3_bind_double(statement, 7, measurement.remainingPercent)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw sqliteError(database)
                    }
                }

                var prune: OpaquePointer?
                guard sqlite3_prepare_v2(
                    database,
                    "DELETE FROM quota_snapshots WHERE captured_at < ?",
                    -1,
                    &prune,
                    nil
                ) == SQLITE_OK, let prune else {
                    throw sqliteError(database)
                }
                sqlite3_bind_double(
                    prune,
                    1,
                    capturedAt.timeIntervalSince1970 - Self.retentionWindow
                )
                let pruneResult = sqlite3_step(prune)
                sqlite3_finalize(prune)
                guard pruneResult == SQLITE_DONE else {
                    throw sqliteError(database)
                }

                try execute(database, "COMMIT")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        }
    }

    /// Loads saved primary-window readings. `slotID` limits the result to one
    /// account, which lets a provider whose window length differs be charted on
    /// its own time and value scale instead of being flattened onto a shared one.
    func loadPrimaryUsedPoints(
        since start: Date,
        bucketSeconds: Int = Self.chartBucketSeconds,
        slotID: String? = nil
    ) throws -> [ChartPoint] {
        precondition(bucketSeconds > 0)
        return try withDatabase { database in
            let query = """
                SELECT
                    slot_id,
                    CAST(captured_at / ? AS INTEGER) * ? AS bucket_key,
                    MIN(captured_at) AS first_measurement,
                    AVG(used_percent)
                FROM quota_snapshots
                WHERE is_primary = 1 AND captured_at >= ?
                    AND (?4 IS NULL OR slot_id = ?4)
                GROUP BY slot_id, bucket_key
                ORDER BY first_measurement ASC, slot_id ASC
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw sqliteError(database)
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, Int64(bucketSeconds))
            sqlite3_bind_int64(statement, 2, Int64(bucketSeconds))
            sqlite3_bind_double(statement, 3, start.timeIntervalSince1970)
            if let slotID {
                try bind(slotID, to: 4, statement: statement, database: database)
            } else {
                sqlite3_bind_null(statement, 4)
            }

            var points: [ChartPoint] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                guard let slotBytes = sqlite3_column_text(statement, 0) else {
                    stepResult = sqlite3_step(statement)
                    continue
                }
                points.append(
                    ChartPoint(
                        seriesID: String(cString: slotBytes),
                        timestamp: Date(
                            timeIntervalSince1970: sqlite3_column_double(statement, 2)
                        ),
                        value: sqlite3_column_double(statement, 3)
                    )
                )
                stepResult = sqlite3_step(statement)
            }
            guard stepResult == SQLITE_DONE else {
                throw sqliteError(database)
            }
            return points
        }
    }

    private func withDatabase<T>(
        _ operation: (OpaquePointer) throws -> T
    ) throws -> T {
        let databaseDirectory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: databaseDirectory.path
        )

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database {
                sqlite3_close(database)
            }
            throw HistoryStoreError.openFailed
        }
        defer { sqlite3_close(database) }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: databaseURL.path
        )

        sqlite3_busy_timeout(database, 2_000)
        try execute(database, "PRAGMA journal_mode = WAL")
        try execute(database, "PRAGMA synchronous = NORMAL")
        try execute(
            database,
            """
            CREATE TABLE IF NOT EXISTS quota_snapshots (
                slot_id TEXT NOT NULL,
                metric_id TEXT NOT NULL,
                captured_at REAL NOT NULL,
                minute_bucket INTEGER NOT NULL,
                is_primary INTEGER NOT NULL,
                used_percent REAL NOT NULL,
                remaining_percent REAL NOT NULL,
                PRIMARY KEY (slot_id, metric_id, minute_bucket)
            )
            """
        )
        try execute(
            database,
            """
            CREATE INDEX IF NOT EXISTS quota_snapshots_time
            ON quota_snapshots(captured_at)
            """
        )
        return try operation(database)
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private func bind(
        _ value: String,
        to index: Int32,
        statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(
                statement,
                index,
                pointer,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard result == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private func sqliteError(_ database: OpaquePointer) -> HistoryStoreError {
        let message = sqlite3_errmsg(database).map(String.init(cString:))
            ?? "unknown SQLite failure"
        return .sqlite(message)
    }

    private struct Measurement {
        let slotID: String
        let metricID: String
        let sourceCapturedAt: Date
        let isPrimary: Bool
        let usedPercent: Double
        let remainingPercent: Double
    }
}
