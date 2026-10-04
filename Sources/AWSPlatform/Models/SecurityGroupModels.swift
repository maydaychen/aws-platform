import Foundation

struct SecurityGroupRule: Hashable, Sendable {
    let protocolName: String
    let portRange: String
    let target: String
    var description: String? = nil
    var referencedGroupID: String? = nil
    var referencedAccountID: String? = nil
    var fields: [ELBField] = []
}

struct SecurityGroupModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var ownerID: String? = nil
    var vpcID: String? = nil
    var description: String? = nil
    var inboundRules: [SecurityGroupRule] = []
    var outboundRules: [SecurityGroupRule] = []
    var tags: [ELBField] = []

    static func validID(_ value: String) -> Bool {
        value.range(of: "^sg-(?:[0-9a-f]{8}|[0-9a-f]{17})\\z", options: .regularExpression) != nil
    }
}

struct RelationInstance: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var securityGroupIDs: [String] = []
    var vpcID: String? = nil
}

enum SecurityGroupError: LocalizedError, Equatable {
    case invalidScope, invalidResponse, incompletePagination, permission, credentials, network, throttled, failed
    var errorDescription: String? {
        switch self {
        case .invalidScope: return "Select and verify a profile and region before querying security groups."
        case .invalidResponse: return "EC2 returned incomplete or mismatched resource data. Refresh to try again."
        case .incompletePagination: return "EC2 pagination could not be completed. Partial results were not displayed."
        case .permission: return "EC2 access was denied. Check DescribeSecurityGroups and DescribeInstances permissions for this query."
        case .credentials: return "AWS credentials are unavailable or expired. Sign in and select the profile again."
        case .network: return "Unable to reach EC2. Check your connection and retry."
        case .throttled: return "EC2 is limiting requests. Wait a moment, then retry manually."
        case .failed: return "The EC2 resource query failed. Check the profile, region and service access."
        }
    }
}
