import SwiftUI

struct HealthView: View {
    @ObservedObject var vm: HealthViewModel
    @Environment(\.locale) private var locale
    @State private var accountFilterDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            if let scope = vm.scope {
                VStack(alignment: .leading, spacing: 5) {
                    Text(scope.profileName).font(.headline)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker(L10n.text("Query scope", locale: locale), selection: Binding(
                        get: { vm.queryMode }, set: { vm.setQueryMode($0) }
                    )) {
                        Text(L10n.text("Current account", locale: locale)).tag(HealthQueryMode.account)
                        Text(L10n.text("Entire organization", locale: locale)).tag(HealthQueryMode.organization)
                    }
                    .pickerStyle(.segmented)
                    Text(L10n.format(vm.queryMode == .account ? "%@ · Current account only · All regions"
                                    : "%@ · Organization view · All regions", scope.accountID, locale: locale))
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if vm.queryMode == .organization {
                        organizationFilter
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
            }
            HSplitView {
                HealthEventListView(vm: vm)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
                Group {
                    if let event = vm.selectedEvent, vm.scope != nil {
                        HealthEventDetailView(event: event, vm: vm)
                    } else {
                        EmptyStateView(
                            text: vm.scope == nil
                                ? "Select a profile and verify its connection to view this account's Health events."
                                : "Select an event to view its details and affected entities.",
                            icon: "heart.text.square"
                        )
                    }
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { vm.loadIfNeeded() }
        .onChange(of: vm.scope) { _ in vm.loadIfNeeded() }
        .onChange(of: vm.accountFilter) { accountFilterDraft = $0 }
        .onChange(of: vm.queryMode) { _ in accountFilterDraft = vm.accountFilter }
    }

    private var organizationFilter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Requires organizational view, a management or delegated administrator role, and eligible AWS Support. Events are retained for up to 90 days.", locale: locale))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(L10n.text("Account ID (empty for all accounts)", locale: locale), text: $accountFilterDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { vm.applyAccountFilter(accountFilterDraft) }
                    .accessibilityLabel(L10n.text("Filter organization by account ID", locale: locale))
                Button(L10n.text("Apply account filter", locale: locale)) { vm.applyAccountFilter(accountFilterDraft) }
            }
            Text(L10n.format("Account filter: %@", vm.accountFilter.isEmpty ? L10n.text("All accounts", locale: locale) : vm.accountFilter, locale: locale))
                .font(.caption).foregroundColor(.secondary)
        }
    }
}
