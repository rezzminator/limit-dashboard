import XCTest
@testable import LimitDashboard

final class LimitDashboardTests: XCTestCase {
    func testConfiguredDashboardHasExactlyFourStableSlots() {
        XCTAssertEqual(AccountSlot.configured.count, 4)
        XCTAssertEqual(AccountSlot.configured.filter { $0.provider == .claude }.count, 3)
        XCTAssertEqual(AccountSlot.configured.filter { $0.provider == .codex }.count, 1)
        XCTAssertEqual(Set(AccountSlot.configured.map(\.id)).count, 4)
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

    func testHistoryStoreAggregatesPrimaryRemainingValuesWithoutIdentityData() throws {
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
        let points = try store.loadPrimaryPoints(
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
        XCTAssertEqual(points[0].value, 70, accuracy: 0.001)
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
