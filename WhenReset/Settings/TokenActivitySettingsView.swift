#if os(iOS)
import Observation
import SwiftUI

/// Token activity, then performance for a chosen span. With no local transcripts
/// the page explains that instead of drawing an empty chart. Screenshot launches
/// supply a sample year whose parts add up to each day's total.
struct TokenActivitySettingsView: View {
    @State private var chart: TokenActivityChart
    @State private var span: TokenPerformanceSpan

    init() {
        let initialChart: TokenActivityChart
        #if DEBUG
        initialChart = ScreenshotLaunch.isActive ? ScreenshotLaunch.tokenChart : .daily
        #else
        initialChart = .daily
        #endif
        _chart = State(initialValue: initialChart)
        _span = State(initialValue: .default)
    }

    private var records: [TokenDayUsage] { TokenRecordStore.shared.records }

    private var activity: TokenActivity {
        let days = Dictionary(records.map { ($0.date, $0.total) }, uniquingKeysWith: +)
        return TokenActivity.of(days: days, hasPartialCounts: TokenRecordStore.shared.hasPartialCounts)
    }

    private var summary: TokenSpanSummary {
        TokenSpanMath.summary(records: records, span: span)
    }

    var body: some View {
        Form {
            if records.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No local transcripts")
                            .font(.subheadline.weight(.semibold))
                        Text("This iPhone has no agent transcripts to read, so there is no token chart yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("token-activity-empty")
                }
                .listRowSeparator(.hidden)
                .blinkySettingsSection()
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Token activity", selection: $chart) {
                            ForEach(TokenActivityChart.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("token-activity-chart")
                        Text(String(
                            format: String.localized("%@ tokens in the last 12 months"),
                            locale: AppLanguage.current.locale,
                            TokenActivityText.count(activity.total)
                        ))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        TokenActivityPlot(activity: activity, chart: chart)
                        if activity.hasPartialCounts {
                            Text("Counts may be incomplete.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .blinkySettingsSection()

                Section {
                    TokenPerformanceCard(summary: summary, span: $span)
                } header: {
                    Text("Performance")
                }
                .listRowSeparator(.hidden)
                .blinkySettingsSection()
            }
        }
        .blinkySettingsCanvas()
        .navigationTitle("Token activity")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Day counts and per-model splits. Empty until a reader supplies them.
@MainActor
@Observable
final class TokenRecordStore {
    static let shared = TokenRecordStore()

    var records: [TokenDayUsage] = []
    var hasPartialCounts = false

    private init() {
        #if DEBUG
        guard ScreenshotLaunch.isActive, ScreenshotLaunch.seedsTokenActivity else { return }
        records = ScreenshotLaunch.tokenActivityRecords()
        #endif
    }
}

private enum TokenActivityText {
    static func count(_ value: Int) -> String {
        let locale = AppLanguage.current.locale
        let chinese = AppLanguage.current == .chineseSimplified
        if chinese {
            if value >= 100_000_000 {
                return number(Double(value) / 100_000_000, locale: locale) + "亿"
            }
            if value >= 10_000 {
                return number(Double(value) / 10_000, locale: locale) + "万"
            }
        } else if value >= 1_000_000_000 {
            return number(Double(value) / 1_000_000_000, locale: locale) + "B"
        } else if value >= 1_000_000 {
            return number(Double(value) / 1_000_000, locale: locale) + "M"
        } else if value >= 1_000 {
            return number(Double(value) / 1_000, locale: locale) + "K"
        }
        return value.formatted(.number.grouping(.automatic).locale(locale))
    }

    static func percent(_ value: Double) -> String {
        (value * 100).formatted(
            .number.precision(.fractionLength(0)).locale(AppLanguage.current.locale)
        ) + "%"
    }

    static func speed(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(AppLanguage.current.locale))
    }

    private static func number(_ value: Double, locale: Locale) -> String {
        value.formatted(
            .number.precision(.fractionLength(value < 10 ? 1 : 0)).grouping(.never).locale(locale)
        )
    }
}

private struct TokenActivityPlot: View {
    let activity: TokenActivity
    let chart: TokenActivityChart
    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.locale) private var locale

    private let visibleColumns = 26
    private let gutter: CGFloat = 18
    private let gutterGap: CGFloat = 4

    private var cellRadius: CGFloat {
        interfaceStyle == .screenTime ? 1 : 2
    }

    var body: some View {
        Group {
            switch chart {
            case .daily:
                VStack(alignment: .leading, spacing: 8) {
                    daily
                    legend
                }
                .accessibilityIdentifier("token-activity-daily")
            case .weekly:
                weeklyBars
                    .accessibilityIdentifier("token-activity-weekly")
            case .cumulative:
                cumulativeLine
                    .accessibilityIdentifier("token-activity-cumulative")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The scroll view's ideal width is its content, which would collapse the
    /// grid. A clear row takes the card width, and the overlay reads that width.
    private var daily: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .overlay {
                GeometryReader { proxy in
                    let pitch = max((proxy.size.width - gutter - gutterGap) / CGFloat(visibleColumns), 1)
                    let columns = CGFloat(max(activity.weeks.count, 1))
                    HStack(alignment: .top, spacing: gutterGap) {
                        weekdayGutter(pitch: pitch)
                            .frame(width: gutter)
                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 2) {
                                monthLabels(pitch: pitch)
                                    .frame(width: pitch * columns, height: 14)
                                dayCells(pitch: pitch)
                                    .frame(width: pitch * columns, height: pitch * 7)
                            }
                        }
                        .defaultScrollAnchor(.trailing)
                        .contentMargins(.horizontal, 0, for: .scrollContent)
                    }
                }
            }
    }

    private func weekdayGutter(pitch: CGFloat) -> some View {
        let calendar = Calendar.current
        return VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 14)
            VStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { row in
                    Text(weekdayLabel(row: row, calendar: calendar))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(height: pitch, alignment: .leading)
                }
            }
        }
    }

    private func weekdayLabel(row: Int, calendar: Calendar) -> String {
        guard let start = activity.weeks.first?.start,
              let date = calendar.date(byAdding: .day, value: row, to: start) else { return "" }
        let weekday = calendar.component(.weekday, from: date)
        guard weekday == 2 || weekday == 4 || weekday == 6 else { return "" }
        return date.formatted(.dateTime.weekday(.narrow).locale(locale))
    }

    private func monthLabels(pitch: CGFloat) -> some View {
        let marks = monthMarks(calendar: Calendar.current)
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.index) { mark in
                Text(mark.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: pitch * CGFloat(mark.index))
            }
        }
    }

    private func monthMarks(calendar: Calendar) -> [(index: Int, title: String)] {
        var candidates: [(index: Int, title: String)] = []
        var seen = Set<String>()
        for (index, week) in activity.weeks.enumerated() {
            let month = calendar.component(.month, from: week.start)
            let year = calendar.component(.year, from: week.start)
            guard seen.insert("\(year)-\(month)").inserted else { continue }
            let title = week.start.formatted(.dateTime.month(.abbreviated).locale(locale))
            candidates.append((index, title))
        }
        var kept: [(index: Int, title: String)] = []
        var lastIndex: Int?
        for mark in candidates.reversed() {
            if let lastIndex, lastIndex - mark.index < 4 { continue }
            kept.append(mark)
            lastIndex = mark.index
        }
        return Array(kept.reversed())
    }

    private func dayCells(pitch: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(activity.weeks) { week in
                VStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { row in
                        RoundedRectangle(cornerRadius: cellRadius, style: .continuous)
                            .fill(fill(week: week, row: row))
                            .padding(1)
                            .frame(width: pitch, height: pitch)
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("Less")
            ForEach(0..<5, id: \.self) { step in
                RoundedRectangle(cornerRadius: cellRadius, style: .continuous)
                    .fill(stepColor(step))
                    .frame(width: 9, height: 9)
            }
            Text("More")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private var weeklyBars: some View {
        let peak = max(activity.weeks.map(\.tokens).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(activity.weeks) { week in
                RoundedRectangle(cornerRadius: cellRadius, style: .continuous)
                    .fill(week.tokens > 0 ? Color.accentColor : Color.primary.opacity(0.12))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, 72 * CGFloat(week.tokens) / CGFloat(peak)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 76)
    }

    private var cumulativeLine: some View {
        let points = activity.points
        let minPosition = points.first?.position ?? 0
        let maxPosition = points.last?.position ?? 1
        let span = max(maxPosition - minPosition, 0.001)
        return GeometryReader { proxy in
            let maxRunning = max(points.map(\.running).max() ?? 1, 1)
            Path { path in
                for (index, point) in points.enumerated() {
                    let x = proxy.size.width * CGFloat((point.position - minPosition) / span)
                    let y = proxy.size.height * (1 - CGFloat(point.running) / CGFloat(maxRunning))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 76)
        .frame(maxWidth: .infinity)
    }

    private func fill(week: TokenActivity.Week, row: Int) -> Color {
        if row < week.unrecorded.count, week.unrecorded[row], week.days[row] == nil {
            return Color.primary.opacity(0.06)
        }
        guard let day = week.days[row] else { return .clear }
        return stepColor(activity.step(for: day.tokens))
    }

    private func stepColor(_ step: Int) -> Color {
        switch step {
        case 0: return Color.primary.opacity(0.12)
        case 1: return Color.accentColor.opacity(0.30)
        case 2: return Color.accentColor.opacity(0.52)
        case 3: return Color.accentColor.opacity(0.76)
        default: return Color.accentColor
        }
    }
}

private struct TokenPerformanceCard: View {
    let summary: TokenSpanSummary
    @Binding var span: TokenPerformanceSpan
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Performance", selection: $span) {
                ForEach(TokenPerformanceSpan.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("token-performance-span")
            Text(span.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            summaryRow
            splitLegend
            VStack(alignment: .leading, spacing: 10) {
                ForEach(summary.models) { model in
                    modelRow(model)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("token-performance")
    }

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 8) {
            figure(TokenActivityText.count(summary.total), caption: "Total tokens")
            figure(summary.cacheHit.map(TokenActivityText.percent) ?? "—", caption: "Cache hit")
            figure(summary.averageSpeed.map(TokenActivityText.speed) ?? "—", caption: "Avg speed")
        }
    }

    private func figure(_ value: String, caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var splitLegend: some View {
        HStack(spacing: 10) {
            legendItem(Color.accentColor, "Cache")
            legendItem(Color.accentColor.opacity(0.55), "Input")
            legendItem(Color.accentColor.opacity(0.28), "Output")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func legendItem(_ color: Color, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 4)
            Text(title)
        }
    }

    private func modelRow(_ model: TokenModelUsage) -> some View {
        let open = expanded.contains(model.id)
        return Button {
            if open { expanded.remove(model.id) } else { expanded.insert(model.id) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(TokenActivityText.count(model.total))
                        .font(.subheadline.monospacedDigit())
                    if let speed = model.tokensPerSecond {
                        Text("\(TokenActivityText.speed(speed)) \(String.localized("tok/s"))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                splitBar(model)
                if open {
                    detail("Cache", model.cache.map(TokenActivityText.count) ?? "—")
                    detail("Input", TokenActivityText.count(model.input))
                    detail("Output", TokenActivityText.count(model.output))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("token-model-\(model.id)")
    }

    private func splitBar(_ model: TokenModelUsage) -> some View {
        let total = CGFloat(max(model.total, 1))
        let cache = CGFloat(model.cache ?? 0)
        let input = CGFloat(model.input)
        let output = CGFloat(model.output)
        return GeometryReader { proxy in
            HStack(spacing: 0) {
                if cache > 0 {
                    Color.accentColor.frame(width: proxy.size.width * cache / total)
                }
                if input > 0 {
                    Color.accentColor.opacity(0.55).frame(width: proxy.size.width * input / total)
                }
                if output > 0 {
                    Color.accentColor.opacity(0.28).frame(width: proxy.size.width * output / total)
                }
            }
        }
        .frame(height: 4)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .clipShape(Capsule())
    }

    private func detail(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(value == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
        .font(.caption)
    }
}
#endif
