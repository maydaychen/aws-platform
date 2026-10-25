import Foundation

struct Route53Scope: Hashable, Sendable {
    let profile: AWSProfile
    let accountID: String
    let principalARN: String
    let configPath: String
    let credentialsPath: String

    var profileName: String { profile.name }

    init(profile: AWSProfile, identity: AWSIdentity, paths: AWSConfigurationPaths = AWSConfigurationPaths()) {
        self.profile = profile
        accountID = identity.account
        principalARN = identity.arn
        configPath = paths.config
        credentialsPath = paths.credentials
    }

    func partition() throws -> String {
        let parts = principalARN.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configPath.isEmpty, !credentialsPath.isEmpty,
              accountID.range(of: "^[0-9]{12}$", options: .regularExpression) != nil,
              parts.count == 6, parts[0] == "arn", ["sts", "iam"].contains(String(parts[2])),
              parts[4] == accountID, !parts[5].isEmpty else { throw Route53Error.invalidScope }
        guard ["aws", "aws-cn", "aws-us-gov"].contains(String(parts[1])) else {
            throw Route53Error.unsupportedPartition
        }
        return String(parts[1])
    }
}

struct Route53HostedZone: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isPrivate: Bool
    var recordCount: Int64? = nil
    var comment: String? = nil

    static func normalizedID(_ value: String) -> String? {
        let id = value.hasPrefix("/hostedzone/") ? String(value.dropFirst("/hostedzone/".count)) : value
        return id.range(of: "^[A-Z0-9]{1,32}$", options: .regularExpression) != nil ? id : nil
    }
}

struct Route53Field: Hashable, Sendable {
    let name: String
    let value: String
}

struct Route53VPC: Hashable, Sendable {
    let id: String
    let region: String
}

struct Route53ZoneDetails: Hashable, Sendable {
    let zone: Route53HostedZone
    let callerReference: String
    var nameServers: [String] = []
    var delegationSetID: String? = nil
    var vpcs: [Route53VPC] = []
    var linkedService: [Route53Field] = []
}

struct Route53Alias: Hashable, Sendable {
    let dnsName: String
    let hostedZoneID: String
    let evaluateTargetHealth: Bool
}

struct Route53Record: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let name: String
        let type: String
        let setIdentifier: String?
    }

    let name: String
    let type: String
    var setIdentifier: String? = nil
    var ttl: Int64? = nil
    var values: [String] = []
    var alias: Route53Alias? = nil
    var routingPolicy: String = "Simple"
    var routingFields: [Route53Field] = []

    var id: ID { ID(name: name, type: type, setIdentifier: setIdentifier) }
}

enum Route53Error: LocalizedError, Equatable {
    case invalidScope, unsupportedPartition, invalidResponse, incompletePagination

    var errorDescription: String? {
        switch self {
        case .invalidScope: return "Select and verify an AWS profile before loading Route 53."
        case .unsupportedPartition: return "Route 53 is not supported for this profile's partition in this app."
        case .invalidResponse: return "Route 53 returned incomplete or mismatched data. Refresh to try again."
        case .incompletePagination: return "Route 53 pagination could not be completed. Partial results were not displayed. Refresh to try again."
        }
    }
}
