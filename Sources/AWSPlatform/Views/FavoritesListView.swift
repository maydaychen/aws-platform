import SwiftUI

struct FavoritesListView: View {
    @ObservedObject var vm: FavoritesViewModel
    let onOpen: (ResourceFavorite) -> Void
    @State private var searchText = ""

    private var filtered: [ResourceFavorite] {
        vm.favorites.filter { $0.matches(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Favorites").font(.headline)
                TextField("Search favorites", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(12)

            if let error = vm.storageError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
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
                    .help("Open \(favorite.resourceID) in account \(favorite.accountID), profile \(favorite.profileName), region \(favorite.region)")

                    Button {
                        vm.remove(favorite)
                    } label: {
                        Image(systemName: "star.fill").foregroundColor(.yellow)
                    }
                    .buttonStyle(.borderless)
                    .disabled(vm.storageError != nil)
                    .help("Remove from Favorites")
                    .accessibilityLabel("Remove \(favorite.displayName) from Favorites")
                }
                .padding(.vertical, 4)
                .contextMenu {
                    Button("Open") { onOpen(favorite) }
                    Button("Remove from Favorites") { vm.remove(favorite) }
                        .disabled(vm.storageError != nil)
                }
            }
            .overlay {
                if filtered.isEmpty {
                    EmptyStateView(text: vm.favorites.isEmpty
                        ? "Star an EC2 instance, Lambda function, or S3 bucket to save it here."
                        : "No matching favorites")
                    .padding()
                    .allowsHitTesting(false)
                }
            }
        }
    }
}
