import SwiftUI

struct AutoScalingGroupDetailView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: AutoScalingViewModel

    var body: some View {
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
                        AutoScalingGroupFieldsView(group: group, scope: vm.scope)
                        AutoScalingGroupHistoryView(vm: vm)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .id(group.arn)
            }
        } else {
            EmptyStateView(text: "Select an Auto Scaling group", icon: "arrow.up.arrow.down")
        }
    }
}
