import Foundation

struct HealthScope: Hashable, Sendable {
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

    func endpoint() throws -> HealthEndpoint {
        let parts = principalARN.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard !profileName.isEmpty, !configPath.isEmpty, !credentialsPath.isEmpty,
              accountID.range(of: "^[0-9]{12}$", options: .regularExpression) != nil,
              parts.count == 6, parts[0] == "arn", ["sts", "iam"].contains(String(parts[2])),
              parts[4] == accountID, !parts[5].isEmpty else { throw HealthError.invalidScope }
        switch parts[1] {
        case "aws":
            return HealthEndpoint(partition: "aws", region: "us-east-1", url: "https://health.us-east-1.amazonaws.com")
        case "aws-cn":
            return HealthEndpoint(partition: "aws-cn", region: "cn-northwest-1", url: "https://health.cn-northwest-1.amazonaws.com.cn")
        case "aws-us-gov":
            return HealthEndpoint(partition: "aws-us-gov", region: "us-gov-west-1", url: "https://health.us-gov-west-1.amazonaws.com")
        default: throw HealthError.unsupportedPartition
        }
    }
}

struct HealthEndpoint: Equatable, Sendable {
    let partition: String
    let region: String
    let url: String
}

struct HealthEvent: Identifiable, Hashable, Sendable {
    let arn: String
    let service: String
    let typeCode: String
    let category: String
    let status: String
    let region: String
    var availabilityZone: String? = nil
    var startTime: Date? = nil
    var endTime: Date? = nil
    var lastUpdatedTime: Date? = nil

    var id: String { arn }
}

struct HealthEventDetails: Hashable, Sendable {
    let event: HealthEvent
    let description: String?
    var metadata: [String: String] = [:]
}

struct HealthAffectedEntity: Identifiable, Hashable, Sendable {
    let id: String
    let value: String
    let status: String
    var accountID: String? = nil
    var lastUpdatedTime: Date? = nil
}

enum HealthError: LocalizedError, Equatable {
    case invalidScope, unsupportedPartition, invalidResponse, incompletePagination

    var errorDescription: String? {
        switch self {
        case .invalidScope:
            return "Select and verify an AWS profile before loading Health events."
        case .unsupportedPartition:
            return "AWS Health is not supported for this profile's partition in this app."
        case .invalidResponse:
            return "AWS Health returned incomplete or mismatched data. Refresh to try again."
        case .incompletePagination:
            return "AWS Health pagination could not be completed. Partial results were not displayed. Refresh to try again."
        }
    }
}
