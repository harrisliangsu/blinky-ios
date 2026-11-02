#if os(iOS)
import Observation
import SwiftUI

/// Token activity, then Performance when a span has a speed or a cache,
/// input, or output split. With no local transcripts the page explains that
/// instead of drawing an empty chart. Screenshot launches supply a sample year.
struct TokenActivitySettingsView: View {
    @State private var chart = TokenActivityChart.default

    private var activity: TokenActivity {
        TokenActivity.of(days: TokenRecordStore.shared.days, hasPartialCounts: TokenRecordStore.shared.hasPartialCounts)
    }

    private var performance: TokenPerformanceTable? {
        TokenPerformanceTable.make(TokenRecordStore.shared.performance)
    }

    var body: some View {
        Form {
            if activity.isEmpty, performance == nil {
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
                .blinkySettingsSection()
            }

            if !activity.isEmpty {
                Section {
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
                } header: {
                    Text("Token activity")
                }
                .blinkySettingsSection()
            }

            if let performance {
                Section {
                    TokenPerformanceList(table: performance)
                } header: {
                    Text("Performance")
                }
                .blinkySettingsSection()
            }
        }
        .blinkySettingsCanvas()
        .navigationTitle("Token activity")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Day counts and performance rows. Empty until a reader supplies them.
@MainActor
@Observable
final class TokenRecordStore {
    static let shared = TokenRecordStore()

    var days: [Date: Int] = [:]
    var hasPartialCounts = false
    var performance: [TokenPerformanceRow] = []

    private init() {
        #if DEBUG
        guard ScreenshotLaunch.isActive, ScreenshotLaunch.screen == "tokenActivity" else { return }
        let sample = ScreenshotLaunch.tokenActivitySample()
        days = sample.days
        performance = sample.rows
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

    static func rowTitle(_ name: String) -> String {
        name == "Overall" ? String.localized("Overall") : name
    }

    private static func number(_ value: Double, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 1 : 0)).locale(locale))
    }
}

private struct TokenActivityPlot: View {
    let activity: TokenActivity
    let chart: TokenActivityChart
    @Environment(\.interfaceStyle) private var interfaceStyle

    private var cellRadius: CGFloat {
        interfaceStyle == .screenTime ? 1 : 2
    }

    var body: some View {
        switch chart {
        case .daily:
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 2) {
                        ForEach(activity.weeks) { week in
                            VStack(spacing: 2) {
                                ForEach(0..<7, id: \.self) { row in
                                    RoundedRectangle(cornerRadius: cellRadius, style: .continuous)
                                        .fill(fill(week: week, row: row))
                                        .frame(width: 8, height: 8)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .defaultScrollAnchor(.trailing)
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
        return GeometryReader { proxy in
            let maxRunning = max(points.map(\.running).max() ?? 1, 1)
            let lastColumn = max(Double(activity.columnCount), 1)
            Path { path in
                for (index, point) in points.enumerated() {
                    let x = proxy.size.width * CGFloat(point.position / lastColumn)
                    let y = proxy.size.height * (1 - CGFloat(point.running) / CGFloat(maxRunning))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, lineWidth: 2)
        }
        .frame(height: 76)
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

private struct TokenPerformanceList: View {
    let table: TokenPerformanceTable

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(table.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(TokenActivityText.rowTitle(row.name))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    ForEach(table.columns) { column in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(column.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(text(row.value(for: column), column: column))
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(row.value(for: column) == nil ? .tertiary : .primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("token-performance")
    }

    private func text(_ value: Double?, column: TokenPerformanceTable.Column) -> String {
        guard let value else { return "—" }
        switch column {
        case .speed:
            let locale = AppLanguage.current.locale
            let number = value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
            return "\(number) \(String.localized("tok/s"))"
        case .cache, .input, .output:
            return TokenActivityText.count(Int(value))
        }
    }
}
#endif
