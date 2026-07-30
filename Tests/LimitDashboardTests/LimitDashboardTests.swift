import XCTest
@testable import LimitDashboard

final class LimitDashboardTests: XCTestCase {
    func testConfiguredDashboardHasExactlyFourStableSlots() {
        XCTAssertEqual(AccountSlot.configured.count, 4)
        XCTAssertEqual(AccountSlot.configured.filter { $0.provider == .claude }.count, 3)
        XCTAssertEqual(AccountSlot.configured.filter { $0.provider == .codex }.count, 1)
        XCTAssertEqual(Set(AccountSlot.configured.map(\.id)).count, 4)
        XCTAssertEqual(
            AccountSlot.configured
                .filter { $0.provider == .claude }
                .map(\.title),
            ["Claude Account 1", "Claude Account 2", "Claude Account 3"]
        )
        XCTAssertTrue(
            AccountSlot.configured
                .filter { $0.provider == .claude }
                .allSatisfy { $0.configuredEmail?.contains("@") == true }
        )
    }

    func testRemainingPercentageIsClamped() {
        XCTAssertEqual(
            UsageWindow(id: "a", title: "A", usedPercent: 24, resetAt: nil).remainingPercent,
            76
        )
        XCTAssertEqual(
            UsageWindow(id: "b", title: "B", usedPercent: 140, resetAt: nil).remainingPercent,
            0
        )
    }

    func testObservedSeventyThreePercentUsageIsNotDisplayedAsThirtyPercent() {
        let observed = UsageWindow(
            id: "seven-day",
            title: "7-day",
            usedPercent: 73,
            resetAt: nil
        )
        XCTAssertEqual(observed.usedLabel, "73% used")
        XCTAssertEqual(observed.remainingLabel, "27% remaining")
        XCTAssertEqual(observed.normalizedUsedPercent, 73)
    }

    func testResetCountdownUsesDaysHoursAndZeroPaddedMinutes() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resetAt = now.addingTimeInterval(
            TimeInterval((24 + 12) * 60 * 60 + 5 * 60)
        )
        XCTAssertEqual(
            ResetCountdown.compact(until: resetAt, now: now),
            "1D 12H 05M"
        )
        XCTAssertEqual(
            ResetCountdown.accessibilityText(until: resetAt, now: now),
            "1 day, 12 hours, 5 minutes"
        )
    }

    func testResetCountdownRoundsUpPartialMinuteAndStopsAtZero() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(
            ResetCountdown.compact(
                until: now.addingTimeInterval(61),
                now: now
            ),
            "0D 00H 02M"
        )
        XCTAssertEqual(
            ResetCountdown.compact(
                until: now.addingTimeInterval(-1),
                now: now
            ),
            "0D 00H 00M"
        )
    }

    func testFreshStatusLineSnapshotOverridesStaleSeventyThreePercentCacheForAccountTwo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "limit-dashboard-claude-rate-limits-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fiveHourReset = now.addingTimeInterval(3_600).timeIntervalSince1970
        let sevenDayReset = now.addingTimeInterval(86_400).timeIntervalSince1970

        func writeSample(
            named name: String,
            account: Int,
            sevenDayUsed: Int,
            harvestedAt: Date
        ) throws {
            let payload = """
            {
              "acct": \(account),
              "five_hour_used": 2,
              "seven_day_used": \(sevenDayUsed),
              "five_hour_resets_at": \(fiveHourReset),
              "seven_day_resets_at": \(sevenDayReset),
              "ts": \(harvestedAt.timeIntervalSince1970)
            }
            """
            try Data(payload.utf8).write(
                to: directory.appendingPathComponent(name)
            )
        }

        try writeSample(
            named: "acct-2.older.json",
            account: 2,
            sevenDayUsed: 80,
            harvestedAt: now.addingTimeInterval(-10)
        )
        try writeSample(
            named: "acct-2.current.json",
            account: 2,
            sevenDayUsed: 82,
            harvestedAt: now.addingTimeInterval(-5)
        )
        try writeSample(
            named: "acct-2.wrong-account.json",
            account: 1,
            sevenDayUsed: 99,
            harvestedAt: now
        )

        let store = CredentialStore(claudeRateLimitsDirectory: directory)
        let accountTwo = try XCTUnwrap(
            AccountSlot.configured.first { $0.position == 1 }
        )
        let statusLine = try XCTUnwrap(
            store.localClaudeRateLimits(
                for: accountTwo,
                stateModifiedAt: now.addingTimeInterval(-60),
                now: now
            )
        )
        XCTAssertEqual(statusLine.fiveHour?.usedPercent, 2)
        XCTAssertEqual(statusLine.sevenDay?.usedPercent, 82)

        let merged = store.mergeClaudeWindows(
            cached: [
                UsageWindow(
                    id: "five-hour",
                    title: "5-hour",
                    usedPercent: 10,
                    resetAt: nil
                ),
                UsageWindow(
                    id: "seven-day",
                    title: "7-day",
                    usedPercent: 73,
                    resetAt: nil
                ),
            ],
            statusLine: statusLine
        )
        XCTAssertEqual(
            merged.first { $0.id == "seven-day" }?.usedPercent,
            82
        )
        XCTAssertEqual(
            merged.first { $0.id == "seven-day" }?.remainingPercent,
            18
        )
        XCTAssertNil(
            store.localClaudeRateLimits(
                for: accountTwo,
                stateModifiedAt: now.addingTimeInterval(1),
                now: now
            ),
            "A snapshot written before the authoritative registry state must not be associated with the new account."
        )
    }

    func testBenignRegistryRewriteKeepsFreshSlotTwoSampleWhenIdentityIsContinuous() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "limit-dashboard-claude-continuity-\(UUID().uuidString)",
            isDirectory: true
        )
        let rateDirectory = directory.appendingPathComponent(
            "rate-limits",
            isDirectory: true
        )
        let backupsDirectory = directory.appendingPathComponent(
            "backups",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rateDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: backupsDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let harvestedAt = now.addingTimeInterval(-30)
        let stateModifiedAt = now.addingTimeInterval(-10)
        let sample = """
        {
          "acct": 2,
          "five_hour_used": 13,
          "seven_day_used": 84,
          "five_hour_resets_at": \(now.addingTimeInterval(3_600).timeIntervalSince1970),
          "seven_day_resets_at": \(now.addingTimeInterval(86_400).timeIntervalSince1970),
          "ts": \(harvestedAt.timeIntervalSince1970)
        }
        """
        try Data(sample.utf8).write(
            to: rateDirectory.appendingPathComponent("acct-2.session.json")
        )

        func writeBackup(
            named name: String,
            accountID: String,
            modifiedAt: Date
        ) throws -> URL {
            let file = backupsDirectory.appendingPathComponent(name)
            let payload = """
            {"oauthAccount":{"accountUuid":"\(accountID)"}}
            """
            try Data(payload.utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: file.path
            )
            return file
        }

        _ = try writeBackup(
            named: ".claude.json.backup.before",
            accountID: "account-two",
            modifiedAt: harvestedAt.addingTimeInterval(-30)
        )
        let after = try writeBackup(
            named: ".claude.json.backup.after",
            accountID: "account-two",
            modifiedAt: harvestedAt.addingTimeInterval(10)
        )

        let store = CredentialStore(
            claudeRateLimitsDirectory: rateDirectory,
            claudeBackupsDirectory: backupsDirectory
        )
        let accountTwo = try XCTUnwrap(
            AccountSlot.configured.first { $0.position == 1 }
        )
        let accepted = try XCTUnwrap(
            store.localClaudeRateLimits(
                for: accountTwo,
                stateModifiedAt: stateModifiedAt,
                currentAccountID: "account-two",
                now: now
            )
        )
        XCTAssertEqual(accepted.fiveHour?.usedPercent, 13)
        XCTAssertEqual(accepted.sevenDay?.usedPercent, 84)

        let changedAccount = """
        {"oauthAccount":{"accountUuid":"different-account"}}
        """
        try Data(changedAccount.utf8).write(to: after)
        try FileManager.default.setAttributes(
            [.modificationDate: harvestedAt.addingTimeInterval(10)],
            ofItemAtPath: after.path
        )
        XCTAssertNil(
            store.localClaudeRateLimits(
                for: accountTwo,
                stateModifiedAt: stateModifiedAt,
                currentAccountID: "account-two",
                now: now
            ),
            "A real account change between harvest and the current registry must invalidate the sample."
        )
        XCTAssertTrue(
            store.hasFreshClaudeRateLimitCandidate(
                for: accountTwo,
                now: now
            ),
            "The UI must distinguish a fresh-but-ambiguous sample from having no local source, so it can suppress the older cache."
        )
    }

    func testNewestIdentityMatchedActiveWindowBeatsOlderSeventyThreePercentCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "limit-dashboard-claude-stale-selection-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let harvestedAt = now.addingTimeInterval(-3 * 60 * 60)
        let resetAt = now.addingTimeInterval(36 * 60 * 60)
        let sample = """
        {
          "acct": 2,
          "five_hour_used": 1,
          "seven_day_used": 91,
          "five_hour_resets_at": \(now.addingTimeInterval(60 * 60).timeIntervalSince1970),
          "seven_day_resets_at": \(resetAt.timeIntervalSince1970),
          "ts": \(harvestedAt.timeIntervalSince1970)
        }
        """
        try Data(sample.utf8).write(
            to: directory.appendingPathComponent("acct-2.current.json")
        )

        let store = CredentialStore(claudeRateLimitsDirectory: directory)
        let accountTwo = try XCTUnwrap(
            AccountSlot.configured.first { $0.position == 1 }
        )
        XCTAssertNil(
            store.localClaudeRateLimits(
                for: accountTwo,
                stateModifiedAt: harvestedAt.addingTimeInterval(-60),
                now: now
            ),
            "The three-hour-old observation must not be labeled fresh."
        )
        let historical = try XCTUnwrap(
            store.localClaudeRateLimits(
                for: accountTwo,
                stateModifiedAt: harvestedAt.addingTimeInterval(-60),
                maximumAge: nil,
                now: now
            )
        )
        let merged = store.mergeClaudeWindows(
            cached: [
                UsageWindow(
                    id: "five-hour",
                    title: "5-hour",
                    usedPercent: 10,
                    resetAt: now.addingTimeInterval(-60)
                ),
                UsageWindow(
                    id: "seven-day",
                    title: "7-day",
                    usedPercent: 73,
                    resetAt: resetAt.addingTimeInterval(0.5)
                ),
            ],
            statusLine: historical,
            requireMonotonicActiveWindow: true
        )
        XCTAssertEqual(
            merged.first { $0.id == "seven-day" }?.usedPercent,
            91,
            "The newer 91%-used observation must win over the two-day-old 73% cache for the same reset window."
        )
        XCTAssertEqual(
            merged.first { $0.id == "five-hour" }?.usedPercent,
            1,
            "A newer reset window may legitimately have lower usage."
        )
    }

    func testOlderObservationCannotLowerUsageWithinSameResetWindow() {
        let resetAt = Date(timeIntervalSince1970: 2_000_100_000)
        let statusLine = ClaudeStatusLineRateLimits(
            fiveHour: nil,
            sevenDay: UsageWindow(
                id: "seven-day",
                title: "7-day",
                usedPercent: 89,
                resetAt: resetAt
            ),
            harvestedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let merged = CredentialStore().mergeClaudeWindows(
            cached: [
                UsageWindow(
                    id: "seven-day",
                    title: "7-day",
                    usedPercent: 90,
                    resetAt: resetAt.addingTimeInterval(0.5)
                )
            ],
            statusLine: statusLine,
            requireMonotonicActiveWindow: true
        )
        XCTAssertEqual(
            merged.first?.usedPercent,
            90,
            "Quota usage cannot move backward inside one reset window."
        )
    }

    func testCanonicalClaudeStateRegistryUsesTheRootFileForAccountOne() {
        let claude = AccountSlot.configured.filter { $0.provider == .claude }
        XCTAssertEqual(
            claude.map(\.claudeStatePath),
            [".claude.json", ".claude2/.claude.json", ".claude3/.claude.json"]
        )
    }

    func testMismatchedCachedAccountIsRejected() {
        let store = CredentialStore()
        XCTAssertFalse(
            store.cacheMatchesClaudeIdentity(
                root: ["oauthAccount": ["accountUuid": "account-a"]],
                cached: ["accountUuid": "account-b"]
            )
        )
        XCTAssertTrue(
            store.cacheMatchesClaudeIdentity(
                root: ["oauthAccount": ["accountUuid": "account-a"]],
                cached: ["accountUuid": "account-a"]
            )
        )
    }

    func testRefreshIntervalValidationAndDefault() {
        XCTAssertEqual(RefreshPolicy.defaultSeconds, 20)
        XCTAssertEqual(RefreshPolicy.validated(-100), 10)
        XCTAssertEqual(RefreshPolicy.validated(20), 20)
        XCTAssertEqual(RefreshPolicy.validated(99_999), 3_600)
    }

    func testUnchangedPollSnapshotComparesEqualDespiteNewFetchTime() throws {
        let slot = try XCTUnwrap(AccountSlot.configured.first)
        let window = UsageWindow(
            id: "five-hour",
            title: "5-hour",
            usedPercent: 7,
            resetAt: nil
        )
        let first = AccountSnapshot(
            id: slot.id,
            slot: slot,
            identity: "person@example.com",
            plan: "Pro",
            state: .cached,
            windows: [window],
            fableUsage: nil,
            providerAccountID: "account-id",
            detail: nil,
            refreshedAt: Date(timeIntervalSince1970: 1),
            duplicatePeer: nil
        )
        var nextPoll = first
        nextPoll.refreshedAt = Date(timeIntervalSince1970: 2)

        XCTAssertEqual(first, nextPoll)

        nextPoll.windows = [
            UsageWindow(
                id: "five-hour",
                title: "5-hour",
                usedPercent: 8,
                resetAt: nil
            )
        ]
        XCTAssertNotEqual(first, nextPoll)
    }

    func testHistoryStoreAggregatesPrimaryUsedValuesWithoutIdentityData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "limit-dashboard-history-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        let store = HistoryStore(databaseURL: databaseURL)
        let slot = try XCTUnwrap(AccountSlot.configured.first)
        let start = Date(timeIntervalSince1970: 1_800_000_123)

        func snapshot(usedPercent: Double) -> AccountSnapshot {
            AccountSnapshot(
                id: slot.id,
                slot: slot,
                identity: "private-email@example.com",
                plan: "Plan",
                state: .cached,
                windows: [
                    UsageWindow(
                        id: "five-hour",
                        title: "5-hour",
                        usedPercent: usedPercent,
                        resetAt: nil
                    )
                ],
                fableUsage: UsageWindow(
                    id: "fable",
                    title: "Fable usage",
                    usedPercent: 97,
                    resetAt: nil
                ),
                providerAccountID: "provider-account-id",
                detail: nil,
                refreshedAt: start,
                duplicatePeer: nil
            )
        }

        try store.record([snapshot(usedPercent: 20)], at: start)
        try store.record(
            [snapshot(usedPercent: 40)],
            at: start.addingTimeInterval(60)
        )
        let points = try store.loadPrimaryUsedPoints(
            since: start.addingTimeInterval(-1),
            bucketSeconds: 300
        )

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].seriesID, slot.id)
        XCTAssertEqual(
            points[0].timestamp,
            start,
            "The plotted bucket must begin at its first real measurement, not the bucket boundary."
        )
        XCTAssertEqual(points[0].value, 30, accuracy: 0.001)
        XCTAssertGreaterThan(
            points[0].timestamp,
            start.addingTimeInterval(-60 * 60),
            "History must not backfill a point one hour before the first measurement."
        )
        XCTAssertFalse(
            points.contains {
                $0.timestamp <= start.addingTimeInterval(-60 * 60)
            },
            "No synthetic or carried-back history should be returned."
        )

        let databaseBytes = try Data(contentsOf: databaseURL)
        let databaseText = String(decoding: databaseBytes, as: UTF8.self)
        XCTAssertFalse(databaseText.contains("private-email@example.com"))
        XCTAssertFalse(databaseText.contains("provider-account-id"))
    }

    func testQuotaStateHistoryKeepsIdleClaudeAccountsAtZeroUsed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "limit-dashboard-zero-quota-history-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(
            databaseURL: directory.appendingPathComponent("history.sqlite3")
        )
        let idleSlots = AccountSlot.configured.filter {
            $0.id == "claude-gmail" || $0.id == "claude-khosravi"
        }
        XCTAssertEqual(idleSlots.count, 2)

        let capturedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshots = idleSlots.map { slot in
            AccountSnapshot(
                id: slot.id,
                slot: slot,
                identity: slot.configuredEmail ?? slot.localLabel,
                plan: "Max",
                state: .cached,
                windows: [
                    UsageWindow(
                        id: "five-hour",
                        title: "5-hour",
                        usedPercent: 0,
                        resetAt: nil
                    ),
                    UsageWindow(
                        id: "seven-day",
                        title: "7-day",
                        usedPercent: 90,
                        resetAt: nil
                    ),
                ],
                fableUsage: nil,
                providerAccountID: nil,
                detail: nil,
                refreshedAt: capturedAt,
                duplicatePeer: nil
            )
        }
        try store.record(snapshots, at: capturedAt)

        let points = try store.loadPrimaryUsedPoints(
            since: capturedAt.addingTimeInterval(-1)
        )
        XCTAssertEqual(points.count, 2)
        XCTAssertTrue(points.allSatisfy { $0.value == 0 })
        XCTAssertFalse(
            points.contains { $0.value == 100 },
            "A 100% remaining baseline must never be plotted as activity or quota used."
        )
    }

    func testCachedClaudeFableUsageReadsExactWeeklyScopedEntry() throws {
        let fable = CredentialStore().fableUsageWindow(
            from: [
                "limits": [[
                    "kind": "weekly_scoped",
                    "group": "weekly",
                    "percent": 24,
                    "resets_at": "2026-08-01T03:00:00.299633+00:00",
                    "scope": ["model": ["id": NSNull(), "display_name": "Fable"]],
                    "is_active": false
                ]]
            ]
        )
        XCTAssertEqual(fable?.title, "Fable usage")
        XCTAssertEqual(fable?.usedPercent, 24)
        XCTAssertEqual(fable?.remainingPercent, 76)
        XCTAssertNotNil(fable?.resetAt)
    }

    func testCachedClaudeFableUsageDoesNotInventAValue() {
        XCTAssertNil(
            CredentialStore().fableUsageWindow(
                from: [
                    "limits": [[
                        "kind": "weekly_scoped",
                        "percent": NSNull(),
                        "scope": ["model": ["display_name": "Fable"]]
                    ]]
                ]
            )
        )
        XCTAssertNil(
            CredentialStore().fableUsageWindow(
                from: ["extra_usage": ["is_enabled": true, "utilization": 42]]
            )
        )
    }

    func testVertexReportDecoderKeepsChartAndSummaryWindowsIndependent() throws {
        let payload = """
        {
          "schema_version": 2,
          "project": "test-project",
          "chart_window": {
            "start": "2026-07-28T00:00:00+00:00",
            "end": "2026-07-28T08:00:00+00:00",
            "bucket_seconds": 1200
          },
          "summary_window": {
            "start": "2026-06-28T08:00:00+00:00",
            "end": "2026-07-28T08:00:00+00:00"
          },
          "series": {
            "id": "vertex-ai-token-usage",
            "label": "Vertex AI token totals",
            "unit": "tokens",
            "points": [
              {"timestamp": "2026-07-28T00:00:00+00:00", "value": 1234}
            ]
          },
          "token_totals": {
            "input_not_marked_explicit_cache": 100,
            "explicit_cache_served_input": 20,
            "output": 30,
            "total": 150,
            "explicit_cache_metric_reported": true,
            "implicit_cache_hit_tokens": null,
            "implicit_cache_hit_rate": null,
            "implicit_cache_status": "unavailable_historically_without_request_usage_metadata_cachedContentTokenCount"
          },
          "estimated_eur": 12.34,
          "estimate_kind": "public_list_price_estimate_not_invoice",
          "pricing_source": "test",
          "pricing_warnings": ["fallback clearly flagged"]
        }
        """

        let report = try VertexReportService().decode(Data(payload.utf8))

        XCTAssertEqual(report.chartBucketSeconds, 1_200)
        XCTAssertEqual(
            report.chartEnd.timeIntervalSince(report.chartStart),
            8 * 60 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(
            report.summaryEnd.timeIntervalSince(report.summaryStart),
            30 * 24 * 60 * 60,
            accuracy: 0.001
        )
        XCTAssertEqual(report.series.id, "vertex-ai-token-usage")
        XCTAssertEqual(report.series.unit, .tokens)
        XCTAssertEqual(report.series.points.first?.value, 1_234)
        XCTAssertEqual(report.totals.inputNotMarkedExplicitCache, 100)
        XCTAssertEqual(report.totals.explicitCacheServedInput, 20)
        XCTAssertEqual(report.totals.input, 120)
        XCTAssertTrue(report.totals.explicitCacheMetricReported)
        XCTAssertEqual(report.totals.output, 30)
        XCTAssertEqual(report.estimatedEUR, 12.34)
    }

    func testDashboardRequestsThirtyDailyVertexBuckets() {
        XCTAssertEqual(
            VertexReportService.dashboardArguments,
            [
                "--chart-last", "30d",
                "--chart-interval", "1d",
                "--summary-last", "30d",
                "--timezone", "local",
                "--json",
            ]
        )
    }

    func testZeroVertexBucketsAreValidMeasurementsWithoutActivity() throws {
        let payload = """
        {
          "schema_version": 2,
          "project": "test-project",
          "chart_window": {
            "start": "2026-06-28T00:00:00+00:00",
            "end": "2026-07-28T00:00:00+00:00",
            "bucket_seconds": 86400
          },
          "summary_window": {
            "start": "2026-06-28T00:00:00+00:00",
            "end": "2026-07-28T00:00:00+00:00"
          },
          "series": {
            "id": "vertex-ai-token-usage",
            "label": "Vertex AI token totals",
            "unit": "tokens",
            "points": [
              {"timestamp": "2026-06-28T00:00:00+00:00", "value": 0},
              {"timestamp": "2026-06-29T00:00:00+00:00", "value": 0}
            ]
          },
          "token_totals": {
            "input_not_marked_explicit_cache": 0,
            "explicit_cache_served_input": 0,
            "output": 0,
            "total": 0,
            "explicit_cache_metric_reported": false,
            "implicit_cache_hit_tokens": null,
            "implicit_cache_hit_rate": null,
            "implicit_cache_status": "unavailable"
          },
          "estimated_eur": 0,
          "estimate_kind": "public_list_price_estimate_not_invoice",
          "pricing_source": "test",
          "pricing_warnings": []
        }
        """

        let report = try VertexReportService().decode(Data(payload.utf8))
        XCTAssertEqual(report.series.points.count, 2)
        XCTAssertFalse(report.hasChartActivity)
    }

    func testLocalCodexCredentialIsReadableWithoutExposingValues() throws {
        let slot = try XCTUnwrap(AccountSlot.configured.first { $0.provider == .codex })
        let loaded = CredentialStore().load(slot)
        if case .codex(_, let credential) = loaded {
            XCTAssertTrue(credential.identity.email?.contains("@") == true)
            XCTAssertFalse(credential.identity.email?.contains("•") == true)
            return
        }
        XCTFail("Expected the existing local Codex sign-in.")
    }

    func testLiveProviderRequestsUseTheAppImplementation() async throws {
        guard ProcessInfo.processInfo.environment["LIMIT_DASHBOARD_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live Codex network validation is opt-in.")
        }

        let store = CredentialStore()
        let loaded = AccountSlot.configured.map(store.load)
        let api = ProviderAPI()

        var codexWasLive = false
        for item in loaded {
            switch item {
            case .codex(let slot, let credential):
                let snapshot = try await api.fetchCodex(slot: slot, credential: credential)
                codexWasLive = snapshot.state == .live
                XCTAssertFalse(snapshot.windows.isEmpty)
            case .failed:
                continue
            }
        }

        XCTAssertTrue(codexWasLive, "Codex usage endpoint did not return a live window.")
    }
}
