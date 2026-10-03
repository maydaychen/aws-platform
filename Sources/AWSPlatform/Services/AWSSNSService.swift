import Foundation
import SotoCore
import SotoSNS

struct AWSSNSService: Sendable {
    typealias TopicLoader = @Sendable (SNS.ListTopicsInput) async throws -> SNS.ListTopicsResponse
    typealias AttributeLoader = @Sendable (SNS.GetTopicAttributesInput) async throws -> SNS.GetTopicAttributesResponse
    typealias TagLoader = @Sendable (SNS.ListTagsForResourceRequest) async throws -> SNS.ListTagsForResourceResponse
    typealias SubscriptionLoader = @Sendable (SNS.ListSubscriptionsByTopicInput) async throws -> SNS.ListSubscriptionsByTopicResponse

    private struct Operations: Sendable {
        let topics: TopicLoader
        let attributes: AttributeLoader
        let tags: TagLoader
        let subscriptions: SubscriptionLoader
    }

    private let provider: AWSServiceProvider?
    private let injected: Operations?
    private static let maximumPages = 100

    init(provider: AWSServiceProvider) {
        self.provider = provider
        injected = nil
    }

    init(
        topicLoader: @escaping TopicLoader, attributeLoader: @escaping AttributeLoader,
        tagLoader: @escaping TagLoader, subscriptionLoader: @escaping SubscriptionLoader
    ) {
        provider = nil
        injected = Operations(topics: topicLoader, attributes: attributeLoader, tags: tagLoader, subscriptions: subscriptionLoader)
    }

    func loadTopics(scope: SNSScope) async throws -> [SNSTopic] {
        do {
            let partition = try Self.validateScope(scope)
            let operations = try await operations(scope: scope)
            var result: [SNSTopic] = []
            var seenARNs: Set<String> = []
            var token: String?
            var seenTokens: Set<String> = []
            for _ in 0..<Self.maximumPages {
                try Task.checkCancellation()
                let response = try await operations.topics(.init(nextToken: token))
                try Task.checkCancellation()
                for item in response.topics ?? [] {
                    guard let arn = item.topicArn, seenARNs.insert(arn).inserted else { throw SNSError.invalidResponse }
                    result.append(try Self.topic(arn: arn, scope: scope, partition: partition))
                }
                guard let next = response.nextToken, !next.isEmpty else {
                    try Task.checkCancellation()
                    return result.sorted { $0.name < $1.name }
                }
                guard seenTokens.insert(next).inserted else { throw SNSError.incompletePagination }
                token = next
            }
            throw SNSError.incompletePagination
        } catch {
            throw Self.sanitized(error, operation: .list)
        }
    }

    func loadAttributes(scope: SNSScope, topic: SNSTopic) async throws -> [String: String] {
        do {
            try Self.validateTopic(topic, scope: scope)
            let operations = try await operations(scope: scope)
            try Task.checkCancellation()
            let response = try await operations.attributes(.init(topicArn: topic.arn))
            try Task.checkCancellation()
            let attributes = response.attributes ?? [:]
            guard attributes["TopicArn"] == nil || attributes["TopicArn"] == topic.arn,
                  attributes["Owner"] == nil || attributes["Owner"] == scope.accountID else {
                throw SNSError.invalidResponse
            }
            return attributes
        } catch {
            throw Self.sanitized(error, operation: .attributes)
        }
    }

    func loadTags(scope: SNSScope, topic: SNSTopic) async throws -> [String: String] {
        do {
            try Self.validateTopic(topic, scope: scope)
            let operations = try await operations(scope: scope)
            try Task.checkCancellation()
            let response = try await operations.tags(.init(resourceArn: topic.arn))
            try Task.checkCancellation()
            var tags: [String: String] = [:]
            for tag in response.tags ?? [] {
                guard !tag.key.isEmpty, tags[tag.key] == nil else { throw SNSError.invalidResponse }
                tags[tag.key] = tag.value
            }
            try Task.checkCancellation()
            return tags
        } catch {
            throw Self.sanitized(error, operation: .tags)
        }
    }

    func loadSubscriptions(scope: SNSScope, topic: SNSTopic) async throws -> [SNSSubscription] {
        do {
            try Self.validateTopic(topic, scope: scope)
            let operations = try await operations(scope: scope)
            var result: [SNSSubscription] = []
            var seenARNs: Set<String> = []
            var token: String?
            var seenTokens: Set<String> = []
            for _ in 0..<Self.maximumPages {
                try Task.checkCancellation()
                let response = try await operations.subscriptions(.init(nextToken: token, topicArn: topic.arn))
                try Task.checkCancellation()
                for item in response.subscriptions ?? [] {
                    try Task.checkCancellation()
                    guard item.topicArn == nil || item.topicArn == topic.arn else { throw SNSError.invalidResponse }
                    let status: String
                    let id: String
                    if let arn = item.subscriptionArn, arn.hasPrefix("arn:") {
                        let parts = arn.split(separator: ":", omittingEmptySubsequences: false)
                        guard parts.count == 7, parts.prefix(6).joined(separator: ":") == topic.arn,
                              !parts[6].isEmpty, !parts[6].contains(where: { $0.isWhitespace || $0.isNewline }),
                              seenARNs.insert(arn).inserted else { throw SNSError.invalidResponse }
                        status = "Confirmed"
                        id = arn
                    } else {
                        switch item.subscriptionArn {
                        case "PendingConfirmation": status = "Pending confirmation"
                        case "Deleted": status = "Deleted"
                        default: status = "Unknown"
                        }
                        id = "\(topic.arn)#subscription-\(result.count)"
                    }
                    result.append(SNSSubscription(
                        id: id, arn: item.subscriptionArn, protocolName: item.protocol,
                        endpoint: item.endpoint, owner: item.owner, topicARN: topic.arn, status: status
                    ))
                }
                guard let next = response.nextToken, !next.isEmpty else {
                    try Task.checkCancellation()
                    return result
                }
                guard seenTokens.insert(next).inserted else { throw SNSError.incompletePagination }
                token = next
            }
            throw SNSError.incompletePagination
        } catch {
            throw Self.sanitized(error, operation: .subscriptions)
        }
    }

    private func operations(scope: SNSScope) async throws -> Operations {
        try Task.checkCancellation()
        if let injected { return injected }
        guard let provider else { throw SNSError.invalidScope }
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": scope.configPath, "AWS_SHARED_CREDENTIALS_FILE": scope.credentialsPath
        ])
        let client = try await provider.snsClient(profile: scope.profile, paths: paths, region: scope.region)
        return Operations(
            topics: { try await client.listTopics($0) }, attributes: { try await client.getTopicAttributes($0) },
            tags: { try await client.listTagsForResource($0) }, subscriptions: { try await client.listSubscriptionsByTopic($0) }
        )
    }

    private static func validateScope(_ scope: SNSScope) throws -> String {
        try Task.checkCancellation()
        let parts = scope.principalARN.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        let partitions: [String: AWSPartition] = [
            "aws": .aws, "aws-cn": .awscn, "aws-us-gov": .awsusgov,
            "aws-iso": .awsiso, "aws-iso-b": .awsisob, "aws-iso-e": .awsisoe,
            "aws-iso-f": .awsisof, "aws-eusc": .awseusc
        ]
        guard !scope.profileName.isEmpty,
              scope.accountID.range(of: "^[0-9]{12}$", options: .regularExpression) != nil,
              scope.region.range(of: "^[a-z]{2,4}(?:-[a-z0-9]+)+-[0-9]+$", options: .regularExpression) != nil,
              parts.count == 6, parts[0] == "arn", ["sts", "iam"].contains(String(parts[2])),
              parts[4] == scope.accountID, !parts[5].isEmpty,
              let partition = partitions[String(parts[1])],
              partition == Region(rawValue: scope.region).partition else { throw SNSError.invalidScope }
        return String(parts[1])
    }

    private static func topic(arn: String, scope: SNSScope, partition: String) throws -> SNSTopic {
        try Task.checkCancellation()
        let parts = arn.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "arn", parts[1] == partition, parts[2] == "sns",
              parts[3] == scope.region, parts[4] == scope.accountID, !parts[5].isEmpty,
              parts[5].range(of: "^[A-Za-z0-9_-]+(?:\\.fifo)?$", options: .regularExpression) != nil else {
            throw SNSError.invalidResponse
        }
        return SNSTopic(arn: arn, name: String(parts[5]))
    }

    private static func validateTopic(_ selected: SNSTopic, scope: SNSScope) throws {
        let partition = try validateScope(scope)
        let parsed = try topic(arn: selected.arn, scope: scope, partition: partition)
        guard parsed.name == selected.name else { throw SNSError.invalidResponse }
    }

    private enum Operation { case list, attributes, tags, subscriptions }

    private static func sanitized(_ error: Error, operation: Operation) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? SNSError { return error }
        if error is AWSServiceError { return SNSError.invalidScope }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AuthorizationError", "AuthorizationErrorException", "AccessDenied", "AccessDeniedException",
            "UnauthorizedException", "ForbiddenException"].contains(code) {
            switch operation {
            case .list: return RequestError.listPermission
            case .attributes: return RequestError.attributesPermission
            case .tags: return RequestError.tagsPermission
            case .subscriptions: return RequestError.subscriptionsPermission
            }
        }
        if UserFacingError.requiresSSOLogin(error) { return RequestError.credentials }
        if error is URLError { return RequestError.network }
        switch code {
        case "Throttled", "Throttling", "ThrottlingException", "TooManyRequestsException":
            return RequestError.throttled
        case "InvalidNextToken", "InvalidNextTokenException":
            return SNSError.incompletePagination
        case "NotFound", "ResourceNotFound", "ResourceNotFoundException":
            return RequestError.notFound
        default: return RequestError.failed
        }
    }

    enum RequestError: LocalizedError, Equatable {
        case listPermission, attributesPermission, tagsPermission, subscriptionsPermission
        case credentials, network, throttled, notFound, failed

        var errorDescription: String? {
            switch self {
            case .listPermission:
                return "SNS topic access was denied. Check sns:ListTopics for the selected account and region."
            case .attributesPermission:
                return "Topic attributes could not be read. Check sns:GetTopicAttributes for this topic ARN."
            case .tagsPermission:
                return "Topic tags could not be read. Check sns:ListTagsForResource for this topic ARN."
            case .subscriptionsPermission:
                return "Topic subscriptions could not be read. Check sns:ListSubscriptionsByTopic for this topic ARN."
            case .credentials:
                return "AWS credentials expired or are unavailable. Sign in to the session, select the profile again, then reload SNS."
            case .network:
                return "Unable to reach SNS. Check your network or proxy, then refresh."
            case .throttled:
                return "SNS is limiting requests. Wait a moment, then refresh manually."
            case .notFound:
                return "The SNS resource was not found. Refresh the topic list and check the selected account and region."
            case .failed:
                return "The SNS request failed. Check the selected profile, region and service availability, then refresh."
            }
        }
    }
}
