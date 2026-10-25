import Combine
import Foundation

@MainActor
final class RecentResourcesViewModel: ObservableObject {
    static let storageKey = "recentResources.v1"
    static let limitPerScope = 50

    @Published private(set) var entries: [RecentResource] = []
    @Published private(set) var storageError: String?

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
        guard let saved = defaults.object(forKey: Self.storageKey) else { return }
        guard let data = saved as? Data,
              let decoded = try? JSONDecoder().decode([RecentResource].self, from: data),
              decoded.allSatisfy(\.isValid) else {
            storageError = "Saved recent resources could not be read. The original data has been preserved; editing is disabled."
            return
        }
        entries = Self.normalized(decoded)
    }

    func entries(for scope: RecentResourceScope?, matching query: String = "") -> [RecentResource] {
        guard let scope, scope.isValid else { return [] }
        return entries.filter { scope.contains($0.resource) && $0.resource.matches(query) }
    }

    func recordVisit(_ resource: ResourceFavorite, scope: RecentResourceScope?) {
        guard let scope, scope.contains(resource), storageError == nil else { return }
        let entry = RecentResource(resource: resource, lastVisitedAt: now())
        guard entry.isValid else { return }
        save(Self.normalized([entry] + entries.filter { $0.id != entry.id }))
    }

    func remove(_ entry: RecentResource, scope: RecentResourceScope?) {
        guard let scope, scope.contains(entry.resource), entry.isValid, storageError == nil else { return }
        save(entries.filter { $0.id != entry.id })
    }

    func clear(scope: RecentResourceScope?) {
        guard let scope, scope.isValid, storageError == nil else { return }
        save(entries.filter { !scope.contains($0.resource) })
    }

    private static func normalized(_ entries: [RecentResource]) -> [RecentResource] {
        let sorted = entries.enumerated().sorted {
            if $0.element.lastVisitedAt == $1.element.lastVisitedAt { return $0.offset < $1.offset }
            return $0.element.lastVisitedAt > $1.element.lastVisitedAt
        }
        var seen: Set<ResourceFavorite.ID> = []
        var scopeCounts: [RecentResourceScope: Int] = [:]
        return sorted.compactMap { _, entry in
            let scope = RecentResourceScope(profileName: entry.resource.profileName, accountID: entry.resource.accountID)
            guard seen.insert(entry.id).inserted, scopeCounts[scope, default: 0] < limitPerScope else { return nil }
            scopeCounts[scope, default: 0] += 1
            return entry
        }
    }

    private func save(_ updated: [RecentResource]) {
        guard updated != entries else { return }
        guard let data = try? JSONEncoder().encode(updated) else {
            storageError = "Recent resources could not be saved. Existing history has been preserved."
            return
        }
        defaults.set(data, forKey: Self.storageKey)
        entries = updated
    }
}
