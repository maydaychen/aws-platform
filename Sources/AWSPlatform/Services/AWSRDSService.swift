import Foundation
import SotoCore
import SotoRDS

struct AWSRDSService: Sendable {
    typealias InstanceLoader = @Sendable (RDS.DescribeDBInstancesMessage) async throws -> RDS.DBInstanceMessage
    typealias ClusterLoader = @Sendable (RDS.DescribeDBClustersMessage) async throws -> RDS.DBClusterMessage

    private struct Operations: Sendable {
        let instances: InstanceLoader
        let clusters: ClusterLoader
    }

    private let provider: AWSServiceProvider?
    private let injected: Operations?

    init(provider: AWSServiceProvider) {
        self.provider = provider
        injected = nil
    }

    init(instanceLoader: @escaping InstanceLoader, clusterLoader: @escaping ClusterLoader) {
        provider = nil
        injected = Operations(instances: instanceLoader, clusters: clusterLoader)
    }

    func loadInstances(scope: MonitoringScope) async throws -> [RDSDatabase] {
        do {
            let operations = try await operations(scope: scope)
            let values = try await Self.pages { marker in
                let response = try await operations.instances(.init(marker: marker, maxRecords: 100))
                try Task.checkCancellation()
                let databases = try (response.dbInstances ?? []).compactMap { raw -> RDSDatabase? in
                    guard Self.isRDSEngine(raw.engine) else { return nil }
                    return try Self.instance(raw, scope: scope)
                }
                return (databases, response.marker)
            }
            return try Self.uniqueSorted(values)
        } catch { throw Self.sanitized(error, operation: .instances) }
    }

    func loadClusters(scope: MonitoringScope) async throws -> [RDSDatabase] {
        do {
            let operations = try await operations(scope: scope)
            let values = try await Self.pages { marker in
                let response = try await operations.clusters(.init(includeShared: false, marker: marker, maxRecords: 100))
                try Task.checkCancellation()
                let databases = try (response.dbClusters ?? []).compactMap { raw -> RDSDatabase? in
                    guard Self.isRDSEngine(raw.engine) else { return nil }
                    return try Self.cluster(raw, scope: scope)
                }
                return (databases, response.marker)
            }
            return try Self.uniqueSorted(values)
        } catch { throw Self.sanitized(error, operation: .clusters) }
    }

    private func operations(scope: MonitoringScope) async throws -> Operations {
        try Task.checkCancellation()
        guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty else {
            throw RDSError.invalidScope
        }
        if let injected { return injected }
        guard let provider else { throw RDSError.invalidScope }
        let client = try await provider.rdsClient(scope: scope)
        try Task.checkCancellation()
        return Operations(instances: { try await client.describeDBInstances($0) },
                          clusters: { try await client.describeDBClusters($0) })
    }

    private static func pages(
        _ loader: @Sendable (String?) async throws -> ([RDSDatabase], String?)
    ) async throws -> [RDSDatabase] {
        var databases: [RDSDatabase] = []
        var marker: String?
        var seenMarkers: Set<String> = []
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            let (page, next) = try await loader(marker)
            try Task.checkCancellation()
            databases.append(contentsOf: page)
            guard let next, !next.isEmpty else { return databases }
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenMarkers.insert(next).inserted else { throw RDSError.incompletePagination }
            marker = next
        }
        throw RDSError.incompletePagination
    }

    private static func uniqueSorted(_ values: [RDSDatabase]) throws -> [RDSDatabase] {
        guard Set(values.map(\.arn)).count == values.count,
              Set(values.map(\.identifier)).count == values.count else { throw RDSError.invalidResponse }
        return values.sorted { $0.identifier < $1.identifier }
    }

    private static func identity(arn: String?, identifier: String?, kind: RDSResourceKind,
                                 scope: MonitoringScope) throws -> (String, String) {
        guard let arn, let identifier, !identifier.isEmpty,
              identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.contains(":"),
              !identifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RDSError.invalidResponse
        }
        let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
        let resourceType = kind == .instance ? "db" : "cluster"
        guard arn == "arn:\(partition):rds:\(scope.region):\(scope.accountID):\(resourceType):\(identifier)" else {
            throw RDSError.invalidResponse
        }
        return (arn, identifier)
    }

    private static func instance(_ raw: RDS.DBInstance, scope: MonitoringScope) throws -> RDSDatabase {
        let (arn, identifier) = try identity(arn: raw.dbInstanceArn, identifier: raw.dbInstanceIdentifier,
                                             kind: .instance, scope: scope)
        return RDSDatabase(
            arn: arn, identifier: identifier, kind: .instance,
            engine: raw.engine, engineVersion: raw.engineVersion, status: raw.dbInstanceStatus,
            instanceClass: raw.dbInstanceClass, clusterIdentifier: raw.dbClusterIdentifier,
            endpoint: raw.endpoint?.address, availabilityZone: raw.availabilityZone,
            secondaryAvailabilityZone: raw.secondaryAvailabilityZone, storageType: raw.storageType,
            kmsKeyID: raw.kmsKeyId, vpcID: raw.dbSubnetGroup?.vpcId, subnetGroup: raw.dbSubnetGroup?.dbSubnetGroupName,
            port: raw.endpoint?.port, allocatedStorageGB: raw.allocatedStorage,
            backupRetentionDays: raw.backupRetentionPeriod, multiAZ: raw.multiAZ,
            publiclyAccessible: raw.publiclyAccessible, encrypted: raw.storageEncrypted,
            deletionProtection: raw.deletionProtection,
            subnetIDs: (raw.dbSubnetGroup?.subnets ?? []).compactMap(\.subnetIdentifier),
            securityGroupIDs: (raw.vpcSecurityGroups ?? []).compactMap(\.vpcSecurityGroupId),
            tags: try tags(raw.tagList), createdAt: raw.instanceCreateTime
        )
    }

    private static func cluster(_ raw: RDS.DBCluster, scope: MonitoringScope) throws -> RDSDatabase {
        let (arn, identifier) = try identity(arn: raw.dbClusterArn, identifier: raw.dbClusterIdentifier,
                                             kind: .cluster, scope: scope)
        let members = try (raw.dbClusterMembers ?? []).map { raw -> RDSClusterMember in
            guard let identifier = raw.dbInstanceIdentifier,
                  !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RDSError.invalidResponse }
            return RDSClusterMember(identifier: identifier, isWriter: raw.isClusterWriter, promotionTier: raw.promotionTier)
        }
        guard Set(members.map(\.id)).count == members.count else { throw RDSError.invalidResponse }
        return RDSDatabase(
            arn: arn, identifier: identifier, kind: .cluster,
            engine: raw.engine, engineVersion: raw.engineVersion, status: raw.status,
            instanceClass: raw.dbClusterInstanceClass, endpoint: raw.endpoint, readerEndpoint: raw.readerEndpoint,
            storageType: raw.storageType, kmsKeyID: raw.kmsKeyId, subnetGroup: raw.dbSubnetGroup,
            engineMode: raw.engineMode, port: raw.port, allocatedStorageGB: raw.allocatedStorage,
            backupRetentionDays: raw.backupRetentionPeriod, multiAZ: raw.multiAZ,
            publiclyAccessible: raw.publiclyAccessible, encrypted: raw.storageEncrypted,
            deletionProtection: raw.deletionProtection, availabilityZones: raw.availabilityZones ?? [],
            securityGroupIDs: (raw.vpcSecurityGroups ?? []).compactMap(\.vpcSecurityGroupId),
            members: members, tags: try tags(raw.tagList), createdAt: raw.clusterCreateTime,
            serverlessV2MinACU: raw.serverlessV2ScalingConfiguration?.minCapacity,
            serverlessV2MaxACU: raw.serverlessV2ScalingConfiguration?.maxCapacity
        )
    }

    private static func tags(_ raw: [RDS.Tag]?) throws -> [String: String]? {
        guard let raw else { return nil }
        var values: [String: String] = [:]
        for tag in raw {
            guard let key = tag.key, !key.isEmpty, values[key] == nil else { throw RDSError.invalidResponse }
            values[key] = tag.value ?? ""
        }
        return values
    }

    private static func isRDSEngine(_ engine: String?) -> Bool {
        !["docdb", "neptune"].contains(engine?.lowercased() ?? "")
    }

    private enum Operation { case instances, clusters }

    private static func sanitized(_ error: Error, operation: Operation) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? RDSError { return error }
        if let error = error as? RequestError { return error }
        if error is AWSServiceError { return RDSError.invalidScope }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedException", "UnauthorizedOperation", "ForbiddenException"].contains(code) {
            return operation == .instances ? RequestError.instancesPermission : RequestError.clustersPermission
        }
        if UserFacingError.requiresSSOLogin(error) { return RequestError.credentials }
        if error is URLError { return RequestError.network }
        switch code {
        case "Throttling", "ThrottlingException", "TooManyRequestsException": return RequestError.throttled
        case "KMSKeyNotAccessibleFault", "KMSKeyNotAccessible", "KMSKeyNotAccessibleException": return RequestError.encryption
        case "InvalidMarker", "InvalidMarkerException", "InvalidPaginationToken": return RDSError.incompletePagination
        default: return RequestError.failed
        }
    }

    enum RequestError: LocalizedError, Equatable {
        case instancesPermission, clustersPermission, credentials, network, throttled, encryption, failed

        var errorDescription: String? {
            switch self {
            case .instancesPermission: return "DB instances could not be read. Check rds:DescribeDBInstances permission for the selected profile."
            case .clustersPermission: return "DB clusters could not be read. Check rds:DescribeDBClusters permission for the selected profile."
            case .credentials: return "AWS credentials expired or are unavailable. Sign in to the session, select the profile again, then reload RDS."
            case .network: return "Unable to reach RDS. Check your network or proxy, then refresh."
            case .throttled: return "RDS is limiting requests. Wait a moment, then refresh manually."
            case .encryption: return "RDS could not access a KMS key. Check its status and permissions."
            case .failed: return "The RDS request failed. Check the selected profile, region and service availability, then refresh."
            }
        }
    }
}
