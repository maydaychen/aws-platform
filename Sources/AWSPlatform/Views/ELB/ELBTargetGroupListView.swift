import SwiftUI

struct ELBTargetGroupListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: ELBViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: "Target groups", isLoading: vm.isTargetGroupsLoading, searchText: $vm.groupSearchText,
                        onRefresh: vm.refreshTargetGroups, onCancel: vm.cancelTargetGroups,
                        searchPlaceholder: "Search target groups")
                .disabled(vm.scope == nil)
            VStack(alignment: .leading, spacing: 8) {
                ELBScopeCaption(scope: vm.scope)
                Picker(L10n.text("Target type", locale: locale), selection: $vm.targetTypeFilter) {
                    Text(L10n.text("All target types", locale: locale)).tag("All")
                    ForEach(Set(vm.targetGroups.map(\.targetType)).sorted(), id: \.self) { type in Text(type).tag(type) }
                }
                .labelsHidden().disabled(vm.scope == nil)
                if let error = vm.targetGroupsError { NoticeBanner(message: error) }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            List(vm.filteredTargetGroups, selection: $vm.selectedTargetGroup) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.name).fontWeight(.medium).lineLimit(2).help(group.name)
                    Text("\(group.targetType) · \(ELBDisplay.returned(group.protocolName, locale: locale))\(group.port.map { ":\($0)" } ?? "")")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                .padding(.vertical, 5).tag(group).help(group.arn)
            }
            .listStyle(.inset)
            .overlay {
                if vm.isTargetGroupsLoading && vm.targetGroups.isEmpty {
                    ProgressView(L10n.text("Loading target groups…", locale: locale))
                } else if !vm.isTargetGroupsLoading && vm.filteredTargetGroups.isEmpty {
                    EmptyStateView(text: emptyMessage, icon: "target")
                }
            }
            ResourceListFooter(visible: vm.filteredTargetGroups.count, total: vm.targetGroups.count)
        }
    }

    private var emptyMessage: String {
        if vm.scope == nil { return "Choose a profile to view target groups." }
        if vm.targetGroupsError != nil { return "No target group list is available. Use Refresh to retry." }
        return vm.targetGroups.isEmpty ? "No target groups were returned in this region."
            : "No matching target groups. Try another search or type."
    }
}
