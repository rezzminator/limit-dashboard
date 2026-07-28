import Foundation

enum ProviderKind: String, Sendable {
    case claude = "Claude"
    case codex = "Codex"
}

enum AccountState: String, Sendable {
    case loading
    case live
    case cached
    case unavailable

    var title: String {
        switch self {
        case .loading: "Refreshing"
        case .live: "Live"
        case .cached: "Cached"
        case .unavailable: "Unavailable"
        }
    }
}

enum RefreshPolicy {
    static let defaultSeconds = 20
    static let allowedSeconds = 10...3_600

    static func validated(_ seconds: Int) -> Int {
        min(max(seconds, allowedSeconds.lowerBound), allowedSeconds.upperBound)
    }
}

struct AccountSlot: Identifiable, Hashable, Sendable {
    let id: String
    let provider: ProviderKind
    let title: String
    let localLabel: String
    let configuredEmail: String?
    let profileDirectory: String?
    let position: Int

    static let configured: [AccountSlot] = [
        AccountSlot(
            id: "claude-gmail",
            provider: .claude,
            title: "Claude",
            localLabel: "gmail",
            configuredEmail: "mrez9090@gmail.com",
            profileDirectory: ".claude",
            position: 0
        ),
        AccountSlot(
            id: "claude-freudche",
            provider: .claude,
            title: "Claude",
            localLabel: "freudche",
            configuredEmail: "reza@freudche.com",
            profileDirectory: ".claude2",
            position: 1
        ),
        AccountSlot(
            id: "claude-khosravi",
            provider: .claude,
            title: "Claude",
            localLabel: "khosravi",
            configuredEmail: "reza.khosravivala@gmail.com",
            profileDirectory: ".claude3",
            position: 2
        ),
        AccountSlot(
            id: "codex-primary",
            provider: .codex,
            title: "Codex",
            localLabel: "primary",
            configuredEmail: nil,
            profileDirectory: nil,
            position: 3
        )
    ]
}

struct UsageWindow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetAt: Date?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

enum ExtraUsageState: Equatable, Sendable {
    case available
    case disabled
    case unavailable
}

struct ExtraUsageInfo: Sendable {
    let state: ExtraUsageState
    let usedPercent: Double?
    let status: String

    var remainingPercent: Double? {
        usedPercent.map { max(0, min(100, 100 - $0)) }
    }

    static let unavailable = ExtraUsageInfo(
        state: .unavailable,
        usedPercent: nil,
        status: "Unavailable in local cache"
    )
}

struct AccountSnapshot: Identifiable, Sendable {
    let id: String
    let slot: AccountSlot
    var identity: String
    var plan: String
    var state: AccountState
    var windows: [UsageWindow]
    var extraUsage: ExtraUsageInfo?
    var providerAccountID: String?
    var detail: String?
    var refreshedAt: Date?
    var duplicatePeer: String?

    static func loading(_ slot: AccountSlot) -> AccountSnapshot {
        AccountSnapshot(
            id: slot.id,
            slot: slot,
            identity: slot.localLabel,
            plan: "Checking",
            state: .loading,
            windows: [],
            extraUsage: nil,
            providerAccountID: nil,
            detail: nil,
            refreshedAt: nil,
            duplicatePeer: nil
        )
    }

    static func unavailable(
        _ slot: AccountSlot,
        identity: String? = nil,
        plan: String = "Local session",
        detail: String
    ) -> AccountSnapshot {
        AccountSnapshot(
            id: slot.id,
            slot: slot,
            identity: identity ?? slot.localLabel,
            plan: plan,
            state: .unavailable,
            windows: [],
            extraUsage: slot.provider == .claude ? .unavailable : nil,
            providerAccountID: nil,
            detail: detail,
            refreshedAt: Date(),
            duplicatePeer: nil
        )
    }
}

struct LocalIdentity: Sendable {
    let email: String?
    let displayName: String?
    let organizationName: String?

    var preferredDisplay: String? {
        email ?? displayName
    }
}

struct CodexCredential: Sendable {
    let accessToken: String
    let accountID: String
    let identity: LocalIdentity
}

enum LoadedCredential: Sendable {
    case codex(AccountSlot, CodexCredential)
    case failed(AccountSlot, LocalIdentity?, String)

    var slot: AccountSlot {
        switch self {
        case .codex(let slot, _), .failed(let slot, _, _):
            slot
        }
    }
}
