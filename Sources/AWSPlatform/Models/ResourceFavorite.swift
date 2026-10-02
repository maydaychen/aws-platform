import Foundation

struct ResourceFavorite: Codable, Identifiable, Equatable {
    struct ID: Hashable {
        let profileName: String
        let accountID: String
        let region: String
        let service: AWSService
        let resourceID: String
    }

    let profileName: String
    let accountID: String
    /// The browsing region is retained for S3 as well; bucket location is
    /// resolved separately by the existing S3 loader.
    let region: String
    let service: AWSService
    let resourceID: String
    let displayName: String

    var id: ID {
        ID(profileName: profileName, accountID: accountID, region: region,
           service: service, resourceID: resourceID)
    }

    var isValid: Bool {
        [profileName, accountID, region, resourceID, displayName].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "-"
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [displayName, resourceID, profileName, accountID, region, service.rawValue]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
