import SwiftUI

struct CloudWatchLogGroupListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: CloudWatchLogsBrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: "Log groups", isLoading: vm.isLoading, searchText: $vm.searchText,
                        onRefresh: vm.refresh, onCancel: vm.cancelLoading, searchPlaceholder: "Search log groups")
                .disabled(vm.scope == nil)
            List(vm.filteredGroups, selection: $vm.selectedGroup) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).fontWeight(.medium).lineLimit(2).help(group.name)
                    if let logClass = group.logClass {
                        Text(logClass).font(.caption).foregroundColor(.secondary)
                    }
                }.padding(.vertical, 4).tag(group)
            }
            .listStyle(.inset)
            .overlay {
                if !vm.isLoading, vm.filteredGroups.isEmpty {
                    EmptyStateView(text: vm.error ?? (vm.scope == nil ? "Choose a profile to view log groups." :
                        vm.groups.isEmpty ? "No log groups in this region." : "No matching log groups."), icon: "doc.text.magnifyingglass")
                }
            }
            ResourceListFooter(visible: vm.filteredGroups.count, total: vm.groups.count)
        }
    }
}
