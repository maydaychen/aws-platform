import SwiftUI

struct EBSListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: EBSViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: vm.kind.title, isLoading: vm.isLoading, searchText: $vm.searchText,
                        onRefresh: vm.refresh, onCancel: vm.cancel, searchPlaceholder: "Search names, IDs or tags")
                .disabled(vm.scope?.isValid != true)
            VStack(alignment: .leading, spacing: 8) {
                if let scope = vm.scope {
                    Text("\(scope.accountID) · \(scope.region)").font(.caption.monospacedDigit())
                        .foregroundColor(.secondary).textSelection(.enabled)
                }
                if vm.kind == .snapshot {
                    Text(L10n.text("Only snapshots owned by the current account", locale: locale))
                        .font(.caption).foregroundColor(.secondary)
                }
                Picker(L10n.text("State", locale: locale), selection: $vm.stateFilter) {
                    ForEach(vm.availableStates, id: \.self) { Text(L10n.text($0, locale: locale)).tag($0) }
                }.labelsHidden().disabled(vm.scope?.isValid != true)
                if let error = vm.error { NoticeBanner(message: error) }
                if vm.isStale { NoticeBanner(message: "Showing previously loaded EBS resources; they may be out of date.") }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            List(vm.filteredResources, selection: $vm.selectedResource) { resource in
                VStack(alignment: .leading, spacing: 6) {
                    Text(resource.name).fontWeight(.medium).lineLimit(2).help(resource.name)
                    Text(resource.id).font(.caption.monospaced()).foregroundColor(.secondary)
                    Text([resource.sizeGiB.map { "\($0) GiB" }, resource.volumeType, resource.state].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundColor(.secondary)
                }.padding(.vertical, 5).tag(resource)
            }
            .listStyle(.inset)
            .overlay {
                if vm.isLoading && vm.resources.isEmpty {
                    ProgressView(L10n.text("Loading EBS resources…", locale: locale))
                } else if !vm.isLoading && vm.filteredResources.isEmpty {
                    EmptyStateView(text: emptyMessage, icon: vm.kind.service.icon)
                }
            }
            HStack {
                Text(L10n.format("%@ of %@ resources", String(vm.filteredResources.count), String(vm.resources.count), locale: locale))
                Spacer(minLength: 0)
            }.font(.caption).foregroundColor(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var emptyMessage: String {
        if vm.scope == nil { return "Select and verify a profile and region before loading EBS resources." }
        if vm.error != nil { return "No EBS list is available. Use Refresh to retry." }
        if !vm.resources.isEmpty { return "No matching EBS resources. Try another search or state." }
        return vm.kind == .volume ? "No EBS volumes were returned in this region." : "No snapshots owned by this account were returned in this region."
    }
}
