import Charts
import SwiftUI

struct CostTrendView: View {
    let report: CostReport
    @Environment(\.locale) private var locale
    @State private var showDailyAmounts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart(report.daily) { day in
                if let date = CostDates.date(day.date) {
                    BarMark(
                        x: .value(L10n.text("Day", locale: locale), date, unit: .day),
                        y: .value(report.currency ?? L10n.text("Amount", locale: locale), NSDecimalNumber(decimal: day.amount).doubleValue)
                    )
                    .foregroundStyle(day.amount < 0 ? Color.orange : Color.accentColor)
                    .accessibilityLabel(day.date)
                    .accessibilityValue(CostDisplay.amount(day.amount, currency: report.currency))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .environment(\.timeZone, CostDates.calendar.timeZone)
            .frame(height: 210)
            DisclosureGroup(L10n.text("Daily amounts", locale: locale), isExpanded: $showDailyAmounts) {
                LazyVStack(spacing: 8) {
                    ForEach(report.daily) { day in
                        HStack {
                            Text(day.date)
                            Spacer()
                            Text(CostDisplay.amount(day.amount, currency: report.currency))
                        }
                        .font(.caption.monospacedDigit())
                        .textSelection(.enabled)
                    }
                }
                .padding(.top, 10)
            }
            .font(.caption)
        }
    }
}
