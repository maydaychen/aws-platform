import Foundation
import SotoCore
import SotoEC2

struct AWSEBSService: Sendable {
    typealias VolumeLoader = @Sendable (EC2.DescribeVolumesRequest) async throws -> EC2.DescribeVolumesResult
    typealias SnapshotLoader = @Sendable (EC2.DescribeSnapshotsRequest) async throws -> EC2.DescribeSnapshotsResult

    private let provider: AWSServiceProvider?
    private let volumes: VolumeLoader?
    private let snapshots: SnapshotLoader?

    init(provider: AWSServiceProvider) { self.provider = provider; volumes = nil; snapshots = nil }
    init(volumes: @escaping VolumeLoader, snapshots: @escaping SnapshotLoader) {
        provider = nil; self.volumes = volumes; self.snapshots = snapshots
    }

    func load(kind: EBSResource.Kind, scope: MonitoringScope) async throws -> [EBSResource] {
        do {
            try Task.checkCancellation()
            guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty else { throw EBSError.invalidScope }
            let volumeLoader: VolumeLoader
            let snapshotLoader: SnapshotLoader
            if let volumes, let snapshots {
                volumeLoader = volumes; snapshotLoader = snapshots
            } else {
                guard let provider else { throw EBSError.invalidScope }
                let client = try await provider.ec2Client(scope: scope)
                volumeLoader = { try await client.describeVolumes($0) }
                snapshotLoader = { try await client.describeSnapshots($0) }
            }
            let rows = try await Self.pages { token in
                switch kind {
                case .volume:
                    let response = try await volumeLoader(.init(maxResults: 200, nextToken: token))
                    return (try (response.volumes ?? []).map { try Self.volume($0, scope: scope) }, response.nextToken)
                case .snapshot:
                    let response = try await snapshotLoader(.init(maxResults: 200, nextToken: token, ownerIds: ["self"]))
                    return (try (response.snapshots ?? []).map { try Self.snapshot($0, scope: scope) }, response.nextToken)
                }
            }
            return rows.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        } catch { throw Self.sanitized(error, kind: kind) }
    }

    private static func pages(_ loader: @Sendable (String?) async throws -> ([EBSResource], String?)) async throws -> [EBSResource] {
        var rows: [EBSResource] = []
        var ids = Set<String>()
        var tokens = Set<String>()
        var token: String?
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            let (page, next) = try await loader(token)
            try Task.checkCancellation()
            for row in page {
                guard ids.insert(row.id).inserted else { throw EBSError.invalidResponse }
                rows.append(row)
            }
            guard let next, !next.isEmpty else { return rows }
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, tokens.insert(next).inserted else { throw EBSError.pagination }
            token = next
        }
        throw EBSError.pagination
    }

    private static func volume(_ raw: EC2.Volume, scope: MonitoringScope) throws -> EBSResource {
        guard let id = raw.volumeId, EBSResource.Kind.volume.validID(id),
              raw.size.map({ $0 >= 0 }) ?? true,
              raw.availabilityZone.map({ zone in
                  zone.hasPrefix(scope.region + "-") || (zone.hasPrefix(scope.region) && String(zone.dropFirst(scope.region.count)).range(of: "^[a-z]\\z", options: .regularExpression) != nil)
              }) ?? true else { throw EBSError.invalidResponse }
        let tags = try tags(raw.tags)
        let attachments = try (raw.attachments ?? []).map { attachment in
            if let volumeID = attachment.volumeId, volumeID != id { throw EBSError.invalidResponse }
            return EBSResource.Attachment(instanceID: attachment.instanceId, device: attachment.device,
                                          state: attachment.state?.rawValue, deleteOnTermination: attachment.deleteOnTermination)
        }
        return EBSResource(id: id, name: nonempty(tags["Name"]) ?? id, kind: .volume,
                           state: raw.state?.rawValue ?? "Unknown", sizeGiB: raw.size, encrypted: raw.encrypted,
                           createdAt: raw.createTime, ownerID: scope.accountID, volumeType: raw.volumeType?.rawValue,
                           availabilityZone: raw.availabilityZone, iops: raw.iops, throughput: raw.throughput,
                           kmsKeyID: raw.kmsKeyId, snapshotID: nonempty(raw.snapshotId), attachments: attachments, tags: tags)
    }

    private static func snapshot(_ raw: EC2.Snapshot, scope: MonitoringScope) throws -> EBSResource {
        guard let id = raw.snapshotId, EBSResource.Kind.snapshot.validID(id), raw.ownerId == scope.accountID,
              raw.volumeSize.map({ $0 >= 0 }) ?? true else { throw EBSError.invalidResponse }
        let tags = try tags(raw.tags)
        return EBSResource(id: id, name: nonempty(tags["Name"]) ?? id, kind: .snapshot,
                           state: raw.state?.rawValue ?? "Unknown", sizeGiB: raw.volumeSize, encrypted: raw.encrypted,
                           createdAt: raw.startTime, ownerID: scope.accountID, kmsKeyID: raw.kmsKeyId,
                           volumeID: nonempty(raw.volumeId), description: raw.description, progress: raw.progress,
                           storageTier: raw.storageTier?.rawValue, tags: tags)
    }

    private static func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }

    private static func tags(_ raw: [EC2.Tag]?) throws -> [String: String] {
        var result: [String: String] = [:]
        for tag in raw ?? [] {
            guard let key = tag.key, !key.isEmpty, let value = tag.value, result[key] == nil else { throw EBSError.invalidResponse }
            result[key] = value
        }
        return result
    }

    private static func sanitized(_ error: Error, kind: EBSResource.Kind) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? EBSError { return error }
        if error is AWSServiceError { return EBSError.invalidScope }
        let code = (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedOperation", "UnauthorizedException", "ForbiddenException"].contains(code) {
            return kind == .volume ? EBSError.volumesPermission : EBSError.snapshotsPermission
        }
        if UserFacingError.requiresSSOLogin(error) { return EBSError.credentials }
        if error is URLError { return EBSError.network }
        if ["Throttling", "ThrottlingException", "RequestLimitExceeded"].contains(code) { return EBSError.throttled }
        if ["InvalidNextToken", "InvalidPaginationToken"].contains(code) { return EBSError.pagination }
        return EBSError.failed
    }
}
