import Foundation

enum RDSResourceKind: String, CaseIterable, Identifiable, Sendable {
    case instance, cluster

    var id: Self { self }
    var title: String { self == .instance ? "DB instances" : "DB clusters" }
    var singularTitle: String { self == .instance ? "DB instance" : "DB cluster" }
}

struct RDSClusterMember: Identifiable, Hashable, Sendable {
    let identifier: String
    let isWriter: Bool?
    let promotionTier: Int?

    var id: String { identifier }

    init(identifier: String, isWriter: Bool? = nil, promotionTier: Int? = nil) {
        self.identifier = identifier
        self.isWriter = isWriter
        self.promotionTier = promotionTier
    }
}

struct RDSDatabase: Identifiable, Hashable, Sendable {
    let arn: String
    let identifier: String
    let kind: RDSResourceKind
    let engine: String?
    let engineVersion: String?
    let status: String?
    let instanceClass: String?
    let clusterIdentifier: String?
    let endpoint: String?
    let readerEndpoint: String?
    let availabilityZone: String?
    let secondaryAvailabilityZone: String?
    let storageType: String?
    let kmsKeyID: String?
    let vpcID: String?
    let subnetGroup: String?
    let engineMode: String?
    let port: Int?
    let allocatedStorageGB: Int?
    let backupRetentionDays: Int?
    let multiAZ: Bool?
    let publiclyAccessible: Bool?
    let encrypted: Bool?
    let deletionProtection: Bool?
    let availabilityZones: [String]
    let subnetIDs: [String]
    let securityGroupIDs: [String]
    let members: [RDSClusterMember]
    let tags: [String: String]?
    let createdAt: Date?
    let serverlessV2MinACU: Double?
    let serverlessV2MaxACU: Double?

    var id: String { arn }

    init(arn: String, identifier: String, kind: RDSResourceKind,
         engine: String? = nil, engineVersion: String? = nil, status: String? = nil,
         instanceClass: String? = nil, clusterIdentifier: String? = nil, endpoint: String? = nil,
         readerEndpoint: String? = nil, availabilityZone: String? = nil, secondaryAvailabilityZone: String? = nil,
         storageType: String? = nil, kmsKeyID: String? = nil, vpcID: String? = nil,
         subnetGroup: String? = nil, engineMode: String? = nil, port: Int? = nil,
         allocatedStorageGB: Int? = nil, backupRetentionDays: Int? = nil, multiAZ: Bool? = nil,
         publiclyAccessible: Bool? = nil, encrypted: Bool? = nil, deletionProtection: Bool? = nil,
         availabilityZones: [String] = [], subnetIDs: [String] = [], securityGroupIDs: [String] = [],
         members: [RDSClusterMember] = [], tags: [String: String]? = nil, createdAt: Date? = nil,
         serverlessV2MinACU: Double? = nil, serverlessV2MaxACU: Double? = nil) {
        self.arn = arn
        self.identifier = identifier
        self.kind = kind
        self.engine = engine
        self.engineVersion = engineVersion
        self.status = status
        self.instanceClass = instanceClass
        self.clusterIdentifier = clusterIdentifier
        self.endpoint = endpoint
        self.readerEndpoint = readerEndpoint
        self.availabilityZone = availabilityZone
        self.secondaryAvailabilityZone = secondaryAvailabilityZone
        self.storageType = storageType
        self.kmsKeyID = kmsKeyID
        self.vpcID = vpcID
        self.subnetGroup = subnetGroup
        self.engineMode = engineMode
        self.port = port
        self.allocatedStorageGB = allocatedStorageGB
        self.backupRetentionDays = backupRetentionDays
        self.multiAZ = multiAZ
        self.publiclyAccessible = publiclyAccessible
        self.encrypted = encrypted
        self.deletionProtection = deletionProtection
        self.availabilityZones = availabilityZones
        self.subnetIDs = subnetIDs
        self.securityGroupIDs = securityGroupIDs
        self.members = members
        self.tags = tags
        self.createdAt = createdAt
        self.serverlessV2MinACU = serverlessV2MinACU
        self.serverlessV2MaxACU = serverlessV2MaxACU
    }
}

enum RDSError: LocalizedError, Equatable {
    case invalidScope, invalidResponse, incompletePagination

    var errorDescription: String? {
        switch self {
        case .invalidScope: return "Select and verify an AWS profile before loading RDS."
        case .invalidResponse: return "RDS returned incomplete or mismatched data. Refresh to try again."
        case .incompletePagination: return "RDS pagination could not be completed. Partial results were not displayed. Refresh to try again."
        }
    }
}
