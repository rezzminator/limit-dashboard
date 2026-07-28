import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @AppStorage("refreshIntervalSeconds") private var refreshIntervalSeconds =
        RefreshPolicy.defaultSeconds

    private var validatedInterval: Int {
        RefreshPolicy.validated(refreshIntervalSeconds)
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { validatedInterval },
            set: { refreshIntervalSeconds = RefreshPolicy.validated($0) }
        )
    }

    var body: some View {
        ZStack {
            DashboardBackground()

            VStack(alignment: .leading, spacing: 18) {
                header

                if let issue = model.issueSummary {
                    IssueBanner(text: issue)
                }

                Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                    GridRow {
                        AccountCard(snapshot: model.snapshots[0])
                        AccountCard(snapshot: model.snapshots[1])
                    }
                    GridRow {
                        AccountCard(snapshot: model.snapshots[2])
                        AccountCard(snapshot: model.snapshots[3])
                    }
                }
                .frame(maxHeight: .infinity)

                footer
            }
            .padding(26)
        }
        .frame(minWidth: 920, minHeight: 720)
        .onAppear {
            refreshIntervalSeconds = validatedInterval
        }
        .task(id: validatedInterval) {
            await model.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(validatedInterval))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await model.refresh()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Account limits")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("One quiet view of every local subscription.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HeaderStat(value: "\(model.liveCount)", label: "Live")
            HeaderStat(value: "\(model.issueCount)", label: "Issues")
            RefreshIntervalControl(seconds: intervalBinding)

            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(minWidth: 82)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isRefreshing)
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text("Codex stays local; Claude reads cached profile snapshots only.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if let lastUpdated = model.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct DashboardBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(red: 0.055, green: 0.075, blue: 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.cyan.opacity(0.08))
                .frame(width: 420, height: 420)
                .blur(radius: 90)
                .offset(x: 100, y: -180)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(Color.orange.opacity(0.06))
                .frame(width: 360, height: 360)
                .blur(radius: 90)
                .offset(x: -120, y: 170)
        }
    }
}

private struct HeaderStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .frame(width: 58, height: 48)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct IssueBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("Cards below explain what needs attention.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 15)
        .frame(height: 46)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.22))
        }
    }
}

private struct AccountCard: View {
    let snapshot: AccountSnapshot

    private var accent: Color {
        snapshot.slot.provider == .claude
            ? Color(red: 0.84, green: 0.38, blue: 0.23)
            : Color(red: 0.15, green: 0.68, blue: 0.53)
    }

    private var headlineWindow: UsageWindow? {
        snapshot.windows.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                ProviderIcon(provider: snapshot.slot.provider, accent: accent)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(snapshot.slot.title)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        PlanBadge(text: snapshot.plan)
                    }
                    Text(snapshot.identity)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
                StateBadge(state: snapshot.state)
            }

            if snapshot.state == .loading {
                loadingContent
            } else if let headlineWindow {
                usageContent(headlineWindow)
            } else {
                unavailableContent
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), accent.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .shadow(color: Color.black.opacity(0.14), radius: 20, y: 8)
    }

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 138, height: 32)
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.10))
                .frame(height: 10)
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.08))
                .frame(width: 190, height: 10)
            Spacer()
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Reading local session")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .redacted(reason: .placeholder)
    }

    private func usageContent(_ headline: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(headline.remainingPercent.rounded()))%")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("remaining")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let resetAt = headline.resetAt {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(headline.title.uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                        Text("resets \(compactReset(resetAt))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(snapshot.windows.prefix(2)) { window in
                LimitRow(window: window, accent: accent)
            }
            if snapshot.slot.provider == .claude {
                ExtraUsageRow(info: snapshot.extraUsage ?? .unavailable, accent: accent)
            }

            Spacer(minLength: 0)

            if snapshot.state == .cached || snapshot.duplicatePeer != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if snapshot.state == .cached, let detail = snapshot.detail {
                        DetailStrip(
                            icon: "key.slash",
                            text: detail,
                            color: .orange
                        )
                    }
                    if let peer = snapshot.duplicatePeer {
                        DetailStrip(
                            icon: "person.2.badge.gearshape",
                            text: "Same provider account as \(peer)",
                            color: .orange
                        )
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(accent)
                        .frame(width: 5, height: 5)
                    Text(snapshot.state == .live ? "Provider confirmed" : "Last known value")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            Spacer(minLength: 2)
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.orange)
            Text("Session needs attention")
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Text(snapshot.detail ?? "This account could not be refreshed.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if snapshot.slot.provider == .claude {
                ExtraUsageRow(info: snapshot.extraUsage ?? .unavailable, accent: accent)
            }
            Spacer()
            Text(snapshot.slot.provider == .claude
                 ? "Cached-only mode. No Keychain request will be made."
                 : "Open Codex and sign in again.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
        }
    }

    private func compactReset(_ date: Date) -> String {
        let totalMinutes = max(0, Int(date.timeIntervalSinceNow / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}

private struct RefreshIntervalControl: View {
    @Binding var seconds: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("Every")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("20", value: $seconds, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 48)
                .accessibilityLabel("Automatic refresh interval in seconds")
            Text("sec")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Stepper(
                "Refresh interval",
                value: $seconds,
                in: RefreshPolicy.allowedSeconds,
                step: 5
            )
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .help("Automatic refresh interval: 10–3600 seconds. The choice is saved.")
    }
}

private struct ProviderIcon: View {
    let provider: ProviderKind
    let accent: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.95), accent.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: provider == .claude ? "sparkles" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 42, height: 42)
        .shadow(color: accent.opacity(0.24), radius: 9, y: 4)
    }
}

private struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

private struct StateBadge: View {
    let state: AccountState

    private var color: Color {
        switch state {
        case .live: .green
        case .cached: .orange
        case .loading: .blue
        case .unavailable: .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(state.title)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
    }
}

private struct LimitRow: View {
    let window: UsageWindow
    let accent: Color

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(window.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.72), accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * window.remainingPercent / 100)
                }
            }
            .frame(height: 7)
        }
    }
}

private struct ExtraUsageRow: View {
    let info: ExtraUsageInfo
    let accent: Color

    private var statusColor: Color {
        switch info.state {
        case .available: accent
        case .disabled: .secondary
        case .unavailable: .orange
        }
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(statusColor)
                Text("Extra usage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(info.status)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(statusColor)
            }

            if let remaining = info.remainingPercent {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [accent.opacity(0.72), accent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: proxy.size.width * remaining / 100)
                    }
                }
                .frame(height: 7)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            statusColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

private struct DetailStrip: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
