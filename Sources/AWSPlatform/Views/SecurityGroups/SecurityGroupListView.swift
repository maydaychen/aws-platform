import SwiftUI

struct SecurityGroupListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: SecurityGroupsViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: "Security groups", isLoading: vm.isLoading, searchText: $vm.searchText,
                        onRefresh: vm.refresh, onCancel: vm.cancel, searchPlaceholder: "Search names, rules or tags")
                .disabled(vm.scope?.isValid != true)
            VStack(alignment: .leading, spacing: 8) {
                if let scope = vm.scope {
                    Text("\(scope.accountID) · \(scope.region)")
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Picker(L10n.text("VPC", locale: locale), selection: $vm.vpcFilter) {
                    ForEach(vm.availableVPCs, id: \.self) { value in
                        Text(value == "All" ? L10n.text("All VPCs", locale: locale) : value).tag(value)
                    }
                }
                .labelsHidden().disabled(vm.scope?.isValid != true)
                if let error = vm.error { NoticeBanner(message: error) }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            List(vm.filteredGroups, selection: $vm.selectedGroup) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.name).fontWeight(.medium).lineLimit(2).help(group.name)
                    Text(group.id).font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1)
                }
                .padding(.vertical, 5).tag(group)
            }
            .listStyle(.inset)
            .overlay {
                if vm.isLoading && vm.groups.isEmpty {
                    ProgressView(L10n.text("Loading security groups…", locale: locale))
                } else if !vm.isLoading && vm.filteredGroups.isEmpty {
                    EmptyStateView(text: emptyMessage, icon: "shield")
                }
            }
            HStack {
                Text(vm.filteredGroups.count == vm.groups.count
                     ? L10n.format(vm.groups.count == 1 ? "%@ security group" : "%@ security groups", String(vm.groups.count), locale: locale)
                     : L10n.format("%@ of %@ security groups", String(vm.filteredGroups.count), String(vm.groups.count), locale: locale))
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var emptyMessage: String {
        if vm.scope == nil { return "Choose a profile to view security groups." }
        if vm.error != nil { return "No security group list is available. Use Refresh to retry." }
        return vm.groups.isEmpty ? "No security groups were returned in this region."
            : "No matching security groups. Try another search or VPC."
    }
}
