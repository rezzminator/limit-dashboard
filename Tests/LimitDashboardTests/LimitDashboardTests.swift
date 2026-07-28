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

    func testRefreshIntervalValidationAndDefault() {
        XCTAssertEqual(RefreshPolicy.defaultSeconds, 20)
        XCTAssertEqual(RefreshPolicy.validated(-100), 10)
        XCTAssertEqual(RefreshPolicy.validated(20), 20)
        XCTAssertEqual(RefreshPolicy.validated(99_999), 3_600)
    }

    func testCachedClaudeExtraUsageDoesNotInventAValue() throws {
        let extra = CredentialStore().extraUsageInfo(
            from: [
                "extra_usage": [
                    "is_enabled": false,
                    "monthly_limit": NSNull(),
                    "used_credits": NSNull(),
                    "utilization": NSNull()
                ]
            ]
        )
        XCTAssertEqual(extra.state, .disabled)
        XCTAssertNil(extra.usedPercent)
        XCTAssertEqual(extra.status, "Not enabled")
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
