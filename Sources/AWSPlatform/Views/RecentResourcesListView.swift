import SwiftUI

struct RecentResourcesListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: RecentResourcesViewModel
    let scope: RecentResourceScope?
    let onOpen: (ResourceFavorite) -> Void
    @State private var searchText = ""
    @State private var isClearConfirmationPresented = false
    @State private var pendingClearScope: RecentResourceScope?

    private var currentScope: RecentResourceScope? {
        guard let scope, scope.isValid else { return nil }
        return scope
    }

    private var scopedEntries: [RecentResource] {
        vm.entries(for: currentScope)
    }

    private var filtered: [RecentResource] {
        vm.entries(for: currentScope, matching: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let error = vm.storageError {
                NoticeBanner(message: error)
                    .padding(12)
            }

            List(filtered) { entry in
                resourceRow(entry)
            }
            .listStyle(.inset)
            .overlay {
                if filtered.isEmpty {
                    EmptyStateView(text: emptyMessage, icon: "clock")
                        .allowsHitTesting(false)
                }
            }
            ResourceListFooter(visible: filtered.count, total: scopedEntries.count)
        }
        .onChange(of: scope) { _ in
            searchText = ""
            isClearConfirmationPresented = false
            pendingClearScope = nil
        }
        .alert(L10n.text("Clear recent resources?", locale: locale), isPresented: $isClearConfirmationPresented,
               presenting: pendingClearScope) { confirmedScope in
            Button(L10n.text("Clear history", locale: locale), role: .destructive) {
                guard confirmedScope == currentScope else { return }
                vm.clear(scope: confirmedScope)
                pendingClearScope = nil
            }
            Button(L10n.text("Cancel", locale: locale), role: .cancel) {
                pendingClearScope = nil
            }
        } message: { confirmedScope in
            Text(L10n.format("Remove recent history for profile %@ in account %@? AWS resources and favorites will remain unchanged.", confirmedScope.profileName, confirmedScope.accountID, locale: locale))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Recent", locale: locale)).font(.headline)
                Spacer(minLength: 8)
                Button(L10n.text("Clear history…", locale: locale)) {
                    guard let currentScope else { return }
                    pendingClearScope = currentScope
                    isClearConfirmationPresented = true
                }
                .buttonStyle(.borderless)
                .disabled(scopedEntries.isEmpty || vm.storageError != nil)
                .help(L10n.text("Clear recent history for the current profile and account", locale: locale))
                .accessibilityLabel(L10n.text("Clear recent resources for the current profile", locale: locale))
            }
            if let currentScope {
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentScope.profileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(currentScope.profileName)
                    Text(L10n.format("Account %@", currentScope.accountID, locale: locale))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            }
            ResourceSearchField(text: $searchText, placeholder: "Search recent resources")
                .disabled(currentScope == nil)
        }
        .padding(12)
    }

    private func resourceRow(_ entry: RecentResource) -> some View {
        let resource = entry.resource
        return HStack(spacing: 8) {
            Button {
                open(entry)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: resource.service.icon)
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(resource.displayName)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(verbatim: entry.lastVisitedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)
                                .locale(locale)))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                                .help(L10n.format("Last visited %@", entry.lastVisitedAt.ISO8601Format(), locale: locale))
                        }
                        Text("\(resource.service.rawValue) · \(resource.region)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.format("Open %@ in account %@, profile %@, region %@", resource.resourceID, resource.accountID, resource.profileName, resource.region, locale: locale))

            Button {
                vm.remove(entry, scope: currentScope)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(vm.storageError != nil)
            .help(L10n.text("Remove from Recent", locale: locale))
            .accessibilityLabel(L10n.format("Remove %@ from Recent", resource.displayName, locale: locale))
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(L10n.text("Open", locale: locale)) { open(entry) }
            Button(L10n.text("Remove from Recent", locale: locale)) { vm.remove(entry, scope: currentScope) }
                .disabled(vm.storageError != nil)
        }
    }

    private func open(_ entry: RecentResource) {
        guard let currentScope, currentScope.contains(entry.resource) else { return }
        onOpen(entry.resource)
    }

    private var emptyMessage: String {
        if currentScope == nil {
            return "Select a profile and verify its connection to view recent resources."
        }
        if vm.storageError != nil {
            return "Recent history is unavailable. See the storage message above."
        }
        return scopedEntries.isEmpty
            ? "Open a resource to find it here later. Recent history is saved for this profile and account."
            : "No matching recent resources. Try another search."
    }
}
