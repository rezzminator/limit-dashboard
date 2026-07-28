import AppKit
import Charts
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

                VertexCard(
                    report: model.vertexReport,
                    error: model.vertexError
                )
                .equatable()

                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow(alignment: .top) {
                        AccountCard(snapshot: model.snapshots[0]).equatable()
                        AccountCard(snapshot: model.snapshots[1]).equatable()
                    }
                    GridRow(alignment: .top) {
                        AccountCard(snapshot: model.snapshots[2]).equatable()
                        AccountCard(snapshot: model.snapshots[3]).equatable()
                    }
                }

                Spacer(minLength: 0)

                footer
            }
            .padding(14)
        }
        .frame(minWidth: 920, minHeight: 720)
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
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .shadow(color: Color.accentColor.opacity(0.24), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Account limits")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("One quiet view of every local subscription.")
                        .font(.system(size: 13, weight: .medium))
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

    private var historyEnd: Date {
        let latest = allPoints.map(\.timestamp).max() ?? Date()
        return latest.addingTimeInterval(
            TimeInterval(HistoryStore.chartBucketSeconds)
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.indigo)
                        .frame(width: 26, height: 26)
                        .background(Color.indigo.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quota history")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        if let error {
                            Text(error)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                        } else if let firstMeasurement {
                            Text(
                                "Saved snapshots only · begins \(firstMeasurement, style: .time)"
                            )
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        } else {
                            Text("No saved measurements yet")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                historyLegend
            }

            Text("PRIMARY QUOTA REMAINING SNAPSHOTS · 24H")
                .font(.system(size: 8, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            if hasPoints {
                Chart {
                    ForEach(series) { account in
                        ForEach(account.points) { point in
                            LineMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Remaining", point.value),
                                series: .value("Account", account.id)
                            )
                            .foregroundStyle(color(for: account.id))
                            .lineStyle(.init(lineWidth: 2.2, lineCap: .round))
                            .interpolationMethod(.linear)

                            PointMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Remaining", point.value)
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
                    AxisMarks(values: .automatic(desiredCount: 6)) {
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
            } else {
                Text("History begins with local refresh snapshots.")
                    .font(.system(size: 11, weight: .semibold))
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
        .frame(height: 138)
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
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
    }

    private func color(for slotID: String) -> Color {
        switch slotID {
        case "claude-gmail":
            Color(red: 0.96, green: 0.34, blue: 0.24)
        case "claude-freudche":
            Color(red: 0.96, green: 0.68, blue: 0.20)
        case "claude-khosravi":
            Color(red: 0.65, green: 0.42, blue: 0.95)
        default:
            Color(red: 0.16, green: 0.78, blue: 0.63)
        }
    }
}

private struct VertexCard: View, Equatable {
    let report: VertexReport?
    let error: String?

    nonisolated static func == (
        lhs: VertexCard,
        rhs: VertexCard
    ) -> Bool {
        lhs.report == rhs.report && lhs.error == rhs.error
    }

    private var axisMaximum: Double {
        max(1, report?.series.points.map(\.value).max() ?? 0)
    }

    private var hasReportedActivity: Bool {
        report?.hasChartActivity == true
    }

    private var axisDomain: ClosedRange<Double> {
        hasReportedActivity ? 0...axisMaximum : -0.08...1
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.blue)
                            .frame(width: 26, height: 26)
                            .background(Color.blue.opacity(0.12), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vertex AI token usage")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                            Text(statusText)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(statusColor)
                        }
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                        Text("Token totals · daily buckets")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(chartWindowLabel)
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                if let report, !report.series.points.isEmpty {
                    Chart(report.series.points) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Tokens", point.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color.blue.opacity(0.28),
                                    Color.blue.opacity(0.02),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.linear)

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Tokens", point.value)
                        )
                        .foregroundStyle(Color.blue)
                        .lineStyle(.init(lineWidth: 2.4, lineCap: .round))
                        .interpolationMethod(.linear)

                        PointMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Tokens", point.value)
                        )
                        .foregroundStyle(Color.blue)
                        .symbolSize(hasReportedActivity ? 12 : 20)
                    }
                    .chartXScale(domain: report.chartStart...report.chartEnd)
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
                        AxisMarks(values: .automatic(desiredCount: 6)) {
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
                } else {
                    Text(error ?? "Loading actual Cloud Monitoring token buckets…")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(error == nil ? Color.secondary : Color.orange)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .center
                        )
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(height: 146)

            Divider()
                .overlay(Color.white.opacity(0.10))
                .padding(.horizontal, 13)

            VertexSummarySection(report: report, error: error)
        }
        .frame(height: 225)
        .panelSurface(accent: .blue)
    }

    private var statusText: String {
        if let error {
            return error
        }
        guard report != nil else {
            return "Reading local authenticated Cloud Monitoring data"
        }
        if !hasReportedActivity {
            return "No tokens reported in this window · zero is a valid measurement"
        }
        return "Actual Cloud Monitoring token totals"
    }

    private var statusColor: Color {
        if error != nil {
            return .orange
        }
        return .secondary
    }

    private var chartWindowLabel: String {
        guard let report else {
            return "VERTEX TOKEN TOTALS"
        }
        return "VERTEX TOKEN TOTALS · \(durationLabel(from: report.chartStart, to: report.chartEnd)) · \(durationLabel(seconds: report.chartBucketSeconds)) SUM BUCKETS"
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

private struct VertexSummarySection: View {
    let report: VertexReport?
    let error: String?

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vertex AI summary")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(summaryWindowLabel)
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)

            Divider()
                .overlay(Color.white.opacity(0.10))

            if let report {
                VStack(alignment: .leading, spacing: 1) {
                    if let estimatedEUR = report.estimatedEUR {
                        Text(
                            "~€\(estimatedEUR, format: .number.precision(.fractionLength(2)))"
                        )
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                    } else {
                        Text("Unavailable")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    Text("estimated list price · not an invoice")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                .frame(width: 190, alignment: .leading)

                VertexMetric(
                    label: "Input tokens",
                    value: compactTokens(report.totals.input)
                )
                VertexMetric(
                    label: "Output tokens",
                    value: compactTokens(report.totals.output)
                )
                VertexMetric(
                    label: "Total tokens",
                    value: compactTokens(report.totals.total)
                )

                Spacer()

                if !report.pricingWarnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(report.pricingWarnings.joined(separator: "\n"))
                }
            } else {
                Text(error ?? "Loading one local Monitoring summary…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(error == nil ? Color.secondary : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 78)
    }

    private var summaryWindowLabel: String {
        guard let report else { return "SUMMARY WINDOW" }
        return "\(durationLabel(from: report.summaryStart, to: report.summaryEnd)) SUMMARY"
    }

    private func durationLabel(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
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

    private func compactTokens(_ value: Int64) -> String {
        value.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
        )
    }
}

private struct VertexMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: 116, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.11),
                    Color.secondary.opacity(0.055),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.blue.opacity(0.12))
        }
    }
}

private struct AccountCard: View, Equatable {
    let snapshot: AccountSnapshot

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
        guard snapshot.state != .unavailable,
              snapshot.state != .quotaUnavailable else {
            return 148
        }
        return snapshot.slot.provider == .claude ? 148 : 106
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
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

                if let headlineWindow,
                   snapshot.state != .loading {
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(
                                "\(Int(headlineWindow.remainingPercent.rounded()))%"
                            )
                            .font(
                                .system(
                                    size: 24,
                                    weight: .bold,
                                    design: .rounded
                                )
                            )
                            Text("remaining")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(headlineWindow.usedLabel)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }

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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.10))
                .frame(height: 7)
        }
        .redacted(reason: .placeholder)
    }

    private func usageContent(_ headline: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(snapshot.windows.prefix(2)) { window in
                CompactLimitRow(window: window, accent: accent)
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
                        .fill(accent)
                        .frame(width: 5, height: 5)
                    Text(snapshot.state == .live ? "Provider confirmed" : "Local quota snapshot")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let resetAt = headline.resetAt {
                        Text("· resets \(compactReset(resetAt))")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
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
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(snapshot.detail ?? "This account could not be refreshed.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(snapshot.slot.provider == .claude
                     ? "Waiting for this account’s own local quota snapshot."
                     : "Open Codex and sign in again.")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
            }
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
    @FocusState private var intervalFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("Every")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("20", value: $seconds, format: .number)
                .focused($intervalFieldFocused)
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
            Image(systemName: provider == .claude ? "sparkles" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
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
                .font(.system(size: 10, weight: .bold))
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

    var body: some View {
        HStack(spacing: 8) {
            Text(window.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(accent)
                        .frame(
                            width: proxy.size.width
                                * window.normalizedUsedPercent / 100
                        )
                }
            }
            .frame(height: 5)
            Text("\(window.usedLabel) · \(window.remainingLabel)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .frame(width: 158, alignment: .trailing)
        }
        .frame(height: 16)
    }
}

private struct CompactFableRow: View {
    let window: UsageWindow?
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Text("Fable")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            if let window {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                        Capsule()
                            .fill(accent)
                            .frame(
                                width: proxy.size.width
                                    * window.normalizedUsedPercent / 100
                            )
                    }
                }
                .frame(height: 5)
                Text("\(window.usedLabel) · \(window.remainingLabel)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .frame(width: 158, alignment: .trailing)
            } else {
                Spacer()
                Text("Unavailable in local cache")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(height: 16)
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
                Text("\(window.usedLabel) · \(window.remainingLabel)")
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
                        .frame(width: proxy.size.width * window.normalizedUsedPercent / 100)
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
                Text(window.map { "\($0.usedLabel) · \($0.remainingLabel)" }
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
                            .frame(width: proxy.size.width * window.normalizedUsedPercent / 100)
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
