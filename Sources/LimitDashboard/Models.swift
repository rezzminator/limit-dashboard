import Foundation

enum ProviderKind: String, Hashable, Sendable {
    case claude = "Claude"
    case codex = "Codex"
}

enum AccountState: String, Hashable, Sendable {
    case loading
    case live
    case cached
    case quotaUnavailable
    case unavailable

    var title: String {
        switch self {
        case .loading: "Refreshing"
        case .live: "Live"
        case .cached: "Cached"
        case .quotaUnavailable: "Quota unavailable"
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
    let claudeStatePath: String?
    let position: Int

    static let configured: [AccountSlot] = [
        AccountSlot(
            id: "claude-gmail",
            provider: .claude,
            title: "Claude Account 1",
            localLabel: "account 1",
            configuredEmail: "mrez9090@gmail.com",
            claudeStatePath: ".claude.json",
            position: 0
        ),
        AccountSlot(
            id: "claude-freudche",
            provider: .claude,
            title: "Claude Account 2",
            localLabel: "account 2",
            configuredEmail: "reza.khosravivala@gmail.com",
            claudeStatePath: ".claude2/.claude.json",
            position: 1
        ),
        AccountSlot(
            id: "claude-khosravi",
            provider: .claude,
            title: "Claude Account 3",
            localLabel: "account 3",
            configuredEmail: "reza@intuita.health",
            claudeStatePath: ".claude3/.claude.json",
            position: 2
        ),
        AccountSlot(
            id: "codex-primary",
            provider: .codex,
            title: "Codex",
            localLabel: "primary",
            configuredEmail: nil,
            claudeStatePath: nil,
            position: 3
        )
    ]
}

struct UsageWindow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetAt: Date?

    var normalizedUsedPercent: Double {
        max(0, min(100, usedPercent))
    }

    var remainingPercent: Double {
        100 - normalizedUsedPercent
    }

    var usedLabel: String {
        "\(Int(normalizedUsedPercent.rounded()))% used"
    }

    var remainingLabel: String {
        "\(Int(remainingPercent.rounded()))% remaining"
    }
}

enum ResetCountdown {
    static func compact(until resetAt: Date, now: Date = Date()) -> String {
        let remainingSeconds = max(0, resetAt.timeIntervalSince(now))
        let totalMinutes = remainingSeconds > 0
            ? Int(ceil(remainingSeconds / 60))
            : 0
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        return String(format: "%dD %02dH %02dM", days, hours, minutes)
    }

    static func accessibilityText(
        until resetAt: Date,
        now: Date = Date()
    ) -> String {
        let remainingSeconds = max(0, resetAt.timeIntervalSince(now))
        let totalMinutes = remainingSeconds > 0
            ? Int(ceil(remainingSeconds / 60))
            : 0
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        return [
            spoken(days, unit: "day"),
            spoken(hours, unit: "hour"),
            spoken(minutes, unit: "minute"),
        ].joined(separator: ", ")
    }

    private static func spoken(_ value: Int, unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s")"
    }
}

struct AccountSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let slot: AccountSlot
    var identity: String
    var plan: String
    var state: AccountState
    var windows: [UsageWindow]
    var fableUsage: UsageWindow?
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
            fableUsage: nil,
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
            fableUsage: nil,
            providerAccountID: nil,
            detail: detail,
            refreshedAt: Date(),
            duplicatePeer: nil
        )
    }

    static func quotaUnavailable(
        _ slot: AccountSlot,
        identity: String,
        plan: String,
        detail: String
    ) -> AccountSnapshot {
        AccountSnapshot(
            id: slot.id,
            slot: slot,
            identity: identity,
            plan: plan,
            state: .quotaUnavailable,
            windows: [],
            fableUsage: nil,
            providerAccountID: nil,
            detail: detail,
            refreshedAt: Date(),
            duplicatePeer: nil
        )
    }

    // `refreshedAt` is intentionally excluded. Polling the same visible values
    // should not publish a new card or disturb SwiftUI view identity.
    static func == (lhs: AccountSnapshot, rhs: AccountSnapshot) -> Bool {
        lhs.id == rhs.id
            && lhs.slot == rhs.slot
            && lhs.identity == rhs.identity
            && lhs.plan == rhs.plan
            && lhs.state == rhs.state
            && lhs.windows == rhs.windows
            && lhs.fableUsage == rhs.fableUsage
            && lhs.providerAccountID == rhs.providerAccountID
            && lhs.detail == rhs.detail
            && lhs.duplicatePeer == rhs.duplicatePeer
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
