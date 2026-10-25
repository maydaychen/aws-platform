import SwiftUI

struct RDSDatabaseListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: RDSViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: "RDS databases", isLoading: vm.isLoading, searchText: $vm.searchText,
                        onRefresh: vm.refresh, onCancel: vm.cancelLoading, searchPlaceholder: "Search databases")
                .disabled(vm.scope?.isValid != true)
            Picker(L10n.text("Database type", locale: locale), selection: $vm.kindFilter) {
                Text(L10n.text("All types", locale: locale)).tag(RDSResourceKind?.none)
                ForEach(RDSResourceKind.allCases) { kind in
                    Text(L10n.text(kind.title, locale: locale)).tag(Optional(kind))
                }
            }
            .pickerStyle(.menu).labelsHidden()
            .accessibilityLabel(L10n.text("Database type", locale: locale))
            .disabled(vm.scope == nil)
            .padding(.horizontal, WorkspaceLayout.contextSpacing).padding(.bottom, WorkspaceLayout.controlSpacing)
            Divider()
            List(vm.filteredDatabases, selection: $vm.selectedDatabase) { database in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(database.identifier).fontWeight(.medium).lineLimit(1).help(database.identifier)
                        Spacer(minLength: 0)
                        Text(L10n.text(database.kind.singularTitle, locale: locale))
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    Text(summary(database)).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                .padding(.vertical, 4).tag(database).help(database.arn)
            }
            .listStyle(.inset)
            .overlay {
                if !vm.isLoading, vm.filteredDatabases.isEmpty {
                    EmptyStateView(text: emptyMessage, icon: vm.databases.isEmpty && vm.error != nil
                        ? "exclamationmark.triangle" : "cylinder")
                }
            }
            if !vm.databases.isEmpty {
                if let error = vm.instanceError { NoticeBanner(message: error) }
                if let error = vm.clusterError { NoticeBanner(message: error) }
            }
            ResourceListFooter(visible: vm.filteredDatabases.count, total: vm.databases.count)
        }
    }

    private var emptyMessage: String {
        if vm.scope == nil { return "Choose a profile to view RDS databases." }
        if vm.databases.isEmpty {
            return vm.error ?? "No RDS DB instances or clusters in this region."
        }
        return "No matching databases. Try another search or type."
    }

    private func summary(_ database: RDSDatabase) -> String {
        [database.engine, database.engineVersion, database.status].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
