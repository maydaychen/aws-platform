import SwiftUI

struct CostReportView: View {
    let report: CostReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            reportMetadata
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                totalCard("This month", amount: report.thisMonth,
                          subtitle: report.query.currentMonthStart == report.query.referenceDate
                            ? "No completed days this month"
                            : "Through \(CostDates.string(CostDates.inclusiveEnd(of: report.query.summaryRange))) UTC")
                totalCard("Last month", amount: report.lastMonth, subtitle: "Full calendar month · UTC")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Daily costs").font(.headline)
                    Spacer()
                    Text(report.daily.isEmpty ? "Not available" : CostDisplay.amount(report.selectedTotal, currency: report.currency))
                        .font(.headline.monospacedDigit())
                        .help(report.daily.isEmpty ? "No daily cost amounts returned" : "Selected-period total: \(report.selectedTotal.description)")
                }
                Text(CostDisplay.coverage(report.query.range))
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
                Text("\(report.apiRequestCount) API calls/pages for this result · SDK retries excluded")
                Text("Billing data can arrive late or change. This is not a final invoice.")
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
            Text("Cost region: \(CostDisplay.region(report.query.region)) · All amounts below")
                .font(.caption).foregroundColor(.secondary)
        }
        .textSelection(.enabled)
    }

    private var metricLabel: some View {
        HStack(spacing: 8) {
            Text("UnblendedCost").font(.caption.weight(.semibold))
            Text(report.currency ?? "No currency returned").font(.caption.monospaced())
            if report.estimated {
                Label("Estimated", systemImage: "clock").font(.caption).foregroundColor(.orange)
            }
        }
        .fixedSize()
    }

    private var fetchedLabel: some View {
        Text("Fetched \(report.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption).foregroundColor(.secondary)
            .fixedSize()
    }

    private func totalCard(_ title: String, amount: Decimal?, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout).foregroundColor(.secondary)
            Text(amount.map { CostDisplay.amount($0, currency: report.currency) } ?? "Not available")
                .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
                .help(amount.map { "\($0.description) \(report.currency ?? "")" } ?? "No amount returned")
                .textSelection(.enabled)
            Text(subtitle).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .costPanel()
    }

    private var serviceBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("By service").font(.headline)
                Spacer()
                Text("\(report.services.count) services").font(.caption).foregroundColor(.secondary)
            }
            Text("Selected period · Negative amounts include credits or refunds")
                .font(.caption).foregroundColor(.secondary)
            if report.services.isEmpty {
                Text("No service costs returned.").foregroundColor(.secondary).padding(.vertical, 12)
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
    static func region(_ value: String?) -> String {
        guard let value else { return "All regions" }
        return value.isEmpty ? "Unspecified (empty AWS value)" : value
    }

    static func amount(_ value: Decimal, currency: String?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let number = formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
        return currency.map { "\(number) \($0)" } ?? number
    }

    static func coverage(_ range: CostDateRange) -> String {
        guard !range.isEmpty else { return "No completed days · UTC" }
        return "\(range.startString) through \(CostDates.string(CostDates.inclusiveEnd(of: range))) · UTC"
    }
}

private extension View {
    func costPanel() -> some View {
        padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06)))
    }
}
