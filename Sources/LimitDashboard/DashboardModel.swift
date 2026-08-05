import Combine
import Foundation

@MainActor
final class DashboardModel: ObservableObject {
    /// The account list read once for the properties below's own default
    /// values. `performRefresh` re-reads the file itself on every cycle, so
    /// this cached copy only avoids reading it three times over at startup.
    private static let initialSlots: [AccountSlot] = AccountSlot.loadConfigured()

    @Published private(set) var snapshots: [AccountSnapshot] =
        DashboardModel.initialSlots.map(AccountSnapshot.loading)
    // The shared 24-hour chart carries only the providers whose primary window is
    // short enough to move within it. Codex's weekly window is charted on its own
    // panel, over its own period and value range.
    @Published private(set) var historySeries: [ChartSeries] =
        DashboardModel.historySeriesSkeleton(for: DashboardModel.initialSlots)
    @Published private(set) var codexSeries: ChartSeries?
    @Published private(set) var historyError: String?
    @Published private(set) var vertexReports: [VertexAccountReport] =
        VertexAccount.configured.map {
            VertexAccountReport(account: $0, report: nil, error: nil)
        }
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    private var refreshInFlight: Task<Void, Never>?
    private let historyStore = HistoryStore()
    private var lastVertexAttempt: Date?

    /// The configured account list, reloaded at the top of every refresh so
    /// enabling, disabling, or adding an account in accounts.json takes
    /// effect without restarting the app.
    private(set) var slots: [AccountSlot] = DashboardModel.initialSlots

    /// The provider's own last-confirmed reading for a Claude slot. Kept so a
    /// card can still show it — honestly re-aged, never as live — when a
    /// later cycle's query is throttled or fails outright rather than
    /// reverting straight to the local snapshot.
    private var providerSnapshotMemo: [String: AccountSnapshot] = [:]

    private var codexSlotID: String? {
        slots.first { $0.provider == .codex }?.id
    }

    var codexSnapshot: AccountSnapshot? {
        snapshots.first { $0.slot.provider == .codex }
    }

    var claudeSnapshots: [AccountSnapshot] {
        snapshots.filter { $0.slot.provider == .claude }
    }

    var liveCount: Int {
        snapshots.filter { $0.state == .live }.count
    }

    var issueCount: Int {
        let unavailable = snapshots.filter { $0.state == .unavailable }.count
        let unavailableQuota = snapshots.filter { $0.state == .quotaUnavailable }.count
        let stale = snapshots.filter { $0.state == .stale }.count
        let hasDuplicateGroup = snapshots.contains { $0.duplicatePeer != nil }
        return unavailable + unavailableQuota + stale + failedVertexAccounts
            + (hasDuplicateGroup ? 1 : 0)
    }

    /// A Vertex account whose report could not be produced. The count covered
    /// only the session slots, so an account that had stopped reporting left the
    /// header reading zero issues while its own lane showed an error.
    private var failedVertexAccounts: Int {
        vertexReports.filter { $0.error != nil }.count
    }

    // The banner explains every condition the header counts, so a non-zero
    // issue count is never left without a reason on screen.
    var issueSummary: String? {
        let unavailable = snapshots.filter { $0.state == .unavailable }.count
        let unavailableQuota = snapshots.filter { $0.state == .quotaUnavailable }.count
        let aged = snapshots.filter { $0.state == .stale }.count
        let duplicates = snapshots.filter { $0.duplicatePeer != nil }.count

        var parts: [String] = []
        if unavailable > 0 {
            parts.append("\(unavailable) account\(unavailable == 1 ? "" : "s") unavailable")
        }
        if unavailableQuota > 0 {
            parts.append(
                "\(unavailableQuota) account\(unavailableQuota == 1 ? "" : "s") waiting for its own quota snapshot"
            )
        }
        if aged > 0 {
            parts.append(
                "\(aged) account\(aged == 1 ? "" : "s") showing an aged reading"
            )
        }
        if duplicates > 0 {
            parts.append("duplicate Claude session detected")
        }
        if failedVertexAccounts > 0 {
            parts.append(
                "\(failedVertexAccounts) Vertex account\(failedVertexAccounts == 1 ? "" : "s") not reporting"
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A manual refresh that lands during a scheduled poll waits for that poll's
    /// result instead of being silently dropped, so the button always resolves
    /// to current data.
    func refresh(showActivity: Bool = false) async {
        if let refreshInFlight {
            if showActivity {
                isRefreshing = true
                await refreshInFlight.value
                isRefreshing = false
            } else {
                await refreshInFlight.value
            }
            return
        }
        let work = Task { await performRefresh() }
        refreshInFlight = work
        if showActivity {
            isRefreshing = true
        }
        defer {
            refreshInFlight = nil
            if showActivity {
                isRefreshing = false
            }
        }
        await work.value
    }

    /// The chart series shell for a slot list, with no points yet. Used both
    /// for the property's own startup value and to keep the legend in step
    /// the moment accounts.json changes, ahead of the history query that
    /// fills the points back in a little later in the same refresh.
    private static func historySeriesSkeleton(for slots: [AccountSlot]) -> [ChartSeries] {
        slots
            .filter { $0.provider == .claude }
            .map {
                ChartSeries(id: $0.id, label: $0.title, unit: .percentUsed, points: [])
            }
    }

    /// Reconciles snapshot and chart state against a freshly loaded slot
    /// list. A vanished id drops its card and its provider memo; a new id
    /// gets a loading card and an empty chart series until its own data
    /// arrives. A no-op when the configured list has not changed.
    private func reconcileSlots(_ newSlots: [AccountSlot]) {
        guard newSlots != slots else { return }
        slots = newSlots
        let validIDs = Set(newSlots.map(\.id))
        snapshots.removeAll { !validIDs.contains($0.id) }
        let presentIDs = Set(snapshots.map(\.id))
        for slot in newSlots where !presentIDs.contains(slot.id) {
            snapshots.append(AccountSnapshot.loading(slot))
        }
        snapshots.sort { $0.slot.position < $1.slot.position }
        historySeries = Self.historySeriesSkeleton(for: newSlots)
        providerSnapshotMemo = providerSnapshotMemo.filter { validIDs.contains($0.key) }
    }

    private func performRefresh() async {
        reconcileSlots(AccountSlot.loadConfigured())
        let currentSlots = slots
        let store = CredentialStore()
        let loaded = await Task.detached(priority: .userInitiated) {
            currentSlots.map(store.load)
        }.value
        var results: [AccountSnapshot] = []

        await withTaskGroup(of: FetchOutcome.self) { group in
            for credential in loaded {
                let memoized = providerSnapshotMemo[credential.slot.id]
                group.addTask {
                    await Self.fetch(credential, store: store, memoizedProviderSnapshot: memoized)
                }
            }
            for await outcome in group {
                results.append(outcome.snapshot)
                if let providerSnapshot = outcome.providerSnapshot {
                    providerSnapshotMemo[outcome.snapshot.slot.id] = providerSnapshot
                }
            }
        }

        results.sort { $0.slot.position < $1.slot.position }
        markDuplicateClaudeSessions(in: &results)
        let finalizedResults = results
        applyChangedSnapshots(finalizedResults)

        let capturedAt = Date()
        let historyStore = historyStore
        let codexSlotID = codexSlotID
        let historyResult = await Task.detached(
            priority: .utility
        ) { [historyStore, finalizedResults, capturedAt, codexSlotID] in
            do {
                try historyStore.record(finalizedResults, at: capturedAt)
                let points = try historyStore.loadPrimaryUsedPoints(
                    since: capturedAt.addingTimeInterval(-HistoryStore.chartWindow)
                )
                // Codex is read over its own weekly period so its climb and its
                // reset are visible rather than flattened into 24 hours.
                let codexPoints = try codexSlotID.map { slotID in
                    try historyStore.loadPrimaryUsedPoints(
                        since: capturedAt.addingTimeInterval(
                            -HistoryStore.codexChartWindow
                        ),
                        bucketSeconds: HistoryStore.codexChartBucketSeconds,
                        slotID: slotID
                    )
                } ?? []
                return HistoryRefreshResult.success(points, codexPoints)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Local history is temporarily unavailable."
                return HistoryRefreshResult.failure(message)
            }
        }.value
        applyHistoryResult(historyResult)

        // Cloud Monitoring data changes slowly, so a good report is held for the
        // full interval. A failure is different: it usually means the account
        // needs signing in again, and once that is done the fix should show up
        // promptly rather than after the next quarter-hour.
        let vertexInterval = vertexReports.contains { $0.error != nil }
            ? VertexReportService.retryInterval
            : VertexReportService.refreshInterval
        let shouldFetchVertex = lastVertexAttempt.map {
            capturedAt.timeIntervalSince($0) >= vertexInterval
        } ?? true
        if shouldFetchVertex {
            lastVertexAttempt = capturedAt
            // Each account is read independently and concurrently, so one
            // unauthenticated project cannot blank the one that does report.
            let vertexResults = await withTaskGroup(
                of: VertexAccountReport.self,
                returning: [VertexAccountReport].self
            ) { group in
                for account in VertexAccount.configured {
                    group.addTask {
                        do {
                            return VertexAccountReport(
                                account: account,
                                report: try VertexReportService().fetch(
                                    account: account
                                ),
                                error: nil
                            )
                        } catch {
                            let message = (error as? LocalizedError)?
                                .errorDescription
                                ?? "Vertex report is temporarily unavailable."
                            return VertexAccountReport(
                                account: account,
                                report: nil,
                                error: message
                            )
                        }
                    }
                }
                var collected: [VertexAccountReport] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            applyVertexResults(vertexResults)
        }
        lastUpdated = capturedAt
    }

    private func applyChangedSnapshots(_ results: [AccountSnapshot]) {
        for result in results {
            guard let index = snapshots.firstIndex(where: { $0.id == result.id }) else {
                snapshots.append(result)
                continue
            }
            if snapshots[index] != result {
                snapshots[index] = result
            }
        }
    }

    private func applyHistoryResult(_ result: HistoryRefreshResult) {
        switch result {
        case .success(let points, let codexPoints):
            let grouped = Dictionary(grouping: points, by: \.seriesID)
            let nextSeries = slots
                .filter { $0.provider == .claude }
                .map { slot in
                    ChartSeries(
                        id: slot.id,
                        label: slot.title,
                        unit: .percentUsed,
                        points: grouped[slot.id] ?? []
                    )
                }
            if historySeries != nextSeries {
                historySeries = nextSeries
            }
            let nextCodex = codexSlotID.map { slotID in
                ChartSeries(
                    id: slotID,
                    label: "Codex",
                    unit: .percentUsed,
                    points: codexPoints
                )
            }
            if codexSeries != nextCodex {
                codexSeries = nextCodex
            }
            if historyError != nil {
                historyError = nil
            }
        case .failure(let message):
            if historyError != message {
                historyError = message
            }
        }
    }

    private func applyVertexResults(_ results: [VertexAccountReport]) {
        // Kept in configured order so the lanes below the chart do not reorder
        // themselves as accounts finish at different speeds.
        let ordered = VertexAccount.configured.compactMap { account in
            results.first { $0.account == account }
        }
        guard !ordered.isEmpty else { return }
        if vertexReports != ordered {
            vertexReports = ordered
        }
    }

    /// A completed fetch, plus a fresh provider reading when this cycle
    /// produced one. Kept separate from `snapshot` so a memo write only
    /// happens on a live, provider-confirmed read — never on a value that was
    /// itself reused from an earlier memo — which would otherwise let a stale
    /// reading refresh its own timestamp indefinitely.
    private struct FetchOutcome: Sendable {
        let snapshot: AccountSnapshot
        let providerSnapshot: AccountSnapshot?
    }

    private nonisolated static func fetch(
        _ loaded: LoadedCredential,
        store: CredentialStore,
        memoizedProviderSnapshot: AccountSnapshot?
    ) async -> FetchOutcome {
        let api = ProviderAPI()
        do {
            switch loaded {
            case .codex(let slot, let credential):
                let snapshot = try await api.fetchCodex(slot: slot, credential: credential)
                return FetchOutcome(snapshot: snapshot, providerSnapshot: nil)
            case .claude(let slot, let credential):
                // The usage endpoint is undocumented and punitively rate
                // limited, so it is queried on its own cadence rather than
                // every poll. A denied attempt falls back to the local
                // snapshot exactly as a failed request would.
                guard ProviderQueryGate.shared.beginAttempt(for: slot.id) else {
                    let snapshot = fallbackClaudeSnapshot(
                        slot: slot,
                        credential: credential,
                        store: store,
                        memoizedProviderSnapshot: memoizedProviderSnapshot
                    )
                    return FetchOutcome(snapshot: snapshot, providerSnapshot: nil)
                }
                do {
                    let snapshot = try await api.fetchClaude(
                        slot: slot,
                        credential: credential,
                        store: store
                    )
                    debugLog("\(slot.id): API OK state=\(snapshot.state.title)")
                    return FetchOutcome(snapshot: snapshot, providerSnapshot: snapshot)
                } catch {
                    debugLog("\(slot.id): API FAILED \(compact(error))")
                    // A rejected token or an unreachable provider must not blank
                    // the card: the local snapshot is still the best known state.
                    let snapshot = fallbackClaudeSnapshot(
                        slot: slot,
                        credential: credential,
                        store: store,
                        memoizedProviderSnapshot: memoizedProviderSnapshot,
                        note: "provider request failed (\(compact(error)))"
                    )
                    return FetchOutcome(snapshot: snapshot, providerSnapshot: nil)
                }
            case .failed(let slot, let identity, let message):
                if slot.provider == .claude {
                    debugLog("\(slot.id): NOT loaded as .claude — \(message)")
                }
                if slot.provider == .claude {
                    let resolvedIdentity = identity
                        ?? LocalIdentity(email: slot.configuredEmail, displayName: nil, organizationName: nil)
                    // `message` says why the provider could not be queried. On a
                    // card that still has local values it belongs beside them as
                    // a note; with no values at all it is the whole story. When
                    // provider queries are switched off there was nothing to
                    // explain, so the card is left to speak for its own source.
                    let snapshot = store.cachedClaudeSnapshot(
                        for: slot,
                        identity: resolvedIdentity,
                        note: CredentialStore.claudeProviderQueriesEnabled
                            ? message
                            : nil
                    ) ?? AccountSnapshot.unavailable(
                        slot,
                        identity: identity?.preferredDisplay,
                        detail: message
                    )
                    return FetchOutcome(snapshot: snapshot, providerSnapshot: nil)
                }
                return FetchOutcome(
                    snapshot: AccountSnapshot.unavailable(
                        slot,
                        identity: identity?.preferredDisplay,
                        detail: message
                    ),
                    providerSnapshot: nil
                )
            }
        } catch {
            return FetchOutcome(
                snapshot: AccountSnapshot.unavailable(
                    loaded.slot,
                    detail: friendly(error)
                ),
                providerSnapshot: nil
            )
        }
    }

    /// Builds a Claude card from local sources for a cycle in which the
    /// provider was not queried — the request throttle denied the attempt or
    /// the request itself failed. When an earlier cycle's provider reading is
    /// newer than what the local sources produced, or the local sources
    /// produced nothing displayable at all, that reading is shown again with
    /// its state re-derived from its own age — so a memo that is getting old
    /// honestly turns `.cached` or `.stale` rather than continuing to read as
    /// live.
    private nonisolated static func fallbackClaudeSnapshot(
        slot: AccountSlot,
        credential: ClaudeCredential,
        store: CredentialStore,
        memoizedProviderSnapshot: AccountSnapshot?,
        note: String? = nil
    ) -> AccountSnapshot {
        let local = store.cachedClaudeSnapshot(
            for: slot,
            identity: credential.identity,
            note: note
        ) ?? AccountSnapshot.unavailable(
            slot,
            identity: credential.identity.preferredDisplay,
            plan: credential.plan,
            detail: note ?? "no local quota snapshot available"
        )

        guard let memoizedProviderSnapshot else { return local }
        let localIsCurrentEnough = local.canDisplayQuotaValues
            && (local.refreshedAt ?? .distantPast)
                >= (memoizedProviderSnapshot.refreshedAt ?? .distantPast)
        guard !localIsCurrentEnough else { return local }

        var reused = memoizedProviderSnapshot
        reused.state = store.claudeSnapshotState(
            fetchedAt: memoizedProviderSnapshot.refreshedAt
        )
        let age = memoizedProviderSnapshot.refreshedAt.map { agoText($0) } ?? "an unknown time"
        reused.detail = "Provider's last confirmed reading · read \(age) ago"
        return reused
    }

    /// A compact "3h 12m"-style age, matching the phrasing `CredentialStore`
    /// uses for its own local-snapshot ages so a reused provider memo reads
    /// the same way a fresh local reading would.
    private nonisolated static func agoText(_ date: Date, now: Date = Date()) -> String {
        let totalMinutes = max(0, Int(now.timeIntervalSince(date) / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Appends a diagnostic line when LIMIT_DASHBOARD_DEBUG=1. A temporary aid
    /// for confirming which source each account resolved to.
    private nonisolated static func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["LIMIT_DASHBOARD_DEBUG"] == "1" else {
            return
        }
        let line = "\(message)\n"
        let url = URL(fileURLWithPath: "/tmp/limit-dashboard-debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// A few words naming the failure, short enough to sit on a card beside the
    /// values it explains. Without it an unreachable provider is indistinguishable
    /// from a rejected token.
    private nonisolated static func compact(_ error: Error) -> String {
        switch error {
        case ProviderAPI.RequestError.http(let code, _):
            return "HTTP \(code)"
        case ProviderAPI.RequestError.decoding:
            return "unexpected response"
        case ProviderAPI.RequestError.invalidResponse:
            return "invalid response"
        case ProviderAPI.RequestError.transport:
            return "transport unavailable"
        case let urlError as URLError:
            return "network \(urlError.errorCode)"
        default:
            return "unavailable"
        }
    }

    private nonisolated static func friendly(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        if error is URLError {
            return "The provider could not be reached. Check the network and refresh."
        }
        return "Refresh failed. The credential was not changed."
    }

    private func markDuplicateClaudeSessions(in snapshots: inout [AccountSnapshot]) {
        let claudeIndices = snapshots.indices.filter {
            snapshots[$0].slot.provider == .claude
                && snapshots[$0].state != .unavailable
                && snapshots[$0].providerAccountID != nil
        }
        let grouped = Dictionary(grouping: claudeIndices) { snapshots[$0].providerAccountID! }
        for indices in grouped.values where indices.count > 1 {
            for index in indices {
                let peer = indices.first(where: { $0 != index }).map {
                    snapshots[$0].identity
                }
                snapshots[index].duplicatePeer = peer
            }
        }
    }
}

private enum HistoryRefreshResult: Sendable {
    case success([ChartPoint], [ChartPoint])
    case failure(String)
}

