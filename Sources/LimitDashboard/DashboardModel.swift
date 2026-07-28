import Combine
import Foundation

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var snapshots: [AccountSnapshot] =
        AccountSlot.configured.map(AccountSnapshot.loading)
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    var liveCount: Int {
        snapshots.filter { $0.state == .live }.count
    }

    var issueCount: Int {
        let unavailable = snapshots.filter { $0.state == .unavailable }.count
        let hasDuplicateGroup = snapshots.contains { $0.duplicatePeer != nil }
        return unavailable + (hasDuplicateGroup ? 1 : 0)
    }

    var issueSummary: String? {
        let unavailable = snapshots.filter { $0.state == .unavailable }.count
        let duplicates = snapshots.filter { $0.duplicatePeer != nil }.count
        if unavailable == 0, duplicates == 0 { return nil }

        var parts: [String] = []
        if unavailable > 0 {
            parts.append("\(unavailable) account\(unavailable == 1 ? "" : "s") unavailable")
        }
        if duplicates > 0 {
            parts.append("duplicate Claude session detected")
        }
        return parts.joined(separator: " · ")
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        snapshots = snapshots.map {
            var copy = $0
            copy.state = .loading
            return copy
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
        snapshots = results
        lastUpdated = Date()
        isRefreshing = false
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
                        identity: resolvedIdentity,
                        detail: "Keychain access not granted · showing local cache"
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
