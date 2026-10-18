import SwiftUI

struct AutoScalingGroupDetailView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: AutoScalingViewModel
    var insightsVM: AutoScalingInsightsViewModel? = nil
    var onOpen: (ELBResourceReference) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if let group = vm.selectedGroup, vm.scope?.isValid == true, vm.groups.contains(group) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Text(group.name).font(.title2.weight(.semibold))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button(action: vm.refreshDetails) { Image(systemName: "arrow.clockwise") }
                                .disabled(vm.isPoliciesLoading || vm.isActivitiesLoading)
                                .help(L10n.text("Refresh policies and activities", locale: locale))
                                .accessibilityLabel(L10n.text("Refresh policies and activities", locale: locale))
                            if vm.isPoliciesLoading || vm.isActivitiesLoading {
                                Button(L10n.text("Cancel", locale: locale), action: vm.cancelLoading)
                            }
                        }
                        Text(L10n.text("Auto Scaling metadata · Read only", locale: locale))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            AutoScalingGroupFieldsView(group: group, scope: vm.scope, onOpen: onOpen)
                            AutoScalingGroupHistoryView(vm: vm)
                            if let insightsVM {
                                AutoScalingBoundInsightsView(vm: insightsVM, scope: vm.scope, group: group)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    .id(group.arn)
                }
            } else {
                EmptyStateView(text: "Select an Auto Scaling group", icon: "arrow.up.arrow.down")
            }
        }
        .onAppear(perform: configureInsights)
        .onChange(of: vm.scope) { _ in configureInsights() }
        .onChange(of: vm.selectedGroup) { _ in configureInsights() }
        .onChange(of: vm.groups) { _ in configureInsights() }
        .onDisappear { insightsVM?.reset() }
    }

    private func configureInsights() {
        guard let group = vm.selectedGroup, vm.scope?.isValid == true, vm.groups.contains(group) else {
            insightsVM?.reset()
            return
        }
        insightsVM?.configure(scope: vm.scope, group: group)
    }
}

private struct AutoScalingBoundInsightsView: View {
    @ObservedObject var vm: AutoScalingInsightsViewModel
    let scope: MonitoringScope?
    let group: ASGGroup

    var body: some View {
        if vm.scope == scope, vm.group == group {
            AutoScalingInsightsView(vm: vm)
        }
    }
}
