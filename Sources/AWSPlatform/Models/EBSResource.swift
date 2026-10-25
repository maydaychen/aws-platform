import Foundation

struct EBSResource: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case volume, snapshot

        var title: String { self == .volume ? "EBS Volumes" : "EBS Snapshots" }
        var service: AWSService { self == .volume ? .ebsVolumes : .ebsSnapshots }
        var emptySelection: String { self == .volume ? "Select an EBS volume" : "Select an EBS snapshot" }
        func validID(_ id: String) -> Bool {
            let prefix = self == .volume ? "vol" : "snap"
            return id.range(of: "^\(prefix)-(?:[0-9a-f]{8}|[0-9a-f]{17})\\z", options: .regularExpression) != nil
        }
    }

    struct Attachment: Hashable, Sendable {
        let instanceID: String?
        let device: String?
        let state: String?
        let deleteOnTermination: Bool?
    }

    let id: String
    let name: String
    let kind: Kind
    let state: String
    let sizeGiB: Int?
    let encrypted: Bool?
    let createdAt: Date?
    let ownerID: String
    var volumeType: String? = nil
    var availabilityZone: String? = nil
    var iops: Int? = nil
    var throughput: Int? = nil
    var kmsKeyID: String? = nil
    var snapshotID: String? = nil
    var volumeID: String? = nil
    var description: String? = nil
    var progress: String? = nil
    var storageTier: String? = nil
    var attachments: [Attachment] = []
    var tags: [String: String] = [:]

    func matches(_ query: String) -> Bool {
        let values = [id, name, state, ownerID] + [volumeType, availabilityZone, snapshotID, volumeID, description, kmsKeyID].compactMap { $0 }
            + tags.flatMap { [$0.key, $0.value] }
            + attachments.flatMap { [$0.instanceID, $0.device].compactMap { $0 } }
        return query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

enum EBSError: String, LocalizedError, Sendable {
    case invalidScope = "Select and verify a profile and region before loading EBS resources."
    case invalidResponse = "EBS returned an invalid resource response. Refresh to retry."
    case pagination = "The EBS list could not be loaded completely. Refresh to retry."
    case volumesPermission = "EBS volume access was denied. Check ec2:DescribeVolumes permission."
    case snapshotsPermission = "EBS snapshot access was denied. Check ec2:DescribeSnapshots permission."
    case credentials = "EBS credentials are unavailable or expired. Verify the selected profile again."
    case network = "Unable to connect to EBS. Check your network and retry."
    case throttled = "EBS request limit reached. Wait a moment and refresh."
    case failed = "Unable to load EBS resources. Refresh to try again."
    case cancelled = "EBS loading cancelled. Refresh to try again."

    var errorDescription: String? { rawValue }
}
