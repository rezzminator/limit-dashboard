import AppKit
import Charts
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @AppStorage("refreshIntervalSeconds") private var refreshIntervalSeconds =
        RefreshPolicy.defaultSeconds
    // The panels below declare fixed minimum heights, so the window has to be
    // tall enough to hold their sum plus spacing and padding. When it was not,
    // SwiftUI compressed the stack and clipped the header title.
    @ScaledMetric(relativeTo: .body) private var minimumDashboardHeight: CGFloat =
        1_228

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

            VStack(alignment: .leading, spacing: 10) {
                header

                if let issue = model.issueSummary {
                    IssueBanner(text: issue)
                }

                HistoryChart(
                    series: model.historySeries,
                    error: model.historyError
                )
                .equatable()

                CodexPanel(
                    snapshot: model.codexSnapshot,
                    series: model.codexSeries
                )
                .equatable()

                VertexCard(accounts: model.vertexReports)
                    .equatable()

                let claudeCards = model.claudeSnapshots
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(
                        Array(stride(from: 0, to: claudeCards.count, by: 2)),
                        id: \.self
                    ) { first in
                        GridRow(alignment: .top) {
                            if claudeCards.indices.contains(first + 1) {
                                AccountCard(snapshot: claudeCards[first])
                                    .equatable()
                                AccountCard(snapshot: claudeCards[first + 1])
                                    .equatable()
                            } else {
                                // An odd final card claims the whole row rather
                                // than leaving a hole beside it.
                                AccountCard(snapshot: claudeCards[first])
                                    .equatable()
                                    .gridCellColumns(2)
                            }
                        }
                    }
                }

                Spacer(minLength: 12)

                footer
            }
            .padding(14)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
        }
        .frame(minWidth: 920, minHeight: minimumDashboardHeight)
        .background(WindowFocusResetter())
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
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.95),
                                    Color.cyan.opacity(0.64),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .shadow(color: Color.accentColor.opacity(0.24), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Account limits")
                        .font(
                            .system(
                                .largeTitle,
                                design: .rounded,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(.primary)
                    Text("One quiet view of every local subscription.")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HeaderStat(value: "\(model.liveCount)", label: "Live")
            HeaderStat(value: "\(model.issueCount)", label: "Issues")
            RefreshIntervalControl(seconds: intervalBinding)

            Button {
                Task { await model.refresh(showActivity: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.body.weight(.semibold))
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
            Text("Runs entirely on this Mac, reading only your own signed-in sessions.")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            } else if let lastUpdated = model.lastUpdated {
                Text("Checked \(lastUpdated, style: .relative)")
                    .font(.callout.weight(.medium))
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
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text(label.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .frame(width: 58, height: 48)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(0.10))
        }
    }
}

private struct IssueBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.body.weight(.semibold))
            Spacer()
            Text("Cards below explain what needs attention.")
                .font(.callout.weight(.medium))
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

private struct PanelSurface: ViewModifier {
    let accent: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )

        content
            .background {
                ZStack {
                    shape.fill(.thinMaterial)
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.035),
                                accent.opacity(0.045),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.16),
                            accent.opacity(0.16),
                            Color.white.opacity(0.055),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: Color.black.opacity(0.13), radius: 14, y: 7)
    }
}

private extension View {
    func panelSurface(
        accent: Color,
        cornerRadius: CGFloat = 16
    ) -> some View {
        modifier(
            PanelSurface(accent: accent, cornerRadius: cornerRadius)
        )
    }
}

private struct HistoryChart: View, Equatable {
    let series: [ChartSeries]
    let error: String?
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 125
    @ScaledMetric(relativeTo: .body) private var idealHeight: CGFloat = 145
    @ScaledMetric(relativeTo: .body) private var maximumHeight: CGFloat = 155

    nonisolated static func == (lhs: HistoryChart, rhs: HistoryChart) -> Bool {
        lhs.series == rhs.series
            && lhs.error == rhs.error
    }

    private var hasPoints: Bool {
        series.contains { !$0.points.isEmpty }
    }

    private var allPoints: [ChartPoint] {
        series.flatMap(\.points)
    }

    private var firstMeasurement: Date? {
        allPoints.map(\.timestamp).min()
    }

    /// Ends the axis a little past the newest measurement. A tick that lands on
    /// the trailing edge has its centred label truncated by the plot bounds, so
    /// the domain reserves proportional room for it.
    private var historyEnd: Date {
        let latest = allPoints.map(\.timestamp).max() ?? Date()
        return latest.addingTimeInterval(
            max(
                TimeInterval(HistoryStore.chartBucketSeconds),
                HistoryStore.chartWindow * 0.04
            )
        )
    }

    private var historyStart: Date {
        historyEnd.addingTimeInterval(-HistoryStore.chartWindow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.indigo)
                        .frame(width: 26, height: 26)
                        .background(Color.indigo.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude quota window state")
                            .font(
                                .system(
                                    .title3,
                                    design: .rounded,
                                    weight: .bold
                                )
                            )
                        if let error {
                            Text(error)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.orange)
                        } else if let firstMeasurement {
                            Text(
                                "Saved remaining-% snapshots · not token activity · begins \(firstMeasurement, style: .time)"
                            )
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        } else {
                            Text("No saved measurements yet")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                historyLegend
            }

            Text("CLAUDE 5-HOUR WINDOW QUOTA REMAINING · 24H")
                .font(.caption2.weight(.heavy))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            if hasPoints {
                Chart {
                    ForEach(series) { account in
                        ForEach(account.points) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Quota remaining", point.value),
                                series: .value("Account", account.id)
                            )
                            .foregroundStyle(color(for: account.id))
                            .lineStyle(.init(lineWidth: 2.2, lineCap: .round))
                            .interpolationMethod(.linear)

                            PointMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Quota remaining", point.value)
                            )
                            .foregroundStyle(color(for: account.id))
                            .symbolSize(18)
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: historyStart...historyEnd)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                        AxisGridLine()
                            .foregroundStyle(Color.secondary.opacity(0.12))
                        AxisValueLabel {
                            if let percent = value.as(Int.self) {
                                Text("\(percent)%")
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine()
                            .foregroundStyle(Color.secondary.opacity(0.08))
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartLegend(.hidden)
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(Color.white.opacity(0.018))
                        .clipShape(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                // The final tick sits on the plot's trailing edge and its label
                // is centred on it, so it needs room to render in full.
                .padding(.trailing, 16)
            } else {
                Text("History begins with real local quota-state snapshots.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .center
                    )
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(
            minHeight: minimumHeight,
            idealHeight: idealHeight,
            maxHeight: maximumHeight
        )
        .panelSurface(accent: .indigo)
    }

    private var historyLegend: some View {
        HStack(spacing: 11) {
            ForEach(series) { account in
                HStack(spacing: 4) {
                    Circle()
                        .fill(color(for: account.id))
                        .frame(width: 6, height: 6)
                    Text(account.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                }
            }
        }
    }

    private func color(for slotID: String) -> Color {
        switch slotID {
        case "claude-1":
            Color(red: 0.96, green: 0.34, blue: 0.24)
        case "claude-2":
            Color(red: 0.96, green: 0.68, blue: 0.20)
        case "claude-3":
            Color(red: 0.65, green: 0.42, blue: 0.95)
        default:
            Color(red: 0.16, green: 0.78, blue: 0.63)
        }
    }
}

/// One card for every authenticated Vertex account: a single plot carrying one
/// line per account, and one stat lane per account beneath it. The accounts
/// share a token axis on purpose — the comparison between projects is the point
/// — and each lane states its own totals so a smaller project is still readable
/// as a number even when its line sits low.
private struct VertexCard: View, Equatable {
    let accounts: [VertexAccountReport]
    // Two 44pt lanes plus the plot and its axis labels.
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 262
    @ScaledMetric(relativeTo: .body) private var idealHeight: CGFloat = 274
    @ScaledMetric(relativeTo: .body) private var maximumHeight: CGFloat = 286

    nonisolated static func == (lhs: VertexCard, rhs: VertexCard) -> Bool {
        lhs.accounts == rhs.accounts
    }

    private var plotted: [VertexAccountReport] {
        accounts.filter { $0.report != nil }
    }

    private var hasReportedActivity: Bool {
        plotted.contains { $0.report?.hasChartActivity == true }
    }

    private var axisMaximum: Double {
        max(
            1,
            plotted.compactMap { $0.report?.series.points.map(\.value).max() }
                .max() ?? 0
        )
    }

    private var axisDomain: ClosedRange<Double> {
        hasReportedActivity ? 0...axisMaximum : -0.08...1
    }

    private var chartStart: Date {
        plotted.compactMap { $0.report?.chartStart }.min()
            ?? Date().addingTimeInterval(-30 * 24 * 60 * 60)
    }

    private var chartEnd: Date {
        plotted.compactMap { $0.report?.chartEnd }.max() ?? Date()
    }

    private func color(for account: VertexAccount) -> Color {
        let index = VertexAccount.configured.firstIndex(of: account) ?? 0
        switch index {
        case 0: return Color.blue
        case 1: return Color(red: 0.88, green: 0.48, blue: 0.84)
        default: return Color(red: 0.36, green: 0.82, blue: 0.74)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.blue)
                            .frame(width: 26, height: 26)
                            .background(Color.blue.opacity(0.12), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vertex AI token usage")
                                .font(
                                    .system(
                                        .title3,
                                        design: .rounded,
                                        weight: .bold
                                    )
                                )
                            Text(statusText)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(statusColor)
                        }
                    }
                    Spacer()
                    HStack(spacing: 11) {
                        ForEach(accounts) { entry in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(color(for: entry.account))
                                    .frame(width: 6, height: 6)
                                Text(entry.account.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Text(chartWindowLabel)
                    .font(.caption2.weight(.heavy))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                if plotted.isEmpty {
                    Text(
                        accounts.compactMap(\.error).first
                            ?? "Loading actual Cloud Monitoring token buckets…"
                    )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(
                        accounts.contains { $0.error != nil }
                            ? Color.orange
                            : Color.secondary
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .center
                    )
                } else {
                    Chart {
                        ForEach(plotted) { entry in
                            if let report = entry.report {
                                ForEach(report.series.points) { point in
                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("Tokens", point.value),
                                        series: .value(
                                            "Account",
                                            entry.account.id
                                        )
                                    )
                                    .foregroundStyle(color(for: entry.account))
                                    .lineStyle(
                                        .init(lineWidth: 2.2, lineCap: .round)
                                    )
                                    .interpolationMethod(.linear)

                                    PointMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("Tokens", point.value)
                                    )
                                    .foregroundStyle(color(for: entry.account))
                                    .symbolSize(hasReportedActivity ? 10 : 20)
                                }
                            }
                        }
                    }
                    .chartXScale(domain: chartStart...chartEnd)
                    .chartYScale(domain: axisDomain)
                    .chartYAxis {
                        if hasReportedActivity {
                            AxisMarks(
                                position: .leading,
                                values: .automatic(desiredCount: 3)
                            ) { value in
                                AxisGridLine()
                                    .foregroundStyle(Color.secondary.opacity(0.12))
                                AxisValueLabel {
                                    if let tokens = value.as(Double.self) {
                                        Text(compactTokens(tokens))
                                    }
                                }
                            }
                        } else {
                            AxisMarks(position: .leading, values: [0]) {
                                AxisGridLine()
                                    .foregroundStyle(Color.secondary.opacity(0.12))
                                AxisValueLabel("0")
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) {
                            AxisGridLine()
                                .foregroundStyle(Color.secondary.opacity(0.08))
                            AxisValueLabel(format: .dateTime.month().day())
                        }
                    }
                    .chartLegend(.hidden)
                    .chartPlotStyle { plotArea in
                        plotArea
                            .background(Color.blue.opacity(0.025))
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 8,
                                    style: .continuous
                                )
                            )
                    }
                    .padding(.trailing, 16)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(minHeight: 110, maxHeight: .infinity)

            Divider()
                .overlay(Color.white.opacity(0.10))
                .padding(.horizontal, 13)

            VStack(spacing: 0) {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider()
                            .overlay(Color.white.opacity(0.06))
                            .padding(.horizontal, 13)
                    }
                    VertexAccountLane(
                        entry: entry,
                        accent: color(for: entry.account)
                    )
                }
            }
        }
        .frame(
            minHeight: minimumHeight,
            idealHeight: idealHeight,
            maxHeight: maximumHeight
        )
        .panelSurface(accent: .blue)
    }

    private var statusText: String {
        let failed = accounts.filter { $0.error != nil }
        if !failed.isEmpty, plotted.isEmpty {
            return failed[0].error ?? "Vertex report is unavailable."
        }
        if !failed.isEmpty {
            return "\(failed.count) account\(failed.count == 1 ? "" : "s") unavailable · see the lane below"
        }
        if plotted.isEmpty {
            return "Reading local authenticated Cloud Monitoring data"
        }
        if !hasReportedActivity {
            return "No tokens reported in this window · zero is a valid measurement"
        }
        return "Actual Cloud Monitoring token totals"
    }

    private var statusColor: Color {
        accounts.contains { $0.error != nil } ? .orange : .secondary
    }

    private var chartWindowLabel: String {
        guard let report = plotted.first?.report else {
            return "VERTEX TOKEN TOTALS"
        }
        return "VERTEX TOKEN TOTALS · \(durationLabel(from: report.chartStart, to: report.chartEnd)) · \(durationLabel(seconds: report.chartBucketSeconds)) SUM BUCKETS · SHARED TOKEN AXIS"
    }

    private func durationLabel(from start: Date, to end: Date) -> String {
        durationLabel(
            seconds: max(0, Int(end.timeIntervalSince(start).rounded()))
        )
    }

    private func durationLabel(seconds: Int) -> String {
        if seconds.isMultiple(of: 86_400) {
            return "\(seconds / 86_400)D"
        }
        if seconds.isMultiple(of: 3_600) {
            return "\(seconds / 3_600)H"
        }
        if seconds.isMultiple(of: 60) {
            return "\(seconds / 60)M"
        }
        return "\(seconds)S"
    }

    private func compactTokens(_ value: Double) -> String {
        Int64(value.rounded()).formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
        )
    }
}

/// One account's numbers, read left to right: which account, what it is
/// estimated to cost, and the token totals behind that estimate.
private struct VertexAccountLane: View {
    let entry: VertexAccountReport
    let accent: Color
    @ScaledMetric(relativeTo: .body) private var laneHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 0) {
                Text(entry.account.label)
                    .font(.callout.weight(.bold))
                    .lineLimit(1)
                Text(projectLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 152, alignment: .leading)

            if let report = entry.report {
                VStack(alignment: .leading, spacing: 0) {
                    if let estimatedEUR = report.estimatedEUR {
                        Text(
                            "~€\(estimatedEUR, format: .number.precision(.fractionLength(2)))"
                        )
                        .font(
                            .system(
                                .title3,
                                design: .rounded,
                                weight: .bold
                            )
                        )
                        .lineLimit(1)
                    } else {
                        Text("Unavailable")
                            .font(.callout.weight(.bold))
                    }
                    Text("est. list price · not an invoice")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                .frame(width: 168, alignment: .leading)

                stat("Input", compactTokens(report.totals.input))
                stat("Output", compactTokens(report.totals.output))
                stat("Total", compactTokens(report.totals.total))

                Spacer(minLength: 4)

                if !report.pricingWarnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(report.pricingWarnings.joined(separator: "\n"))
                }
            } else {
                Text(entry.error ?? "Loading one local Monitoring summary…")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(
                        entry.error == nil ? Color.secondary : Color.orange
                    )
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: laneHeight)
    }

    private var projectLabel: String {
        entry.report?.project
            ?? entry.account.project
            ?? "active gcloud project"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(.callout, design: .rounded, weight: .bold))
                .lineLimit(1)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 92, alignment: .leading)
    }

    private func compactTokens(_ value: Int64) -> String {
        value.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
        )
    }
}

/// Codex reports a single weekly window. On the shared 24-hour chart that is a
/// flat line pinned near mid-scale, so it gets a full-width panel of its own:
/// its own quota period on the x-axis and a value range fitted to its own
/// readings, which is what makes the weekly climb and the reset visible.
private struct CodexPanel: View, Equatable {
    let snapshot: AccountSnapshot?
    let series: ChartSeries?
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 210
    @ScaledMetric(relativeTo: .body) private var idealHeight: CGFloat = 222
    @ScaledMetric(relativeTo: .body) private var maximumHeight: CGFloat = 234

    nonisolated static func == (lhs: CodexPanel, rhs: CodexPanel) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.series == rhs.series
    }

    private var accent: Color { Color(red: 0.15, green: 0.68, blue: 0.53) }

    private var points: [ChartPoint] { series?.points ?? [] }

    private var window: UsageWindow? { snapshot?.windows.first }

    private var chartEnd: Date {
        let latest = points.map(\.timestamp).max() ?? Date()
        return latest.addingTimeInterval(HistoryStore.codexChartWindow * 0.03)
    }

    /// Never draws axis for a stretch that has no readings. Local history began
    /// when the dashboard first recorded, so a fixed week would render days of
    /// blank plot that look like missing data. The window rolls to a true seven
    /// days as soon as that much history exists.
    private var chartStart: Date {
        let rolling = chartEnd.addingTimeInterval(-HistoryStore.codexChartWindow)
        guard let earliest = points.map(\.timestamp).min() else { return rolling }
        return max(
            rolling,
            earliest.addingTimeInterval(
                -Double(HistoryStore.codexChartBucketSeconds)
            )
        )
    }

    /// The span actually plotted, so the header cannot advertise a week of
    /// history the chart does not have.
    private var spanLabel: String {
        let seconds = max(0, chartEnd.timeIntervalSince(chartStart))
        if seconds >= 86_400 {
            return "\(max(1, Int((seconds / 86_400).rounded())))D"
        }
        return "\(max(1, Int((seconds / 3_600).rounded())))H"
    }

    /// Fits the axis to the readings actually on file. A weekly window moves a
    /// couple of points per day, so a fixed 0–100 axis hides every real change;
    /// the bounds are still labeled, so a zoomed axis cannot be mistaken for a
    /// bigger swing than the numbers show.
    private var yDomain: ClosedRange<Double> {
        guard let low = points.map(\.value).min(),
              let high = points.map(\.value).max() else {
            return 0...100
        }
        let padding = max(2, (high - low) * 0.18)
        return max(0, low - padding)...min(100, high + padding)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(accent)
                            .frame(width: 26, height: 26)
                            .background(accent.opacity(0.12), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Codex weekly quota")
                                .font(
                                    .system(
                                        .title3,
                                        design: .rounded,
                                        weight: .bold
                                    )
                                )
                            Text(statusText)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(accent)
                            .frame(width: 6, height: 6)
                        Text("Saved remaining-% snapshots · \(spanLabel)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(
                    "WEEKLY WINDOW QUOTA REMAINING · \(spanLabel) OF HISTORY · AXIS FITTED TO READINGS"
                )
                    .font(.caption2.weight(.heavy))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                if points.isEmpty {
                    Text("History begins with real local quota-state snapshots.")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .center
                        )
                } else {
                    Chart(points) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Quota remaining", point.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.26),
                                    accent.opacity(0.02),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.linear)

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Quota remaining", point.value)
                        )
                        .foregroundStyle(accent)
                        .lineStyle(.init(lineWidth: 2.2, lineCap: .round))
                        .interpolationMethod(.linear)
                    }
                    .chartYScale(domain: yDomain)
                    .chartXScale(domain: chartStart...chartEnd)
                    .chartYAxis {
                        AxisMarks(
                            position: .leading,
                            values: .automatic(desiredCount: 4)
                        ) { value in
                            AxisGridLine()
                                .foregroundStyle(Color.secondary.opacity(0.12))
                            AxisValueLabel {
                                if let percent = value.as(Double.self) {
                                    Text("\(Int(percent.rounded()))%")
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        // One tick per day. Automatic ticks land inside a day on
                        // a short span, and a day-only label then repeats itself.
                        AxisMarks(values: .stride(by: .day)) {
                            AxisGridLine()
                                .foregroundStyle(Color.secondary.opacity(0.08))
                            AxisValueLabel(
                                format: .dateTime.month(.abbreviated).day()
                            )
                        }
                    }
                    .chartLegend(.hidden)
                    .chartPlotStyle { plotArea in
                        plotArea
                            .background(accent.opacity(0.03))
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 8,
                                    style: .continuous
                                )
                            )
                    }
                    .padding(.trailing, 16)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(minHeight: 110, maxHeight: .infinity)

            Divider()
                .overlay(Color.white.opacity(0.10))
                .padding(.horizontal, 13)

            codexSummary
        }
        .frame(
            minHeight: minimumHeight,
            idealHeight: idealHeight,
            maxHeight: maximumHeight
        )
        .panelSurface(accent: accent)
    }

    private var statusText: String {
        guard let snapshot else { return "Reading the local Codex session" }
        if snapshot.state == .unavailable || snapshot.state == .quotaUnavailable {
            return snapshot.detail ?? "This account could not be refreshed."
        }
        return snapshot.identity.privacyMaskedEmail
    }

    private var codexSummary: some View {
        HStack(spacing: 14) {
            ProviderIcon(provider: .codex, accent: accent)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("Codex")
                        .font(
                            .system(
                                .title3,
                                design: .rounded,
                                weight: .bold
                            )
                        )
                    if let snapshot {
                        PlanBadge(text: snapshot.plan)
                    }
                }
                if let window {
                    Text(window.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 168, alignment: .leading)

            Divider()
                .overlay(Color.white.opacity(0.10))

            if let snapshot, let window, snapshot.canDisplayQuotaValues {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(window.remainingPercent.rounded()))%")
                        .font(
                            .system(
                                .title,
                                design: .rounded,
                                weight: .bold
                            )
                        )
                    Text("remaining")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 190, alignment: .leading)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                        Capsule()
                            .fill(accent)
                            .frame(
                                width: proxy.size.width
                                    * window.remainingPercent / 100
                            )
                    }
                }
                .frame(height: 6)

                VStack(alignment: .trailing, spacing: 1) {
                    ResetCountdownLabel(resetAt: window.resetAt)
                    Text(snapshot.detail ?? "Local quota snapshot")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 168, alignment: .trailing)
            } else {
                Text(snapshot?.detail ?? "Waiting for a Codex quota reading.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let snapshot {
                StateBadge(state: snapshot.state)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 74)
    }
}

private struct AccountCard: View, Equatable {
    let snapshot: AccountSnapshot
    @ScaledMetric(relativeTo: .body) private var accountCardHeight: CGFloat = 194

    nonisolated static func == (lhs: AccountCard, rhs: AccountCard) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    private var accent: Color {
        snapshot.slot.provider == .claude
            ? Color(red: 0.84, green: 0.38, blue: 0.23)
            : Color(red: 0.15, green: 0.68, blue: 0.53)
    }

    private var headlineWindow: UsageWindow? {
        snapshot.windows.first
    }

    private var cardHeight: CGFloat {
        accountCardHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                ProviderIcon(provider: snapshot.slot.provider, accent: accent)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(snapshot.slot.title)
                            .font(
                                .system(
                                    .title3,
                                    design: .rounded,
                                    weight: .bold
                                )
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .allowsTightening(true)
                        PlanBadge(text: snapshot.plan)
                    }
                    Text(snapshot.identity.privacyMaskedEmail)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)
                }

                Spacer()

                // No headline percentage here. Every window this card holds is
                // already listed below with its own figure, and lifting one of
                // them into the header restated a number the reader can see —
                // while implying the card had a single overall percentage.
                StateBadge(state: snapshot.state)
            }

            if snapshot.state == .loading {
                loadingContent
            } else if let headlineWindow, snapshot.canDisplayQuotaValues {
                usageContent(headlineWindow)
            } else if snapshot.state == .stale {
                staleContent
            } else {
                unavailableContent
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: cardHeight, alignment: .topLeading)
        .panelSurface(accent: accent, cornerRadius: 18)
    }

    private var loadingContent: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Reading local session")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.10))
                .frame(height: 7)
        }
        .redacted(reason: .placeholder)
    }

    /// Claude reports these two windows. Both keep their row even when one has
    /// no current reading, so every Claude card stays directly comparable and a
    /// dropped window is visible rather than silently missing.
    private static let expectedClaudeWindows: [ExpectedWindow] = [
        ExpectedWindow(id: "five-hour", title: "5-hour"),
        ExpectedWindow(id: "seven-day", title: "7-day"),
    ]

    private struct ExpectedWindow: Identifiable {
        let id: String
        let title: String
    }

    private func usageContent(_ headline: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if snapshot.slot.provider == .claude {
                ForEach(Self.expectedClaudeWindows) { expected in
                    if let window = snapshot.windows.first(
                        where: { $0.id == expected.id }
                    ) {
                        CompactLimitRow(window: window, accent: accent)
                    } else {
                        MissingLimitRow(title: expected.title)
                    }
                }
            } else {
                ForEach(snapshot.windows.prefix(2)) { window in
                    CompactLimitRow(window: window, accent: accent)
                }
            }
            if snapshot.slot.provider == .claude {
                CompactFableRow(window: snapshot.fableUsage, accent: accent)
            }

            if let peer = snapshot.duplicatePeer {
                DetailStrip(
                    icon: "person.2.badge.gearshape",
                    text: "Same provider account as \(peer)",
                    color: .orange
                )
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(snapshot.showsAgedValues ? Color.orange : accent)
                        .frame(width: 5, height: 5)
                    Text(
                        snapshot.detail
                            ?? (snapshot.state == .live
                                ? "Provider confirmed"
                                : "Local quota snapshot")
                    )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            snapshot.showsAgedValues ? Color.orange : .secondary
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if snapshot.showsAgedValues {
                        Text("· usage may be higher")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
    }

    private var unavailableContent: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.state == .quotaUnavailable
                     ? "Quota snapshot unavailable"
                     : "Session needs attention")
                    .font(
                        .system(
                            .title3,
                            design: .rounded,
                            weight: .bold
                        )
                    )
                Text(snapshot.detail ?? "This account could not be refreshed.")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(snapshot.slot.provider == .claude
                     ? "Waiting for this account’s own local quota snapshot."
                     : "Open Codex and sign in again.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
            }
        }
    }

    private var staleContent: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Quota window has reset")
                    .font(
                        .system(
                            .title3,
                            design: .rounded,
                            weight: .bold
                        )
                    )
                Text(
                    snapshot.detail
                        ?? "This account’s local quota source is no longer current."
                )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("Waiting for this account to produce a new local snapshot.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
            }
        }
    }

}

private struct RefreshIntervalControl: View {
    @Binding var seconds: Int
    @FocusState private var intervalFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("Every")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("20", value: $seconds, format: .number)
                .focused($intervalFieldFocused)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .rounded, weight: .bold))
                .frame(width: 48)
                .accessibilityLabel("Automatic refresh interval in seconds")
            Text("sec")
                .font(.callout.weight(.semibold))
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
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(0.10))
        }
        .help("Automatic refresh interval: 10–3600 seconds. The choice is saved.")
        .onAppear {
            intervalFieldFocused = false
        }
    }
}

private struct WindowFocusResetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        FocusClearingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) { }

    private final class FocusClearingView: NSView {
        private var clearedInitialFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !clearedInitialFocus else { return }
            clearedInitialFocus = true
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(nil)
            }
        }
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
            if provider == .claude {
                ClaudeSpark()
                    .fill(.white)
                    .frame(width: 21, height: 21)
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 36, height: 36)
        .shadow(color: accent.opacity(0.24), radius: 9, y: 4)
    }
}

/// The Claude "spark" — a radial burst of tapered, round-tipped rays. Drawn as a
/// vector so it stays crisp at any card size and needs no bundled raster.
private struct ClaudeSpark: Shape {
    var rayCount = 12

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let innerRadius = outer * 0.16
        // A ray tapers from a narrow base near the centre to a rounded tip. Half
        // the angular half-width the base subtends; the tip is rounded by the
        // stroke cap so the fill needs only a slim quadrilateral per ray.
        let baseHalf = (.pi / CGFloat(rayCount)) * 0.42
        var path = Path()
        for index in 0..<rayCount {
            let angle = (2 * .pi / CGFloat(rayCount)) * CGFloat(index) - .pi / 2
            let leftBase = CGPoint(
                x: center.x + cos(angle - baseHalf) * innerRadius,
                y: center.y + sin(angle - baseHalf) * innerRadius
            )
            let rightBase = CGPoint(
                x: center.x + cos(angle + baseHalf) * innerRadius,
                y: center.y + sin(angle + baseHalf) * innerRadius
            )
            let tipHalf = baseHalf * 0.5
            let leftTip = CGPoint(
                x: center.x + cos(angle - tipHalf) * outer,
                y: center.y + sin(angle - tipHalf) * outer
            )
            let rightTip = CGPoint(
                x: center.x + cos(angle + tipHalf) * outer,
                y: center.y + sin(angle + tipHalf) * outer
            )
            path.move(to: leftBase)
            path.addLine(to: leftTip)
            // Round the tip.
            path.addQuadCurve(
                to: rightTip,
                control: CGPoint(
                    x: center.x + cos(angle) * (outer * 1.08),
                    y: center.y + sin(angle) * (outer * 1.08)
                )
            )
            path.addLine(to: rightBase)
            path.closeSubpath()
        }
        // A small filled hub so the rays read as one mark.
        path.addEllipse(
            in: CGRect(
                x: center.x - innerRadius,
                y: center.y - innerRadius,
                width: innerRadius * 2,
                height: innerRadius * 2
            )
        )
        return path
    }
}

private struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.heavy))
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
        case .cached: .teal
        case .stale: .orange
        case .quotaUnavailable: .orange
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
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(color.opacity(0.10), in: Capsule())
    }
}

private struct CompactLimitRow: View {
    let window: UsageWindow
    let accent: Color
    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 52
    @ScaledMetric(relativeTo: .caption) private var valueWidth: CGFloat = 168
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 31

    var body: some View {
        HStack(spacing: 8) {
            Text(window.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(accent)
                        .frame(
                            width: proxy.size.width
                                * window.remainingPercent / 100
                        )
                }
            }
            .frame(height: 5)
            VStack(alignment: .trailing, spacing: 0) {
                Text(window.remainingLabel)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                ResetCountdownLabel(resetAt: window.resetAt)
            }
                .frame(width: valueWidth, alignment: .trailing)
        }
        .frame(height: rowHeight)
    }
}

/// A window the provider stopped reporting a current value for — its reset has
/// passed and no newer sample has arrived. Keeping the row makes the gap
/// explicit; dropping it would quietly promote the next window into the
/// headline position and read as that window's number.
private struct MissingLimitRow: View {
    let title: String
    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 52
    @ScaledMetric(relativeTo: .caption) private var valueWidth: CGFloat = 168
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 31

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Capsule()
                .fill(Color.secondary.opacity(0.10))
                .frame(height: 5)
            VStack(alignment: .trailing, spacing: 0) {
                Text("No current reading")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text("window reset · awaiting a new sample")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(width: valueWidth, alignment: .trailing)
        }
        .frame(height: rowHeight)
    }
}

private struct CompactFableRow: View {
    let window: UsageWindow?
    let accent: Color
    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 52
    @ScaledMetric(relativeTo: .caption) private var valueWidth: CGFloat = 168
    @ScaledMetric(relativeTo: .caption) private var rowHeight: CGFloat = 31

    var body: some View {
        HStack(spacing: 8) {
            Text("Fable")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            if let window {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                        Capsule()
                            .fill(accent)
                            .frame(
                                width: proxy.size.width
                                    * window.remainingPercent / 100
                            )
                    }
                }
                .frame(height: 5)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(window.remainingLabel)
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    ResetCountdownLabel(resetAt: window.resetAt)
                }
                    .frame(width: valueWidth, alignment: .trailing)
            } else {
                Spacer()
                Text("Unavailable in local cache")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(height: rowHeight)
    }
}

private struct ResetCountdownLabel: View {
    let resetAt: Date?

    var body: some View {
        if let resetAt {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let compact = ResetCountdown.compact(
                    until: resetAt,
                    now: context.date
                )
                let accessibility = ResetCountdown.accessibilityText(
                    until: resetAt,
                    now: context.date
                )
                Text("Resets in \(compact)")
                    .accessibilityLabel("Resets in \(accessibility)")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        } else {
            Text("Reset unavailable")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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
                Text(window.remainingLabel)
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

private struct FableUsageRow: View {
    let window: UsageWindow?
    let accent: Color

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(window == nil ? .orange : accent)
                Text("Fable usage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(window.map(\.remainingLabel)
                     ?? "Unavailable in local cache")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(window == nil ? .orange : .primary)
            }

            if let window {
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

                HStack {
                    Text("Weekly model limit")
                    Spacer()
                    if let resetAt = window.resetAt {
                        Text("resets \(compactReset(resetAt))")
                    }
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            (window == nil ? Color.orange : accent).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
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

extension String {
    /// "name@example.com" becomes "name@…" — the mailbox stays recognizable
    /// while the domain stays off the screen and out of screenshots. A string
    /// without an @ (a display name, a bare label) passes through unchanged.
    var privacyMaskedEmail: String {
        guard let at = firstIndex(of: "@"), at != startIndex else { return self }
        return String(self[..<at]) + "@…"
    }
}
