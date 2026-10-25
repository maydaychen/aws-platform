import SwiftUI

struct FavoritesListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: FavoritesViewModel
    let onOpen: (ResourceFavorite) -> Void
    @State private var searchText = ""

    private var filtered: [ResourceFavorite] {
        vm.favorites.filter { $0.matches(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Favorites", locale: locale)).font(.headline)
                ResourceSearchField(text: $searchText, placeholder: "Search favorites")
            }
            .padding(12)
            Divider()

            if let error = vm.storageError {
                NoticeBanner(message: error)
                    .padding(.horizontal, 12)
            }

            List(filtered) { favorite in
                HStack {
                    Button {
                        onOpen(favorite)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: favorite.service.icon)
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(favorite.displayName)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text("\(favorite.service.rawValue) · \(favorite.profileName) · \(favorite.region)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.format("Open %@ in account %@, profile %@, region %@", favorite.resourceID, favorite.accountID, favorite.profileName, favorite.region, locale: locale))

                    Button {
                        vm.remove(favorite)
                    } label: {
                        Image(systemName: "star.fill").foregroundColor(.orange)
                    }
                    .buttonStyle(.borderless)
                    .disabled(vm.storageError != nil)
                    .help(L10n.text("Remove from Favorites", locale: locale))
                    .accessibilityLabel(L10n.format("Remove %@ from Favorites", favorite.displayName, locale: locale))
                }
                .padding(.vertical, 4)
                .contextMenu {
                    Button(L10n.text("Open", locale: locale)) { onOpen(favorite) }
                    Button(L10n.text("Remove from Favorites", locale: locale)) { vm.remove(favorite) }
                        .disabled(vm.storageError != nil)
                }
            }
            .listStyle(.inset)
            .overlay {
                if filtered.isEmpty {
                    EmptyStateView(text: vm.favorites.isEmpty
                        ? "Star a resource in its details to save it here."
                        : "No matching favorites", icon: "star")
                    .padding()
                    .allowsHitTesting(false)
                }
            }
            ResourceListFooter(visible: filtered.count, total: vm.favorites.count)
        }
    }
}
