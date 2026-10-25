import Foundation

enum SNSTopicKind: String, CaseIterable, Identifiable, Sendable {
    case standard, fifo

    var id: Self { self }
    var title: String { self == .fifo ? "FIFO" : "Standard" }
}

struct SNSScope: Hashable, Sendable {
    let profile: AWSProfile
    let accountID: String
    let principalARN: String
    let region: String
    let configPath: String
    let credentialsPath: String

    var profileName: String { profile.name }

    init(
        profile: AWSProfile, identity: AWSIdentity, region: String,
        paths: AWSConfigurationPaths = AWSConfigurationPaths()
    ) {
        self.profile = profile
        accountID = identity.account
        principalARN = identity.arn
        self.region = region
        configPath = paths.config
        credentialsPath = paths.credentials
    }
}

struct SNSTopic: Hashable, Identifiable, Sendable {
    let arn: String
    let name: String

    var id: String { arn }
    var kind: SNSTopicKind { name.hasSuffix(".fifo") ? .fifo : .standard }
}

struct SNSSubscription: Hashable, Identifiable, Sendable {
    let id: String
    let arn: String?
    let protocolName: String?
    let endpoint: String?
    let owner: String?
    let topicARN: String
    let status: String

    init(
        id: String, arn: String? = nil, protocolName: String? = nil, endpoint: String? = nil,
        owner: String? = nil, topicARN: String, status: String
    ) {
        self.id = id
        self.arn = arn
        self.protocolName = protocolName
        self.endpoint = endpoint
        self.owner = owner
        self.topicARN = topicARN
        self.status = status
    }
}

enum SNSError: LocalizedError {
    case invalidScope, invalidResponse, incompletePagination

    var errorDescription: String? {
        switch self {
        case .invalidScope:
            return "Verify the selected profile and region before loading SNS topics."
        case .invalidResponse:
            return "AWS returned incomplete or inconsistent SNS data. Refresh to try again."
        case .incompletePagination:
            return "The complete SNS result could not be retrieved. Refresh to start a new request."
        }
    }
}
