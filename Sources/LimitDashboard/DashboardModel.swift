import Combine
import Foundation

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var snapshots: [AccountSnapshot] =
        AccountSlot.configured.map(AccountSnapshot.loading)
    @Published private(set) var historySeries: [ChartSeries] =
        AccountSlot.configured.map {
            ChartSeries(
                id: $0.id,
                label: $0.configuredEmail ?? $0.localLabel,
                unit: .percentRemaining,
                points: []
            )
        }
    @Published private(set) var historyError: String?
    @Published private(set) var vertexReport: VertexReport?
    @Published private(set) var vertexError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    private var refreshInFlight = false
    private let historyStore = HistoryStore()
    private var lastVertexAttempt: Date?

    var liveCount: Int {
        snapshots.filter { $0.state == .live }.count
    }

    var issueCount: Int {
        let unavailable = snapshots.filter { $0.state == .unavailable }.count
        let unavailableQuota = snapshots.filter { $0.state == .quotaUnavailable }.count
        let hasDuplicateGroup = snapshots.contains { $0.duplicatePeer != nil }
        return unavailable + unavailableQuota + (hasDuplicateGroup ? 1 : 0)
    }

    var issueSummary: String? {
        let unavailable = snapshots.filter { $0.state == .unavailable }.count
        let unavailableQuota = snapshots.filter { $0.state == .quotaUnavailable }.count
        let duplicates = snapshots.filter { $0.duplicatePeer != nil }.count
        if unavailable == 0, unavailableQuota == 0, duplicates == 0 { return nil }

        var parts: [String] = []
        if unavailable > 0 {
            parts.append("\(unavailable) account\(unavailable == 1 ? "" : "s") unavailable")
        }
        if unavailableQuota > 0 {
            parts.append(
                "\(unavailableQuota) account\(unavailableQuota == 1 ? "" : "s") waiting for its own quota snapshot"
            )
        }
        if duplicates > 0 {
            parts.append("duplicate Claude session detected")
        }
        return parts.joined(separator: " · ")
    }

    func refresh(showActivity: Bool = false) async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        if showActivity {
            isRefreshing = true
        }
        defer {
            refreshInFlight = false
            if showActivity {
                isRefreshing = false
            }
        }

        let store = CredentialStore()
        let loaded = await Task.detached(priority: .userInitiated) {
            AccountSlot.configured.map(store.load)
        }.value
        var results: [AccountSnapshot] = []

        await withTaskGroup(of: AccountSnapshot.self) { group in
            for credential in loaded {
                group.addTask {
                    await Self.fetch(credential, store: store)
                }
            }
            for await snapshot in group {
                results.append(snapshot)
            }
        }

        results.sort { $0.slot.position < $1.slot.position }
        markDuplicateClaudeSessions(in: &results)
        let finalizedResults = results
        applyChangedSnapshots(finalizedResults)

        let capturedAt = Date()
        let historyStore = historyStore
        let historyResult = await Task.detached(
            priority: .utility
        ) { [historyStore, finalizedResults, capturedAt] in
            do {
                try historyStore.record(finalizedResults, at: capturedAt)
                let points = try historyStore.loadPrimaryPoints(
                    since: capturedAt.addingTimeInterval(-HistoryStore.chartWindow)
                )
                return HistoryRefreshResult.success(points)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Local history is temporarily unavailable."
                return HistoryRefreshResult.failure(message)
            }
        }.value
        applyHistoryResult(historyResult, snapshots: finalizedResults)

        let shouldFetchVertex = lastVertexAttempt.map {
            capturedAt.timeIntervalSince($0) >= VertexReportService.refreshInterval
        } ?? true
        if shouldFetchVertex {
            lastVertexAttempt = capturedAt
            let vertexResult = await Task.detached(priority: .utility) {
                do {
                    return VertexRefreshResult.success(
                        try VertexReportService().fetch()
                    )
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? "Vertex report is temporarily unavailable."
                    return VertexRefreshResult.failure(message)
                }
            }.value
            applyVertexResult(vertexResult)
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

    private func applyHistoryResult(
        _ result: HistoryRefreshResult,
        snapshots: [AccountSnapshot]
    ) {
        switch result {
        case .success(let points):
            let grouped = Dictionary(grouping: points, by: \.seriesID)
            let nextSeries = AccountSlot.configured.map { slot in
                let identity = snapshots.first(where: { $0.slot.id == slot.id })?.identity
                    ?? slot.configuredEmail
                    ?? slot.localLabel
                return ChartSeries(
                    id: slot.id,
                    label: identity,
                    unit: .percentRemaining,
                    points: grouped[slot.id] ?? []
                )
            }
            if historySeries != nextSeries {
                historySeries = nextSeries
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

    private func applyVertexResult(_ result: VertexRefreshResult) {
        switch result {
        case .success(let report):
            if vertexReport != report {
                vertexReport = report
            }
            if vertexError != nil {
                vertexError = nil
            }
        case .failure(let message):
            if vertexError != message {
                vertexError = message
            }
        }
    }

    private nonisolated static func fetch(
        _ loaded: LoadedCredential,
        store: CredentialStore
    ) async -> AccountSnapshot {
        let api = ProviderAPI()
        do {
            switch loaded {
            case .codex(let slot, let credential):
                return try await api.fetchCodex(slot: slot, credential: credential)
            case .failed(let slot, let identity, let message):
                if slot.provider == .claude {
                    let resolvedIdentity = identity
                        ?? LocalIdentity(email: slot.configuredEmail, displayName: nil, organizationName: nil)
                    return store.cachedClaudeSnapshot(
                        for: slot,
                        identity: resolvedIdentity
                    ) ?? AccountSnapshot.unavailable(
                        slot,
                        identity: identity?.preferredDisplay,
                        detail: message
                    )
                }
                return AccountSnapshot.unavailable(
                    slot,
                    identity: identity?.preferredDisplay,
                    detail: message
                )
            }
        } catch {
            return AccountSnapshot.unavailable(
                loaded.slot,
                detail: friendly(error)
            )
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
    case success([ChartPoint])
    case failure(String)
}

private enum VertexRefreshResult: Sendable {
    case success(VertexReport)
    case failure(String)
}
