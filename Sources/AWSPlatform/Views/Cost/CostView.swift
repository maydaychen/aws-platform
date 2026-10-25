import SwiftUI

struct CostView: View {
    @ObservedObject var vm: CostViewModel
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let scope = vm.scope {
                    scopeHeader(scope)
                    filters
                    if let error = vm.error {
                        NoticeBanner(message: vm.report == nil ? error : "Could not update the report. Showing the saved result below. \(error)")
                    }
                    if let message = vm.statusMessage {
                        Text(L10n.text(message, locale: locale)).font(.caption).foregroundColor(.secondary)
                    }
                    if let report = vm.report {
                        CostReportView(report: report)
                    } else if vm.isLoading {
                        billingNotice
                        VStack(spacing: 12) {
                            ProgressView()
                            Text(L10n.text("Loading costs for this account…", locale: locale)).foregroundColor(.secondary)
                            Text(L10n.text("Results appear after every page is retrieved.", locale: locale)).font(.caption).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        billingNotice
                        EmptyStateView(
                            text: vm.error == nil && vm.statusMessage == nil
                                ? "No cost report loaded. Choose filters and apply, or refresh."
                                : "No cost report is available. Use Apply or Refresh to try again.",
                            icon: "chart.bar.xaxis"
                        )
                        .frame(minHeight: 220)
                    }
                    if vm.report != nil { billingNotice }
                } else {
                    EmptyStateView(text: "Select a profile and verify its connection to view this account's costs.", icon: "person.crop.circle.badge.questionmark")
                        .frame(minHeight: 260)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { vm.loadIfNeeded() }
        .onChange(of: vm.scope) { _ in vm.loadIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(L10n.text("Costs", locale: locale)).font(.title2.weight(.semibold))
            Spacer()
            if vm.isLoading {
                ProgressView().controlSize(.small)
                Button(L10n.text("Cancel", locale: locale), action: vm.cancel)
            }
            Button(action: vm.refresh) {
                Label(L10n.text("Refresh", locale: locale), systemImage: "arrow.clockwise")
            }
            .disabled(vm.scope == nil || vm.isLoading)
            .help(L10n.text("Request updated data from Cost Explorer. API charges apply.", locale: locale))
        }
    }

    private func scopeHeader(_ scope: CostScope) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(scope.profileName).font(.headline).fixedSize()
                accountLabel(scope)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(scope.profileName).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                accountLabel(scope)
            }
        }
        .textSelection(.enabled)
    }

    private func accountLabel(_ scope: CostScope) -> some View {
        Text(L10n.format("%@ · Current account only", scope.accountID, locale: locale))
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .fixedSize()
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 12) {
                    periodPicker
                    regionPicker
                    applyButton
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 12) {
                    periodPicker
                    regionPicker
                    applyButton
                }
            }
            if vm.period == .custom {
                HStack(spacing: 16) {
                    DatePicker(L10n.text("From", locale: locale), selection: $vm.customStart, in: vm.earliestDate...vm.latestDate, displayedComponents: .date)
                    DatePicker(L10n.text("Through", locale: locale), selection: $vm.customEnd, in: vm.earliestDate...vm.latestDate, displayedComponents: .date)
                    Spacer(minLength: 0)
                }
                .environment(\.timeZone, CostDates.calendar.timeZone)
                .datePickerStyle(.field)
            }
            Text(L10n.text(vm.hasUnappliedFilters
                 ? "Filters changed. Apply to update; the report keeps its original scope."
                 : "Completed UTC days only; today's partial costs are excluded.", locale: locale))
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(10)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var periodPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("Period", locale: locale)).font(.caption).foregroundColor(.secondary)
            Picker(L10n.text("Period", locale: locale), selection: $vm.period) {
                ForEach(CostPeriod.allCases) { period in Text(L10n.text(period.title, locale: locale)).tag(period) }
            }
            .labelsHidden()
            .frame(width: 170)
        }
    }

    private var regionPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("Cost region", locale: locale)).font(.caption).foregroundColor(.secondary)
            Picker(L10n.text("Cost region", locale: locale), selection: $vm.selectedRegion) {
                Text(L10n.text("All regions", locale: locale)).tag(Optional<String>.none)
                ForEach(vm.availableRegions, id: \.self) { region in
                    Text(CostDisplay.region(region, locale: locale)).tag(Optional(region))
                }
            }
            .labelsHidden()
            .frame(width: 230)
            .help(L10n.text("Independent of resource regions. AWS billing region values are shown as returned, including any global-service values.", locale: locale))
        }
    }

    private var applyButton: some View {
        Button(L10n.text("Apply", locale: locale), action: vm.applyFilters)
            .disabled(vm.isLoading)
            .help(L10n.text("Apply dates and cost region. Previously loaded filters use the in-memory cache.", locale: locale))
    }

    private var billingNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Cost Explorer API requests are billable, including pagination. Refresh, new filters and automatic retries can make additional requests. Saved reports are reused during this session.", locale: locale))
                    .fixedSize(horizontal: false, vertical: true)
                Link(L10n.text("AWS Cost Explorer pricing", locale: locale), destination: URL(string: "https://aws.amazon.com/aws-cost-management/aws-cost-explorer/pricing/")!)
            }
        }
        .font(.caption).foregroundColor(.secondary)
    }
}
