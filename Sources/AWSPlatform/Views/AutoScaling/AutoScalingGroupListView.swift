import SwiftUI

struct AutoScalingGroupListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: AutoScalingViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: "Auto Scaling groups", isLoading: vm.isLoading, searchText: $vm.searchText,
                        onRefresh: vm.refresh, onCancel: vm.cancelLoading, searchPlaceholder: "Search Auto Scaling groups")
                .disabled(vm.scope?.isValid != true)
            Divider()
            List(vm.filteredGroups, selection: $vm.selectedGroup) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).fontWeight(.medium).lineLimit(1).help(group.name)
                    Text(L10n.format("Desired %@ · Min %@ · Max %@", number(group.desiredCapacity),
                                     number(group.minSize), number(group.maxSize), locale: locale))
                        .font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                .padding(.vertical, 4).tag(group).help(group.arn)
            }
            .listStyle(.inset)
            .overlay {
                if !vm.isLoading, vm.filteredGroups.isEmpty {
                    EmptyStateView(text: emptyMessage, icon: vm.error == nil ? "arrow.up.arrow.down" : "exclamationmark.triangle")
                }
            }
            ResourceListFooter(visible: vm.filteredGroups.count, total: vm.groups.count)
        }
    }

    private var emptyMessage: String {
        if vm.scope == nil { return "Choose a profile to view Auto Scaling groups." }
        if vm.groups.isEmpty { return vm.error ?? "No Auto Scaling groups in this region." }
        return "No matching Auto Scaling groups. Try another search."
    }

    private func number(_ value: Int?) -> String {
        value.map(String.init) ?? L10n.text("Not returned", locale: locale)
    }
}
