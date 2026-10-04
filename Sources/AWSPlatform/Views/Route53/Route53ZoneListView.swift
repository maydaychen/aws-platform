import SwiftUI

struct Route53ZoneListView: View {
    @ObservedObject var vm: Route53ViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: "Hosted zones", isLoading: vm.isLoading, searchText: $vm.searchText,
                        onRefresh: vm.refresh, onCancel: vm.cancelLoading,
                        searchPlaceholder: "Search hosted zones")
                .disabled(vm.scope == nil)
            VStack(alignment: .leading, spacing: 8) {
                if let scope = vm.scope {
                    Text("\(scope.accountID) · Global")
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .help("Hosted zones in the current profile's account. Independent of the resource region.")
                }
                Picker("Zone visibility", selection: $vm.privateFilter) {
                    Text("All zones").tag(Optional<Bool>.none)
                    Text("Public").tag(Optional(false))
                    Text("Private").tag(Optional(true))
                }
                .labelsHidden().pickerStyle(.segmented)
                .disabled(vm.scope == nil)
                if let error = vm.error { NoticeBanner(message: error) }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            List(vm.filteredZones, selection: $vm.selectedZone) { zone in
                VStack(alignment: .leading, spacing: 6) {
                    Text(zone.name).fontWeight(.medium).lineLimit(2).help(zone.name)
                    HStack(spacing: 8) {
                        Label(zone.isPrivate ? "Private" : "Public", systemImage: zone.isPrivate ? "lock" : "globe")
                        Spacer(minLength: 0)
                        Text(zone.recordCount.map { "\($0) records" } ?? "Count not returned")
                            .lineLimit(1)
                    }
                    .font(.caption).foregroundColor(.secondary)
                }
                .padding(.vertical, 5)
                .tag(zone).help(zone.id)
            }
            .listStyle(.inset)
            .overlay {
                if vm.isLoading && vm.zones.isEmpty {
                    ProgressView("Loading hosted zones…")
                } else if !vm.isLoading && vm.filteredZones.isEmpty {
                    EmptyStateView(text: emptyMessage, icon: "network")
                }
            }
            HStack {
                Text(vm.filteredZones.count == vm.zones.count
                     ? "\(vm.zones.count) \(vm.zones.count == 1 ? "hosted zone" : "hosted zones")"
                     : "\(vm.filteredZones.count) of \(vm.zones.count) hosted zones")
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundColor(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var emptyMessage: String {
        if vm.scope == nil { return "Choose a profile to view hosted zones." }
        if vm.error != nil { return "No hosted zone list is available. Use Refresh to retry." }
        return vm.zones.isEmpty ? "No hosted zones were returned for this account."
            : "No matching hosted zones. Try another search or filter."
    }
}
