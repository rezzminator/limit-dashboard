import Foundation

enum ProviderKind: String, Hashable, Sendable {
    case claude = "Claude"
    case codex = "Codex"
}

enum AccountState: String, Hashable, Sendable {
    case loading
    case live
    case cached
    case stale
    case quotaUnavailable
    case unavailable

    var title: String {
        switch self {
        case .loading: "Refreshing"
        case .live: "Live"
        case .cached: "Cached"
        case .stale: "Aged"
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
            id: "claude-1",
            provider: .claude,
            title: "Claude Account 1",
            localLabel: "account 1",
            configuredEmail: nil,
            claudeStatePath: ".claude.json",
            position: 0
        ),
        AccountSlot(
            id: "claude-2",
            provider: .claude,
            title: "Claude Account 2",
            localLabel: "account 2",
            configuredEmail: nil,
            claudeStatePath: ".claude2/.claude.json",
            position: 1
        ),
        AccountSlot(
            id: "claude-3",
            provider: .claude,
            title: "Claude Account 3",
            localLabel: "account 3",
            configuredEmail: nil,
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

    // Every window that survives into a snapshot has already been checked
    // against its own `resets_at`, so a window that is present is a window whose
    // provider reset has not happened yet. An observation of an active window
    // stays meaningful as it ages — usage inside one window never moves
    // backward, so an old reading is a valid lower bound, not a wrong number.
    // Values are therefore withheld only when there is no active window left.
    var canDisplayQuotaValues: Bool {
        switch state {
        case .live, .cached, .stale:
            !windows.isEmpty
        case .loading, .quotaUnavailable, .unavailable:
            false
        }
    }

    /// True when the newest values are old enough that usage may have grown
    /// since. The card shows the numbers as a lower bound and states the age.
    var showsAgedValues: Bool {
        state == .stale && !windows.isEmpty
    }

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
        detail: String,
        refreshedAt: Date? = Date()
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
            refreshedAt: refreshedAt,
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

/// A Claude OAuth session read from the login Keychain. The token is held in
/// memory for the duration of one request and is never logged or persisted.
struct ClaudeCredential: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let identity: LocalIdentity
    let plan: String
    let providerAccountID: String?
    /// Present so an expired session can be exchanged for a new one. It is held
    /// only for the length of that exchange and is never logged or displayed.
    var refreshToken: String?

    func isUsable(now: Date = Date()) -> Bool {
        guard !accessToken.isEmpty else { return false }
        // Refreshing is Claude Code's job. An expired token is left alone and
        // the dashboard falls back to the local snapshot instead.
        guard let expiresAt else { return true }
        return expiresAt > now
    }
}

enum LoadedCredential: Sendable {
    case codex(AccountSlot, CodexCredential)
    case claude(AccountSlot, ClaudeCredential)
    case failed(AccountSlot, LocalIdentity?, String)

    var slot: AccountSlot {
        switch self {
        case .codex(let slot, _), .claude(let slot, _), .failed(let slot, _, _):
            slot
        }
    }
}
