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
