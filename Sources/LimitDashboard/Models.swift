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
    /// Home-relative Claude config directory (e.g. ".claude", ".claude2").
    /// `nil` for Codex, which has no per-account directory of its own.
    let configDirectory: String?
    let position: Int

    /// Home-relative path to this account's `.claude.json` registry. The
    /// default directory keeps its registry at the home root beside it rather
    /// than inside it — Claude Code carries this special case forward from
    /// when only one config directory existed.
    var claudeStatePath: String? {
        guard let configDirectory else { return nil }
        return configDirectory == ".claude"
            ? ".claude.json"
            : "\(configDirectory)/.claude.json"
    }

    /// The account number the status-line harvester stamps into its file
    /// names — the trailing integer of the config directory name, or 1 for
    /// the bare ".claude". Harvest-file matching keys off this rather than
    /// array position, so disabling one account cannot shift another's
    /// harvest mapping onto the wrong slot.
    var statusLineSlot: Int? {
        guard let configDirectory else { return nil }
        if configDirectory == ".claude" { return 1 }
        let trailingDigits = String(
            configDirectory.reversed().prefix(while: \.isNumber).reversed()
        )
        return trailingDigits.isEmpty ? nil : Int(trailingDigits)
    }

    static let defaultSlots: [AccountSlot] = [
        AccountSlot(
            id: "claude-1",
            provider: .claude,
            title: "Claude Account 1",
            localLabel: "account 1",
            configuredEmail: nil,
            configDirectory: ".claude",
            position: 0
        ),
        AccountSlot(
            id: "claude-2",
            provider: .claude,
            title: "Claude Account 2",
            localLabel: "account 2",
            configuredEmail: nil,
            configDirectory: ".claude2",
            position: 1
        ),
        AccountSlot(
            id: "claude-3",
            provider: .claude,
            title: "Claude Account 3",
            localLabel: "account 3",
            configuredEmail: nil,
            configDirectory: ".claude3",
            position: 2
        ),
        AccountSlot(
            id: "codex-primary",
            provider: .codex,
            title: "Codex",
            localLabel: "primary",
            configuredEmail: nil,
            configDirectory: nil,
            position: 3
        )
    ]

    /// Accounts come from `~/.config/limit-dashboard/accounts.json` when that
    /// file exists and decodes to at least one entry, so a checkout of this
    /// repository names nobody's accounts. A missing file or one that fails to
    /// decode falls back to the four historical slots, so chart history keyed
    /// by their ids keeps its series. A file that decodes but disables every
    /// entry is a deliberate "nothing enabled" state, not a decode failure, so
    /// it returns an empty list rather than falling back — callers must
    /// tolerate zero slots.
    static func loadConfigured(
        from url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/limit-dashboard/accounts.json")
    ) -> [AccountSlot] {
        struct Stored: Decodable {
            let id: String
            let provider: String
            let label: String
            let configDirectory: String?
            let email: String?
            let enabled: Bool?
        }
        guard
            let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode([Stored].self, from: data),
            !stored.isEmpty
        else {
            return defaultSlots
        }
        return stored
            .filter { $0.enabled ?? true }
            .enumerated()
            .map { index, entry in
                AccountSlot(
                    id: entry.id,
                    provider: entry.provider == "codex" ? .codex : .claude,
                    title: entry.label,
                    localLabel: entry.label.lowercased(),
                    configuredEmail: entry.email,
                    configDirectory: entry.configDirectory,
                    position: index
                )
            }
    }
}

struct UsageWindow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetAt: Date?

    var normalizedUsedPercent: Double {
        max(0, min(100, usedPercent))
    }

    /// What is still available in the window. Every bar in the dashboard is
    /// drawn from this, not from the used share: a quota reads like a tank, so
    /// the bar starts full on a fresh window and drains towards empty as it is
    /// spent. Filling by used-% would have shown an empty bar for the state
    /// with the most headroom.
    var remainingPercent: Double {
        100 - normalizedUsedPercent
    }

    /// The only quota figure the dashboard renders. Providers report usage as a
    /// spent share, but showing both halves of the same fact put two numbers on
    /// every row that had to be read against each other; the app states one.
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
