import Foundation

struct RecentResourceScope: Hashable {
    let profileName: String
    let accountID: String

    var isValid: Bool {
        !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && accountID.utf8.count == 12
            && accountID.utf8.allSatisfy { (48...57).contains($0) }
    }

    func contains(_ resource: ResourceFavorite) -> Bool {
        isValid && resource.profileName == profileName && resource.accountID == accountID
    }
}

struct RecentResource: Codable, Identifiable, Equatable {
    let resource: ResourceFavorite
    let lastVisitedAt: Date

    var id: ResourceFavorite.ID { resource.id }

    var isValid: Bool {
        resource.isValid
            && RecentResourceScope(profileName: resource.profileName, accountID: resource.accountID).isValid
            && lastVisitedAt.timeIntervalSinceReferenceDate.isFinite
    }
}
