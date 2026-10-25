import Foundation

struct RDSDatabaseEvent: Identifiable, Hashable, Sendable {
    let sourceARN: String?
    let sourceIdentifier: String
    let kind: RDSResourceKind
    let date: Date?
    let categories: [String]?
    let message: String?

    var id: Self { self }
}

struct RDSEventsSnapshot: Hashable, Sendable {
    let databaseARN: String
    let start: Date
    let end: Date
    let events: [RDSDatabaseEvent]
}

struct RDSDatabaseSnapshot: Identifiable, Hashable, Sendable {
    let arn: String
    let identifier: String
    let databaseIdentifier: String
    let kind: RDSResourceKind
    let type: String?
    let status: String?
    let createdAt: Date?
    let engine: String?
    let engineVersion: String?
    let allocatedStorageGB: Int?
    let encrypted: Bool?
    let kmsKeyID: String?
    let progress: Int?

    var id: String { arn }
}

enum RDSInsightsError: LocalizedError, Equatable {
    case invalidScope, invalidResponse, incompletePagination
    case eventsPermission, snapshotsPermission, credentials, network, throttled, failed

    var errorDescription: String? {
        switch self {
        case .invalidScope:
            return "Select an RDS database in a verified profile and region before loading details."
        case .invalidResponse:
            return "RDS returned inconsistent database details. Reload to try again."
        case .incompletePagination:
            return "The complete RDS details could not be retrieved. Reload to start a new request."
        case .eventsPermission:
            return "Database events could not be read. Check rds:DescribeEvents permission for the selected profile."
        case .snapshotsPermission:
            return "Database snapshots could not be read. Check rds:DescribeDBSnapshots or rds:DescribeDBClusterSnapshots permission."
        case .credentials:
            return "AWS credentials expired or are unavailable. Select the profile again, then reload database details."
        case .network:
            return "Unable to reach RDS. Check your network or proxy, then reload database details."
        case .throttled:
            return "RDS is limiting requests. Wait a moment, then reload database details manually."
        case .failed:
            return "Database details could not be loaded. Check the selected database and region, then reload."
        }
    }
}
