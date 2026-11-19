import SwiftUI
import Charts

/// Chart colours.
///
/// Every chart here plots one series, so there is no categorical palette to
/// separate — each uses a single hue and the title names what it shows, which is
/// why none of them carries a legend. Status colours stay reserved for status.
private enum ChartPalette {
    /// Balance: a cool hue, distinct from the status greens and reds.
    static let balance = Color(red: 0.20, green: 0.47, blue: 0.85)
    /// Spend: a warmer hue so the two charts never read as the same measure.
    static let spend = Color(red: 0.42, green: 0.35, blue: 0.80)
    static let units = Color(red: 0.11, green: 0.55, blue: 0.56)

    static let gridLine = Color.secondary.opacity(0.18)
}

// MARK: - Balance trend

/// Balance over time — a line, because the job is change over time.
struct BalanceTrendChart: View {
    let meter: Meter
    @State private var selectedDate: Date?

    private var series: [(date: Date, balance: Double)] {
        ConsumptionAnalytics.balanceSeries(meter: meter, days: 30)
    }

    var body: some View {
        Card(title: "Balance, last 30 days") {
            if series.count < 2 {
                EmptyChartHint(message: "Two readings are needed before a trend appears. Open the app once a day.")
            } else {
                Chart {
                    ForEach(series, id: \.date) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Balance", point.balance)
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(ChartPalette.balance)

                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Balance", point.balance)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            .linearGradient(
                                colors: [ChartPalette.balance.opacity(0.22), ChartPalette.balance.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }

                    // Zero matters here: below it the meter is on emergency credit.
                    if series.contains(where: { $0.balance < 0 }) {
                        RuleMark(y: .value("Zero", 0))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(Theme.Status.critical.color.opacity(0.6))
                    }

                    if let selectedDate, let point = nearest(to: selectedDate) {
                        RuleMark(x: .value("Selected", point.date))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .foregroundStyle(ChartPalette.gridLine)
                            .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                                ChartTooltip(
                                    title: Formatters.taka(point.balance),
                                    subtitle: Formatters.dayMonth(point.date)
                                )
                            }

                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Balance", point.balance)
                        )
                        .symbolSize(90)
                        .foregroundStyle(ChartPalette.balance)
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartYAxis { recessiveYAxis(format: .currency) }
                .chartXAxis { recessiveXAxis() }
                .frame(height: 180)
            }
        }
    }

    private func nearest(to date: Date) -> (date: Date, balance: Double)? {
        series.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
        }
    }
}

// MARK: - Daily spend

/// Estimated taka per day — bars, because each day is a discrete magnitude.
struct DailySpendChart: View {
    let meter: Meter
    @State private var selectedDate: Date?

    private var series: [(date: Date, amount: Double)] {
        ConsumptionAnalytics.dailySeries(meter: meter, days: 30)
    }

    private var average: Double? {
        guard !series.isEmpty else { return nil }
        return series.reduce(0) { $0 + $1.amount } / Double(series.count)
    }

    var body: some View {
        Card(title: "Estimated daily spend") {
            if series.isEmpty {
                EmptyChartHint(message: "Daily spend is worked out from the gap between readings. It appears after a second sync.")
            } else {
                Chart {
                    ForEach(series, id: \.date) { point in
                        BarMark(
                            x: .value("Date", point.date, unit: .day),
                            y: .value("Spend", point.amount),
                            width: .fixed(6)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(ChartPalette.spend.opacity(selectedDate == nil ? 0.9 : 0.35))
                    }

                    if let average {
                        RuleMark(y: .value("Average", average))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .foregroundStyle(Color.secondary.opacity(0.7))
                            .annotation(position: .top, alignment: .leading) {
                                Text("avg \(Formatters.takaShort(average))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                    }

                    if let selectedDate, let point = nearest(to: selectedDate) {
                        BarMark(
                            x: .value("Date", point.date, unit: .day),
                            y: .value("Spend", point.amount),
                            width: .fixed(6)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(ChartPalette.spend)
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            ChartTooltip(
                                title: Formatters.taka(point.amount),
                                subtitle: Formatters.dayMonth(point.date)
                            )
                        }
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartYAxis { recessiveYAxis(format: .currency) }
                .chartXAxis { recessiveXAxis() }
                .frame(height: 160)
            }
        }
    }

    private func nearest(to date: Date) -> (date: Date, amount: Double)? {
        series.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
        }
    }
}

// MARK: - Monthly usage

/// NESCO's own monthly figures — the only consumption data it publishes.
struct MonthlyUsageChart: View {
    let meter: Meter

    /// Units and taka are different measures, so they get their own view of the
    /// same bars rather than a second y-axis.
    private enum Measure: String, CaseIterable, Identifiable {
        case units = "Units"
        case taka = "Taka"
        var id: String { rawValue }
    }

    @State private var measure: Measure = .units

    private var series: [MonthlyUsage] {
        Array(
            meter.monthlyUsage
                .sorted { $0.month < $1.month }
                .suffix(12)
        )
    }

    private func value(_ usage: MonthlyUsage) -> Double? {
        measure == .units ? usage.unit : usage.electricityTaka
    }

    private var plotted: [MonthlyUsage] {
        series.filter { value($0) != nil }
    }

    var body: some View {
        Card {
            HStack {
                Text("Monthly use, from NESCO")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Measure", selection: $measure) {
                    ForEach(Measure.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }

            if plotted.isEmpty {
                EmptyChartHint(message: "NESCO has not published monthly usage for this meter yet.")
            } else {
                let peak = plotted.compactMap { value($0) }.max()

                Chart(plotted) { usage in
                    BarMark(
                        x: .value("Month", usage.shortLabel),
                        y: .value(measure.rawValue, value(usage) ?? 0)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(ChartPalette.units.opacity(0.9))
                    .annotation(position: .top) {
                        // Only the peak month is labelled, so a number appears
                        // where it means something.
                        if value(usage) == peak {
                            Text(measure == .units ? Formatters.units(peak) : Formatters.takaShort(peak))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartYAxis { recessiveYAxis(format: measure == .taka ? .currency : .plain) }
                .chartXAxis { recessiveXAxis(isCategorical: true) }
                .frame(height: 160)
                .animation(.snappy, value: measure)
            }
        }
    }
}

// MARK: - Shared chart furniture

private enum AxisFormat { case currency, plain }

/// Grid and axes stay recessive so the data carries the chart.
@AxisContentBuilder
private func recessiveYAxis(format: AxisFormat) -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisGridLine().foregroundStyle(ChartPalette.gridLine)
        AxisValueLabel {
            if let number = value.as(Double.self) {
                Text(format == .currency ? Formatters.takaShort(number) : String(format: "%.0f", number))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@AxisContentBuilder
private func recessiveXAxis(isCategorical: Bool = false) -> some AxisContent {
    if isCategorical {
        AxisMarks { value in
            AxisValueLabel()
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    } else {
        AxisMarks(values: .stride(by: .day, count: 7)) { value in
            AxisGridLine().foregroundStyle(ChartPalette.gridLine)
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(Formatters.dayMonth(date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ChartTooltip: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.weight(.semibold))
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct EmptyChartHint: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }
}
