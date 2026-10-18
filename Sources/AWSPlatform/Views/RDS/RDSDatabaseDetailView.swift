import SwiftUI

struct RDSDatabaseDetailView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: RDSViewModel

    var body: some View {
        if let database = vm.selectedDatabase, vm.scope?.isValid == true, vm.databases.contains(database) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Text(database.identifier).font(.title2.weight(.semibold))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(action: vm.refresh) { Image(systemName: "arrow.clockwise") }
                            .disabled(vm.isLoading)
                            .help(L10n.text("Refresh RDS databases", locale: locale))
                            .accessibilityLabel(L10n.text("Refresh RDS databases", locale: locale))
                        if vm.isLoading { Button(L10n.text("Cancel", locale: locale), action: vm.cancelLoading) }
                    }
                    Text(L10n.text(database.kind.singularTitle, locale: locale))
                        .font(.caption).foregroundColor(.secondary)
                    Text(L10n.text("Database metadata · Read only", locale: locale))
                        .font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                Divider()
                ScrollView {
                    RDSDatabaseFieldsView(database: database, scope: vm.scope)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .id(database.id)
            }
        } else {
            EmptyStateView(text: "Select an RDS DB instance or cluster", icon: "cylinder")
        }
    }
}
