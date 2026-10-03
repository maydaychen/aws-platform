import SwiftUI

struct CostView: View {
    @ObservedObject var vm: CostViewModel

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
                        Text(message).font(.caption).foregroundColor(.secondary)
                    }
                    if let report = vm.report {
                        CostReportView(report: report)
                    } else if vm.isLoading {
                        billingNotice
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Loading costs for this account…").foregroundColor(.secondary)
                            Text("Results appear after every page is retrieved.").font(.caption).foregroundColor(.secondary)
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
            Text("Costs").font(.title2.weight(.semibold))
            Spacer()
            if vm.isLoading {
                ProgressView().controlSize(.small)
                Button("Cancel", action: vm.cancel)
            }
            Button(action: vm.refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(vm.scope == nil || vm.isLoading)
            .help("Request updated data from Cost Explorer. API charges apply.")
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
        Text("\(scope.accountID) · Current account only")
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
                    DatePicker("From", selection: $vm.customStart, in: vm.earliestDate...vm.latestDate, displayedComponents: .date)
                    DatePicker("Through", selection: $vm.customEnd, in: vm.earliestDate...vm.latestDate, displayedComponents: .date)
                    Spacer(minLength: 0)
                }
                .environment(\.timeZone, CostDates.calendar.timeZone)
                .datePickerStyle(.field)
            }
            Text(vm.hasUnappliedFilters
                 ? "Filters changed. Apply to update; the report keeps its original scope."
                 : "Completed UTC days only; today's partial costs are excluded.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(10)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var periodPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Period").font(.caption).foregroundColor(.secondary)
            Picker("Period", selection: $vm.period) {
                ForEach(CostPeriod.allCases) { period in Text(period.title).tag(period) }
            }
            .labelsHidden()
            .frame(width: 170)
        }
    }

    private var regionPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Cost region").font(.caption).foregroundColor(.secondary)
            Picker("Cost region", selection: $vm.selectedRegion) {
                Text("All regions").tag(Optional<String>.none)
                ForEach(vm.availableRegions, id: \.self) { region in
                    Text(CostDisplay.region(region)).tag(Optional(region))
                }
            }
            .labelsHidden()
            .frame(width: 230)
            .help("Independent of resource regions. AWS billing region values are shown as returned, including any global-service values.")
        }
    }

    private var applyButton: some View {
        Button("Apply", action: vm.applyFilters)
            .disabled(vm.isLoading)
            .help("Apply dates and cost region. Previously loaded filters use the in-memory cache.")
    }

    private var billingNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Cost Explorer API requests are billable, including pagination. Refresh, new filters and automatic retries can make additional requests. Saved reports are reused during this session.")
                    .fixedSize(horizontal: false, vertical: true)
                Link("AWS Cost Explorer pricing", destination: URL(string: "https://aws.amazon.com/aws-cost-management/aws-cost-explorer/pricing/")!)
            }
        }
        .font(.caption).foregroundColor(.secondary)
    }
}
