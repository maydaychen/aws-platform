import Combine
import Foundation

@MainActor
final class FavoritesViewModel: ObservableObject {
    @Published private(set) var favorites: [ResourceFavorite] = []
    @Published private(set) var storageError: String?

    static let storageKey = "resourceFavorites.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let saved = defaults.object(forKey: Self.storageKey) else { return }
        guard let data = saved as? Data,
              let decoded = try? JSONDecoder().decode([ResourceFavorite].self, from: data),
              decoded.allSatisfy(\.isValid) else {
            storageError = "Saved favorites could not be read. The original data has been preserved; editing is disabled."
            return
        }
        var seen: Set<ResourceFavorite.ID> = []
        favorites = decoded.filter { seen.insert($0.id).inserted }
    }

    func contains(_ favorite: ResourceFavorite) -> Bool {
        favorites.contains { $0.id == favorite.id }
    }

    func toggle(_ favorite: ResourceFavorite) {
        guard favorite.isValid, storageError == nil else { return }
        var updated = favorites.filter { $0.id != favorite.id }
        if !contains(favorite) { updated.insert(favorite, at: 0) }
        save(updated)
    }

    func remove(_ favorite: ResourceFavorite) {
        guard storageError == nil else { return }
        save(favorites.filter { $0.id != favorite.id })
    }

    private func save(_ updated: [ResourceFavorite]) {
        guard let data = try? JSONEncoder().encode(updated) else {
            storageError = "Favorites could not be saved. Existing favorites have been preserved."
            return
        }
        defaults.set(data, forKey: Self.storageKey)
        favorites = updated
    }
}
