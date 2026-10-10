import SwiftUI

struct HealthAffectedAccountsView: View {
    @ObservedObject var vm: HealthViewModel
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSectionTitle(title: "Affected accounts")
            if vm.isAccountsLoading {
                ProgressView(L10n.text("Loading affected accounts…", locale: locale)).controlSize(.small)
            } else if let error = vm.accountsError {
                NoticeBanner(message: error)
                Button(L10n.text("Retry affected accounts", locale: locale), action: vm.refreshAffectedAccounts)
            } else if vm.affectedAccounts.isEmpty {
                Text(L10n.text("No affected accounts were returned.", locale: locale)).foregroundColor(.secondary)
            } else {
                Picker(L10n.text("Affected account", locale: locale), selection: Binding(
                    get: { vm.selectedAccount }, set: { vm.selectAccount($0) }
                )) {
                    Text(L10n.text("Select an affected account", locale: locale)).tag(String?.none)
                    ForEach(vm.affectedAccounts, id: \.self) { account in
                        Text(account).tag(Optional(account))
                    }
                }
                Text(L10n.format("Affected accounts: %@", String(vm.affectedAccounts.count), locale: locale))
                    .font(.caption).foregroundColor(.secondary)
                if vm.selectedAccount == nil {
                    Text(L10n.text("Select an affected account to view its event description and resources.", locale: locale))
                        .font(.caption).foregroundColor(.secondary)
                }
                Button(L10n.text("Refresh affected accounts", locale: locale), action: vm.refreshAffectedAccounts)
            }
        }
    }
}
