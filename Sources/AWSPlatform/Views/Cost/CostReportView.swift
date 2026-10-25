import SwiftUI

struct CostReportView: View {
    let report: CostReport
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            reportMetadata
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                totalCard("This month", amount: report.thisMonth,
                          subtitle: report.query.currentMonthStart == report.query.referenceDate
                            ? L10n.text("No completed days this month", locale: locale)
                            : L10n.format("Through %@ UTC", CostDates.string(CostDates.inclusiveEnd(of: report.query.summaryRange)), locale: locale))
                totalCard("Last month", amount: report.lastMonth, subtitle: L10n.text("Full calendar month · UTC", locale: locale))
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("Daily costs", locale: locale)).font(.headline)
                    Spacer()
                    Text(report.daily.isEmpty ? L10n.text("Not available", locale: locale) : CostDisplay.amount(report.selectedTotal, currency: report.currency))
                        .font(.headline.monospacedDigit())
                        .help(report.daily.isEmpty ? L10n.text("No daily cost amounts returned", locale: locale) : L10n.format("Selected-period total: %@", report.selectedTotal.description, locale: locale))
                }
                Text(CostDisplay.coverage(report.query.range, locale: locale))
                    .font(.caption).foregroundColor(.secondary)
                if report.daily.isEmpty {
                    EmptyStateView(text: report.query.range.isEmpty
                                   ? "This period has no completed UTC days yet. Choose another period to see costs."
                                   : "AWS returned no cost data for this account and these filters.", icon: "chart.bar.xaxis")
                        .frame(height: 180)
                } else {
                    CostTrendView(report: report)
                }
            }
            .costPanel()
            serviceBreakdown
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format("%@ API calls/pages for this result · SDK retries excluded", String(report.apiRequestCount), locale: locale))
                Text(L10n.text("Billing data can arrive late or change. This is not a final invoice.", locale: locale))
            }
            .font(.caption).foregroundColor(.secondary)
        }
    }

    private var reportMetadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    metricLabel
                    Spacer(minLength: 0)
                    fetchedLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    metricLabel
                    fetchedLabel
                }
            }
            Text(L10n.format("Cost region: %@ · All amounts below", CostDisplay.region(report.query.region, locale: locale), locale: locale))
                .font(.caption).foregroundColor(.secondary)
        }
        .textSelection(.enabled)
    }

    private var metricLabel: some View {
        HStack(spacing: 8) {
            Text("UnblendedCost").font(.caption.weight(.semibold))
            Text(report.currency ?? L10n.text("No currency returned", locale: locale)).font(.caption.monospaced())
            if report.estimated {
                Label(L10n.text("Estimated", locale: locale), systemImage: "clock").font(.caption).foregroundColor(.orange)
            }
        }
        .fixedSize()
    }

    private var fetchedLabel: some View {
        Text(L10n.format("Fetched %@", report.fetchedAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(locale)), locale: locale))
            .font(.caption).foregroundColor(.secondary)
            .fixedSize()
    }

    private func totalCard(_ title: String, amount: Decimal?, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text(title, locale: locale)).font(.callout).foregroundColor(.secondary)
            Text(amount.map { CostDisplay.amount($0, currency: report.currency) } ?? L10n.text("Not available", locale: locale))
                .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
                .help(amount.map { "\($0.description) \(report.currency ?? "")" } ?? L10n.text("No amount returned", locale: locale))
                .textSelection(.enabled)
            Text(subtitle).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .costPanel()
    }

    private var serviceBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("By service", locale: locale)).font(.headline)
                Spacer()
                Text(L10n.format("%@ services", String(report.services.count), locale: locale)).font(.caption).foregroundColor(.secondary)
            }
            Text(L10n.text("Selected period · Negative amounts include credits or refunds", locale: locale))
                .font(.caption).foregroundColor(.secondary)
            if report.services.isEmpty {
                Text(L10n.text("No service costs returned.", locale: locale)).foregroundColor(.secondary).padding(.vertical, 12)
            } else {
                ForEach(report.services.sorted { $0.amount > $1.amount }) { service in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(service.name).font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text(CostDisplay.amount(service.amount, currency: report.currency))
                            .font(.callout.monospacedDigit()).textSelection(.enabled)
                            .fixedSize()
                            .foregroundColor(service.amount < 0 ? .orange : .primary)
                            .help("\(service.amount.description) \(report.currency ?? "")")
                    }
                    Divider()
                }
            }
        }
        .costPanel()
    }
}

enum CostDisplay {
    static func region(_ value: String?, locale: Locale) -> String {
        guard let value else { return L10n.text("All regions", locale: locale) }
        return value.isEmpty ? L10n.text("Unspecified (empty AWS value)", locale: locale) : value
    }

    static func amount(_ value: Decimal, currency: String?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let number = formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
        return currency.map { "\(number) \($0)" } ?? number
    }

    static func coverage(_ range: CostDateRange, locale: Locale) -> String {
        guard !range.isEmpty else { return L10n.text("No completed days · UTC", locale: locale) }
        return L10n.format("%@ through %@ · UTC", range.startString, CostDates.string(CostDates.inclusiveEnd(of: range)), locale: locale)
    }
}

private extension View {
    func costPanel() -> some View {
        padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06)))
    }
}
