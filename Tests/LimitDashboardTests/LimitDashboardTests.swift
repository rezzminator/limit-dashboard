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
        // Identity comes from each slot's own registry file; the checked-in
        // configuration names no one's mailbox.
        XCTAssertTrue(
            AccountSlot.configured.allSatisfy { $0.configuredEmail == nil }
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
        // A later rewrite of the registry file is not evidence of anything.
        // Claude rewrites `.claude.json` constantly for unrelated reasons, so
        // gating on whole-file modification time discarded good observations and
        // pinned accounts to a days-old cache.
        let afterBenignRewrite = try XCTUnwrap(
            store.localClaudeRateLimits(
                for: accountTwo,
                stateModifiedAt: now.addingTimeInterval(1),
                now: now
            ),
            "A registry rewrite that carries no account change must not discard a current observation."
        )
        XCTAssertEqual(afterBenignRewrite.sevenDay?.usedPercent, 82)
    }

    func testStatusLineAgeReportsTheSampleThatSuppliedTheValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "limit-dashboard-claude-age-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let liveSevenDayReset = now.addingTimeInterval(86_400)

        // One file still describes the active seven-day window from an hour ago.
        // A newer file describes only windows that have already reset, so it
        // contributes nothing and must not make the reading look current.
        let contributing = """
        {
          "acct": 2, "five_hour_used": 4, "seven_day_used": 88,
          "five_hour_resets_at": \(now.addingTimeInterval(-10).timeIntervalSince1970),
          "seven_day_resets_at": \(liveSevenDayReset.timeIntervalSince1970),
          "ts": \(now.addingTimeInterval(-3_600).timeIntervalSince1970)
        }
        """
        let expiredButNewer = """
        {
          "acct": 2, "five_hour_used": 99, "seven_day_used": 99,
          "five_hour_resets_at": \(now.addingTimeInterval(-20).timeIntervalSince1970),
          "seven_day_resets_at": \(now.addingTimeInterval(-15).timeIntervalSince1970),
          "ts": \(now.addingTimeInterval(-30).timeIntervalSince1970)
        }
        """
        try Data(contributing.utf8).write(
            to: directory.appendingPathComponent("acct-2.contributing.json")
        )
        try Data(expiredButNewer.utf8).write(
            to: directory.appendingPathComponent("acct-2.expired.json")
        )

        let store = CredentialStore(claudeRateLimitsDirectory: directory)
        let accountTwo = try XCTUnwrap(
            AccountSlot.configured.first { $0.position == 1 }
        )
        let limits = try XCTUnwrap(
            store.localClaudeRateLimits(
                for: accountTwo,
                stateModifiedAt: now.addingTimeInterval(-7_200),
                maximumAge: nil,
                now: now
            )
        )
        XCTAssertNil(limits.fiveHour, "Both five-hour windows have reset.")
        XCTAssertEqual(limits.sevenDay?.usedPercent, 88)
        XCTAssertEqual(
            limits.harvestedAt,
            now.addingTimeInterval(-3_600),
            "The age must belong to the sample that supplied the value, not to a newer sample that contributed nothing."
        )
        XCTAssertEqual(
            store.claudeSnapshotState(fetchedAt: limits.harvestedAt, now: now),
            .cached,
            "An hour-old reading is not live."
        )
    }

    func testCurrentStatusLineHarvestIsReportedAsLiveRatherThanCached() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = CredentialStore()
        XCTAssertEqual(
            store.claudeSnapshotState(
                fetchedAt: now.addingTimeInterval(-5),
                now: now
            ),
            .live,
            "A snapshot harvested seconds ago is the provider's current state."
        )
        XCTAssertEqual(
            store.claudeSnapshotState(
                fetchedAt: now.addingTimeInterval(-30 * 60),
                now: now
            ),
            .cached
        )
    }

    func testWindowWithoutResetTimeIsDroppedOnceItsSourceIsNoLongerCurrent() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = CredentialStore()
        let raw: [String: Any] = ["utilization": 0.0, "resets_at": NSNull()]

        XCTAssertNil(
            store.usageWindow(
                from: raw,
                id: "five-hour",
                title: "5-hour",
                sourceFetchedAt: now.addingTimeInterval(-3 * 24 * 60 * 60),
                now: now
            ),
            "A window with no reset time carries no expiry, so a days-old reading of it must not render as a live window."
        )
        XCTAssertNotNil(
            store.usageWindow(
                from: raw,
                id: "five-hour",
                title: "5-hour",
                sourceFetchedAt: now.addingTimeInterval(-60),
                now: now
            )
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

    func testClaudeSnapshotFreshnessIsNotConfusedWithPollingTime() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = CredentialStore()
        XCTAssertEqual(
            store.claudeSnapshotState(
                fetchedAt: now.addingTimeInterval(-30 * 60),
                now: now
            ),
            .cached
        )
        XCTAssertEqual(
            store.claudeSnapshotState(
                fetchedAt: now.addingTimeInterval(-2 * 60 * 60),
                now: now
            ),
            .stale
        )
        XCTAssertEqual(
            store.claudeSnapshotState(fetchedAt: nil, now: now),
            .stale
        )
    }

    func testExpiredClaudeQuotaWindowsAreNotDisplayed() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let formatter = ISO8601DateFormatter()
        let store = CredentialStore()
        XCTAssertNil(
            store.usageWindow(
                from: [
                    "utilization": 90.0,
                    "resets_at": formatter.string(
                        from: now.addingTimeInterval(-1)
                    ),
                ],
                id: "seven-day",
                title: "7-day",
                now: now
            )
        )
        XCTAssertNotNil(
            store.usageWindow(
                from: [
                    "utilization": 10.0,
                    "resets_at": formatter.string(
                        from: now.addingTimeInterval(60)
                    ),
                ],
                id: "seven-day",
                title: "7-day",
                now: now
            )
        )
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

    func testAgedSnapshotStillShowsAnActiveWindowButIsMarkedAged() throws {
        let slot = try XCTUnwrap(AccountSlot.configured.first)
        let window = UsageWindow(
            id: "seven-day",
            title: "7-day",
            usedPercent: 91,
            resetAt: Date(timeIntervalSince1970: 2_000_100_000)
        )
        let aged = AccountSnapshot(
            id: slot.id,
            slot: slot,
            identity: "account",
            plan: "Max",
            state: .stale,
            windows: [window],
            fableUsage: nil,
            providerAccountID: nil,
            detail: "1d old",
            refreshedAt: Date(timeIntervalSince1970: 2_000_000_000),
            duplicatePeer: nil
        )
        // The window has not reset, and usage inside one window never falls, so
        // 91% remains a true lower bound. Blanking the card hid the single most
        // important number on it.
        XCTAssertTrue(aged.canDisplayQuotaValues)
        XCTAssertTrue(aged.showsAgedValues)

        var current = aged
        current.state = .cached
        XCTAssertTrue(current.canDisplayQuotaValues)
        XCTAssertFalse(current.showsAgedValues)

        var withoutActiveWindow = aged
        withoutActiveWindow.windows = []
        XCTAssertFalse(
            withoutActiveWindow.canDisplayQuotaValues,
            "With every window reset there is nothing true left to show."
        )
    }

    func testHistoryKeepsEarlierMeasurementsWhenTheNewestReadableSourceIsOlder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "limit-dashboard-history-regression-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(
            databaseURL: directory.appendingPathComponent("history.sqlite3")
        )
        let slot = try XCTUnwrap(AccountSlot.configured.first)
        let old = Date(timeIntervalSince1970: 1_900_000_000)
        let recent = old.addingTimeInterval(6 * 60 * 60)

        func snapshot(usedPercent: Double, refreshedAt: Date) -> AccountSnapshot {
            AccountSnapshot(
                id: slot.id,
                slot: slot,
                identity: "account",
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
                fableUsage: nil,
                providerAccountID: nil,
                detail: nil,
                refreshedAt: refreshedAt,
                duplicatePeer: nil
            )
        }

        // A live session records a recent reading, the session ends, and the only
        // source left is the account's older on-disk cache.
        try store.record([snapshot(usedPercent: 55, refreshedAt: recent)], at: recent)
        try store.record(
            [snapshot(usedPercent: 20, refreshedAt: old)],
            at: recent.addingTimeInterval(60)
        )

        let points = try store.loadPrimaryUsedPoints(
            since: old.addingTimeInterval(-1)
        )
        XCTAssertEqual(
            points.count,
            2,
            "Falling back to an older source must not delete newer measurements that really happened."
        )
        XCTAssertEqual(points.map(\.value).sorted(), [20, 55])
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

        func snapshot(
            usedPercent: Double,
            sourceCapturedAt: Date
        ) -> AccountSnapshot {
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
                refreshedAt: sourceCapturedAt,
                duplicatePeer: nil
            )
        }

        try store.record(
            [snapshot(usedPercent: 20, sourceCapturedAt: start)],
            at: start
        )
        try store.record(
            [
                snapshot(
                    usedPercent: 40,
                    sourceCapturedAt: start.addingTimeInterval(60)
                )
            ],
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

    func testRepeatedPollDoesNotExtendAStaleMeasurementThroughHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "limit-dashboard-history-liveness-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(
            databaseURL: directory.appendingPathComponent("history.sqlite3")
        )
        let slot = try XCTUnwrap(AccountSlot.configured.first)
        let sourceCapturedAt = Date(timeIntervalSince1970: 1_900_000_000)

        func snapshot(refreshedAt: Date?) -> AccountSnapshot {
            AccountSnapshot(
                id: slot.id,
                slot: slot,
                identity: "account",
                plan: "Plan",
                state: .stale,
                windows: [
                    UsageWindow(
                        id: "five-hour",
                        title: "5-hour",
                        usedPercent: 42,
                        resetAt: sourceCapturedAt.addingTimeInterval(24 * 60 * 60)
                    )
                ],
                fableUsage: nil,
                providerAccountID: nil,
                detail: "Stale",
                refreshedAt: refreshedAt,
                duplicatePeer: nil
            )
        }

        try store.record(
            [snapshot(refreshedAt: nil)],
            at: sourceCapturedAt.addingTimeInterval(60 * 60)
        )
        try store.record(
            [snapshot(refreshedAt: sourceCapturedAt)],
            at: sourceCapturedAt.addingTimeInterval(2 * 60 * 60)
        )
        try store.record(
            [snapshot(refreshedAt: sourceCapturedAt)],
            at: sourceCapturedAt.addingTimeInterval(3 * 60 * 60)
        )

        let points = try store.loadPrimaryUsedPoints(
            since: sourceCapturedAt.addingTimeInterval(-1)
        )
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.timestamp, sourceCapturedAt)
        XCTAssertEqual(points.first?.value, 42)
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
            $0.id == "claude-1" || $0.id == "claude-3"
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
            ],
            // Pinned before the entry's own reset. Read against the wall clock
            // this passed until that timestamp went by, then began failing for
            // a reason unrelated to what it checks.
            now: Date(timeIntervalSince1970: 1_785_000_000)
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

    func testClaudeImpersonatedTransportDecodesHelperEnvelope() throws {
        let body = #"{"five_hour":{"utilization":12}}"#
        let encoded = Data(body.utf8).base64EncodedString()
        let envelope = """
        {
          "schema_version": 1,
          "status": 200,
          "body_base64": "\(encoded)",
          "error": null
        }
        """

        let response = try ClaudeUsageTransport().decode(Data(envelope.utf8))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.data, Data(body.utf8))
    }

    func testClaudeImpersonatedTransportRejectsFailedHelperEnvelope() {
        let envelope = """
        {
          "schema_version": 1,
          "status": null,
          "body_base64": "",
          "error": "transport_failed"
        }
        """

        XCTAssertThrowsError(
            try ClaudeUsageTransport().decode(Data(envelope.utf8))
        ) { error in
            XCTAssertEqual(
                error as? ClaudeUsageTransport.TransportError,
                .malformedOutput
            )
        }
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

    func testClaudeCredentialsAreReadableWithoutAnAuthorizationPrompt() throws {
        guard ProcessInfo.processInfo.environment["LIMIT_DASHBOARD_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Reads the real login Keychain; opt-in.")
        }
        // Claude Code's items admit only the `apple-tool:` partition, so a
        // direct SecItemCopyMatching from this app raises the authorization
        // panel on every launch no matter how often "Always Allow" is chosen.
        // Reading through /usr/bin/security uses an ACL entry macOS already
        // grants. A regression here is silent apart from the panel returning,
        // so the read is asserted to complete on its own.
        for slot in AccountSlot.configured where slot.provider == .claude {
            let configDirectory = try XCTUnwrap(
                CredentialStore().claudeConfigDirectory(for: slot)
            )
            let service = CredentialStore.claudeKeychainService(
                forConfigDirectory: configDirectory
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = [
                "find-generic-password", "-s", service, "-a", NSUserName(), "-w",
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(
                process.terminationStatus,
                0,
                "\(slot.id): /usr/bin/security could not read the credential."
            )
            XCTAssertFalse(
                data.isEmpty,
                "\(slot.id): the credential read returned nothing."
            )
        }
    }

    func testVertexAccountsKeepSeparateCredentialsAndProjects() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vertex-accounts-\(UUID().uuidString).json")
        try Data("""
        [
          {"id": "vertex-default", "label": "Personal",
           "configDirectory": null, "project": null},
          {"id": "vertex-second", "label": "Second",
           "configDirectory": ".config/gcloud-second",
           "project": "second-project"}
        ]
        """.utf8).write(to: configURL)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let accounts = VertexAccount.loadConfigured(from: configURL)
        XCTAssertEqual(accounts.count, 2)

        // The first account must stay on the machine's own gcloud config, so
        // adding a second sign-in cannot change what it reports.
        let primary = try XCTUnwrap(accounts.first)
        XCTAssertNil(primary.configDirectory)
        XCTAssertNil(primary.resolvedConfigDirectory)
        XCTAssertNil(primary.project)

        // The second reads its own config directory and names its own project.
        let secondary = accounts[1]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(secondary.project, "second-project")
        XCTAssertEqual(
            secondary.resolvedConfigDirectory,
            home + "/.config/gcloud-second"
        )
        XCTAssertNotEqual(primary.id, secondary.id)

        // A machine without the file still reports its own gcloud identity.
        let fallback = VertexAccount.loadConfigured(
            from: configURL.deletingPathExtension()
                .appendingPathExtension("missing.json")
        )
        XCTAssertEqual(fallback.count, 1)
        XCTAssertNil(fallback[0].configDirectory)
    }

    func testHistoryCanBeReadForOneSlotWithoutDisturbingTheSharedRead() throws {
        // Codex is charted on its own panel, which needs its slot's readings
        // alone. Passing no slot must still return every account, so the shared
        // 24-hour chart is unaffected.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(
            databaseURL: directory.appendingPathComponent("history.sqlite3")
        )
        let claudeSlot = try XCTUnwrap(
            AccountSlot.configured.first { $0.provider == .claude }
        )
        let codexSlot = try XCTUnwrap(
            AccountSlot.configured.first { $0.provider == .codex }
        )
        let at = Date(timeIntervalSince1970: 1_900_000_000)

        func snapshot(_ slot: AccountSlot, used: Double) -> AccountSnapshot {
            AccountSnapshot(
                id: slot.id,
                slot: slot,
                identity: "account",
                plan: "Plan",
                state: .live,
                windows: [
                    UsageWindow(
                        id: "primary",
                        title: "Weekly",
                        usedPercent: used,
                        resetAt: nil
                    )
                ],
                fableUsage: nil,
                providerAccountID: nil,
                detail: nil,
                refreshedAt: at,
                duplicatePeer: nil
            )
        }

        try store.record(
            [snapshot(claudeSlot, used: 11), snapshot(codexSlot, used: 57)],
            at: at
        )

        let codexOnly = try store.loadPrimaryUsedPoints(
            since: at.addingTimeInterval(-60),
            slotID: codexSlot.id
        )
        XCTAssertEqual(codexOnly.map(\.value), [57])
        XCTAssertEqual(Set(codexOnly.map(\.seriesID)), [codexSlot.id])

        let everything = try store.loadPrimaryUsedPoints(
            since: at.addingTimeInterval(-60)
        )
        XCTAssertEqual(everything.map(\.value).sorted(), [11, 57])
    }

    func testCodexPrimaryWeeklyWindowIsLabeledWeeklyNotFiveHour() throws {
        // The real Pro payload: a single 7-day (604800s) primary window and no
        // secondary. The primary window must be named "Weekly" — labeling it
        // "5-hour" is what made the history line look stuck at mid-scale.
        let payload = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 57,
              "limit_window_seconds": 604800,
              "reset_at": 1785902971
            },
            "secondary_window": null
          }
        }
        """
        let slot = try XCTUnwrap(AccountSlot.configured.first { $0.provider == .codex })
        let credential = CodexCredential(
            accessToken: "t",
            accountID: "acct-1",
            identity: LocalIdentity(email: "a@b.com", displayName: nil, organizationName: nil)
        )
        let snapshot = try ProviderAPI().decodeCodexSnapshot(
            Data(payload.utf8),
            slot: slot,
            credential: credential
        )
        XCTAssertEqual(snapshot.windows.count, 1)
        let primary = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(primary.id, "primary")
        XCTAssertEqual(primary.title, "Weekly")
        XCTAssertEqual(primary.usedPercent, 57)
        XCTAssertNotEqual(primary.title, "5-hour")
    }

    func testCodexWindowTitlesFollowTheirActualLength() throws {
        // Both familiar lengths and an unusual one, proving the title is derived
        // from limit_window_seconds rather than the window's position.
        let payload = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 12,
              "limit_window_seconds": 18000,
              "reset_at": 1785902971
            },
            "secondary_window": {
              "used_percent": 40,
              "limit_window_seconds": 259200,
              "reset_at": 1786115271
            }
          }
        }
        """
        let slot = try XCTUnwrap(AccountSlot.configured.first { $0.provider == .codex })
        let credential = CodexCredential(
            accessToken: "t",
            accountID: "acct-1",
            identity: LocalIdentity(email: "a@b.com", displayName: nil, organizationName: nil)
        )
        let snapshot = try ProviderAPI().decodeCodexSnapshot(
            Data(payload.utf8),
            slot: slot,
            credential: credential
        )
        XCTAssertEqual(snapshot.windows.map(\.title), ["5-hour", "3-day"])
        XCTAssertEqual(snapshot.windows.map(\.id), ["primary", "secondary"])
    }

    func testLiveProviderRequestsUseTheAppImplementation() async throws {
        guard ProcessInfo.processInfo.environment["LIMIT_DASHBOARD_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live provider network validation is opt-in.")
        }

        let store = CredentialStore()
        let loaded = AccountSlot.configured.map(store.load)
        let api = ProviderAPI()

        var codexWasLive = false
        var liveClaudeAccounts = 0
        for item in loaded {
            switch item {
            case .codex(let slot, let credential):
                let snapshot = try await api.fetchCodex(slot: slot, credential: credential)
                codexWasLive = snapshot.state == .live
                XCTAssertFalse(snapshot.windows.isEmpty)
            case .claude(let slot, let credential):
                let snapshot = try await api.fetchClaude(
                    slot: slot,
                    credential: credential,
                    store: store
                )
                XCTAssertEqual(snapshot.state, .live)
                XCTAssertFalse(snapshot.windows.isEmpty)
                XCTAssertFalse(
                    snapshot.windows.contains { $0.usedPercent < 0 || $0.usedPercent > 100 },
                    "The provider reported a percentage outside 0...100."
                )
                liveClaudeAccounts += 1
            case .failed:
                continue
            }
        }

        XCTAssertTrue(codexWasLive, "Codex usage endpoint did not return a live window.")
        XCTAssertEqual(
            liveClaudeAccounts,
            3,
            "Every configured Claude account must produce a live provider reading."
        )
    }

    func testClaudeKeychainServiceMatchesClaudeCodesNamingScheme() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // The default config directory keeps the bare service name; any other
        // one is suffixed with the first eight hex digits of SHA-256(path).
        XCTAssertEqual(
            CredentialStore.claudeKeychainService(
                forConfigDirectory: "\(home)/.claude"
            ),
            "Claude Code-credentials"
        )
        XCTAssertEqual(
            CredentialStore.claudeKeychainService(
                forConfigDirectory: NSHomeDirectory() + "/.claude2"
            ),
            "Claude Code-credentials-dceab1ac"
        )
        XCTAssertEqual(
            CredentialStore.claudeKeychainService(
                forConfigDirectory: NSHomeDirectory() + "/.claude3"
            ),
            "Claude Code-credentials-f90b25d2"
        )
    }

    func testSlotOneUsesTheClaudeDirectoryEvenThoughItsRegistryIsAtHome() throws {
        let store = CredentialStore()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let slots = AccountSlot.configured.filter { $0.provider == .claude }
        XCTAssertEqual(
            slots.map { store.claudeConfigDirectory(for: $0) },
            ["\(home)/.claude", "\(home)/.claude2", "\(home)/.claude3"],
            "Slot one reads ~/.claude.json but its credential lives under ~/.claude."
        )
        XCTAssertNil(
            store.claudeConfigDirectory(
                for: try XCTUnwrap(
                    AccountSlot.configured.first { $0.provider == .codex }
                )
            )
        )
    }

    func testExpiredClaudeTokenIsNotUsedForALiveRequest() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let identity = LocalIdentity(
            email: "person@example.com",
            displayName: nil,
            organizationName: nil
        )
        func credential(expiresAt: Date?) -> ClaudeCredential {
            ClaudeCredential(
                accessToken: "token",
                expiresAt: expiresAt,
                identity: identity,
                plan: "Max",
                providerAccountID: nil
            )
        }
        XCTAssertTrue(
            credential(expiresAt: now.addingTimeInterval(60)).isUsable(now: now)
        )
        XCTAssertFalse(
            credential(expiresAt: now.addingTimeInterval(-1)).isUsable(now: now),
            "Refreshing the token is Claude Code's job; an expired one falls back to the local snapshot."
        )
        XCTAssertFalse(
            ClaudeCredential(
                accessToken: "",
                expiresAt: nil,
                identity: identity,
                plan: "Max",
                providerAccountID: nil
            ).isUsable(now: now)
        )
    }

    func testSessionRenewalIsThrottledSoPollingCannotSpawnHelperProcesses() {
        let throttle = SessionRenewalThrottle()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = NSHomeDirectory() + "/.claude3"

        XCTAssertTrue(throttle.beginAttempt(for: account, now: now))
        XCTAssertFalse(
            throttle.beginAttempt(for: account, now: now.addingTimeInterval(1)),
            "The dashboard polls every few seconds; a second attempt straight away would spawn a helper per poll."
        )
        XCTAssertFalse(
            throttle.beginAttempt(for: account, now: now.addingTimeInterval(9 * 60))
        )
        XCTAssertTrue(
            throttle.beginAttempt(for: account, now: now.addingTimeInterval(11 * 60)),
            "After the interval a renewal may be attempted again."
        )
        XCTAssertTrue(
            throttle.beginAttempt(
                for: NSHomeDirectory() + "/.claude2",
                now: now.addingTimeInterval(1)
            ),
            "Throttling is per account, not global."
        )
    }

    func testKeychainCacheInvalidationLetsARenewedTokenBeSeenImmediately() {
        let cache = KeychainCache()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let service = "Claude Code-credentials-test"

        cache.storeFailure(for: service, now: now)
        XCTAssertNotNil(cache.remembered(for: service, now: now))

        cache.invalidate(service)
        XCTAssertNil(
            cache.remembered(for: service, now: now),
            "After Claude Code renews the session the stale result must not be reused."
        )
    }

    func testKeychainRefusalIsRememberedSoThePanelIsNotRaisedRepeatedly() {
        let cache = KeychainCache()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let service = "Claude Code-credentials-test"

        XCTAssertNil(cache.remembered(for: service, now: now))

        cache.storeFailure(for: service, now: now)
        let remembered = cache.remembered(for: service, now: now.addingTimeInterval(60))
        XCTAssertNotNil(
            remembered,
            "A refusal must be remembered, otherwise every poll raises a new panel."
        )
        XCTAssertNil(remembered?.data)

        XCTAssertNil(
            cache.remembered(for: service, now: now.addingTimeInterval(31 * 60)),
            "The refusal eventually expires so access can be granted later."
        )

        cache.store(Data("secret".utf8), for: service, now: now)
        XCTAssertEqual(
            cache.remembered(for: service, now: now.addingTimeInterval(60))?.data,
            Data("secret".utf8)
        )
        XCTAssertNil(
            cache.remembered(for: service, now: now.addingTimeInterval(6 * 60)),
            "A success is re-read often enough to pick up a rotated token."
        )
    }
}
