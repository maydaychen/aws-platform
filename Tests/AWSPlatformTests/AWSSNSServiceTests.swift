import Foundation
import SotoCore
import SotoSNS
import XCTest
@testable import AWSPlatform

final class AWSSNSServiceTests: XCTestCase {
    func testTopicsPaginateWithoutLoadingDetailsAndPreserveFIFOIdentity() async throws {
        let stub = SNSStub(topicPages: [
            .init(nextToken: "page-2", topics: [.init(topicArn: arn("orders.fifo"))]),
            .init(topics: [.init(topicArn: arn("alerts"))])
        ])
        let topics = try await service(stub).loadTopics(scope: scope())

        XCTAssertEqual(topics.map(\.name), ["alerts", "orders.fifo"])
        XCTAssertEqual(topics.map(\.kind), [.standard, .fifo])
        XCTAssertEqual(topics.map(\.id), [arn("alerts"), arn("orders.fifo")])
        let requests = await stub.requests()
        XCTAssertEqual(requests.topics.map(\.nextToken), [nil, "page-2"])
        XCTAssertTrue(requests.attributes.isEmpty)
        XCTAssertTrue(requests.tags.isEmpty)
        XCTAssertTrue(requests.subscriptions.isEmpty)
    }

    func testTopicARNMustMatchAccountRegionPartitionAndTopicNameShape() async {
        let invalidARNs = [
            "arn:aws:sns:us-east-1:999988887777:alerts",
            "arn:aws:sns:eu-west-1:111122223333:alerts",
            "arn:aws-cn:sns:us-east-1:111122223333:alerts",
            "arn:aws:sqs:us-east-1:111122223333:alerts",
            arn(""), arn("has spaces"), arn("alerts") + ":subscription-id", "invalid"
        ]
        for value in invalidARNs {
            let stub = SNSStub(topicPages: [.init(topics: [.init(topicArn: value)])])
            await assertSNSError(.invalidResponse) { _ = try await self.service(stub).loadTopics(scope: self.scope()) }
            let requests = await stub.requests()
            XCTAssertEqual(requests.topics.count, 1)
            XCTAssertTrue(requests.attributes.isEmpty)
            XCTAssertTrue(requests.tags.isEmpty)
            XCTAssertTrue(requests.subscriptions.isEmpty)
        }
        let missing = SNSStub(topicPages: [.init(topics: [.init()])])
        await assertSNSError(.invalidResponse) { _ = try await self.service(missing).loadTopics(scope: self.scope()) }
    }

    func testTopicPaginationCyclePageLimitAndDuplicateARNNeverReturnPartialList() async {
        let cases: [([SNS.ListTopicsResponse], SNSError)] = [
            ([.init(nextToken: "again"), .init(nextToken: "again")], .incompletePagination),
            ((1...100).map { .init(nextToken: "page-\($0)") }, .incompletePagination),
            ([.init(nextToken: "next", topics: [.init(topicArn: arn("alerts"))]),
              .init(topics: [.init(topicArn: arn("alerts"))])], .invalidResponse)
        ]
        for (pages, expected) in cases {
            let stub = SNSStub(topicPages: pages)
            await assertSNSError(expected) { _ = try await self.service(stub).loadTopics(scope: self.scope()) }
            let requests = await stub.requests()
            XCTAssertEqual(requests.topics.count, pages.count)
        }
    }

    func testReturnedAttributesKeepUnknownFieldsAndMissingFieldsStayAbsent() async throws {
        let values = [
            "TopicArn": arn("alerts"), "Owner": "111122223333", "DisplayName": "Team alerts",
            "FifoTopic": "false", "SubscriptionsConfirmed": "0003",
            "Policy": "{\"Statement\":[]}", "FutureSetting": "preserved"
        ]
        let full = SNSStub(attributes: .init(attributes: values))
        let result = try await service(full).loadAttributes(scope: scope(), topic: topic())
        XCTAssertEqual(result, values)
        let requests = await full.requests()
        XCTAssertEqual(requests.attributes.map(\.topicArn), [arn("alerts")])
        XCTAssertTrue(requests.topics.isEmpty)
        XCTAssertTrue(requests.tags.isEmpty)
        XCTAssertTrue(requests.subscriptions.isEmpty)

        let limited = SNSStub(attributes: .init(attributes: ["DisplayName": "Visible name"]))
        let limitedResult = try await service(limited).loadAttributes(scope: scope(), topic: topic())
        XCTAssertEqual(limitedResult, ["DisplayName": "Visible name"])
        XCTAssertNil(limitedResult["Owner"])
        XCTAssertNil(limitedResult["TopicArn"])
        XCTAssertNil(limitedResult["FifoTopic"])
        XCTAssertNil(limitedResult["SubscriptionsConfirmed"])

        let omitted = SNSStub(attributes: .init())
        let omittedResult = try await service(omitted).loadAttributes(scope: scope(), topic: topic())
        XCTAssertTrue(omittedResult.isEmpty)
    }

    func testAttributesValidateIdentityOnlyWhenReturned() async {
        for attributes in [
            ["TopicArn": arn("different")], ["Owner": "999988887777"], ["TopicArn": ""], ["Owner": ""]
        ] {
            let stub = SNSStub(attributes: .init(attributes: attributes))
            await assertSNSError(.invalidResponse) { _ = try await self.service(stub).loadAttributes(scope: self.scope(), topic: self.topic()) }
        }
    }

    func testTagsOnlyQuerySelectedARNAndPreserveEmptyValues() async throws {
        let stub = SNSStub(tags: .init(tags: [.init(key: "Owner", value: "team"), .init(key: "Empty", value: "")]))
        let tags = try await service(stub).loadTags(scope: scope(), topic: topic())

        XCTAssertEqual(tags, ["Owner": "team", "Empty": ""])
        let requests = await stub.requests()
        XCTAssertEqual(requests.tags.map(\.resourceArn), [arn("alerts")])
        XCTAssertTrue(requests.attributes.isEmpty)
        XCTAssertTrue(requests.topics.isEmpty)
        XCTAssertTrue(requests.subscriptions.isEmpty)

        let duplicates = SNSStub(tags: .init(tags: [.init(key: "Owner", value: "first"), .init(key: "Owner", value: "second")]))
        await assertSNSError(.invalidResponse) { _ = try await self.service(duplicates).loadTags(scope: self.scope(), topic: self.topic()) }
        let empty = SNSStub(tags: .init())
        let noTags = try await service(empty).loadTags(scope: scope(), topic: topic())
        XCTAssertTrue(noTags.isEmpty)
    }

    func testSubscriptionsPreserveCrossAccountOwnerPendingDeletedAndUnknownRows() async throws {
        let confirmedARN = arn("alerts") + ":confirmed-1"
        let endpoint = "arn:aws:sqs:us-east-1:444455556666:cross-account-queue"
        let stub = SNSStub(subscriptionPages: [
            .init(nextToken: "page-2", subscriptions: [
                .init(endpoint: endpoint, owner: "444455556666", protocol: "sqs", subscriptionArn: confirmedARN, topicArn: arn("alerts")),
                .init(endpoint: "first@example.invalid", owner: "444455556666", protocol: "email", subscriptionArn: "PendingConfirmation"),
                .init(endpoint: "second@example.invalid", protocol: "email", subscriptionArn: "PendingConfirmation")
            ]),
            .init(subscriptions: [
                .init(subscriptionArn: "Deleted"), .init(subscriptionArn: "Deleted"),
                .init(subscriptionArn: "future-status"), .init(subscriptionArn: ""), .init()
            ])
        ])
        let rows = try await service(stub).loadSubscriptions(scope: scope(), topic: topic())

        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(Set(rows.map(\.id)).count, 8)
        XCTAssertEqual(rows.map(\.status), [
            "Confirmed", "Pending confirmation", "Pending confirmation", "Deleted", "Deleted", "Unknown", "Unknown", "Unknown"
        ])
        XCTAssertEqual(rows[0].id, confirmedARN)
        XCTAssertEqual(rows[0].owner, "444455556666")
        XCTAssertEqual(rows[0].endpoint, endpoint)
        XCTAssertEqual(rows[0].protocolName, "sqs")
        XCTAssertEqual(rows[1].arn, "PendingConfirmation")
        XCTAssertEqual(rows[5].arn, "future-status")
        XCTAssertEqual(rows[6].arn, "")
        XCTAssertNil(rows[7].arn)
        XCTAssertNil(rows[7].protocolName)
        XCTAssertNil(rows[7].endpoint)
        XCTAssertNil(rows[7].owner)
        XCTAssertTrue(rows.allSatisfy { $0.topicARN == arn("alerts") })
        let requests = await stub.requests()
        XCTAssertEqual(requests.subscriptions.map(\.nextToken), [nil, "page-2"])
        XCTAssertTrue(requests.subscriptions.allSatisfy { $0.topicArn == arn("alerts") })
        XCTAssertTrue(requests.topics.isEmpty)
        XCTAssertTrue(requests.attributes.isEmpty)
        XCTAssertTrue(requests.tags.isEmpty)
    }

    func testSubscriptionARNAndReturnedTopicIdentityCannotEscapeSelectedTopic() async {
        let invalid = [
            "arn:aws:sns:us-east-1:999988887777:alerts:subscription",
            "arn:aws:sns:eu-west-1:111122223333:alerts:subscription",
            "arn:aws-cn:sns:us-east-1:111122223333:alerts:subscription",
            arn("different") + ":subscription", arn("alerts"), arn("alerts") + ":",
            arn("alerts") + ":one:two", arn("alerts") + ":has spaces", "arn:invalid"
        ]
        for subscriptionARN in invalid {
            let stub = SNSStub(subscriptionPages: [.init(subscriptions: [.init(subscriptionArn: subscriptionARN)])])
            await assertSNSError(.invalidResponse) { _ = try await self.service(stub).loadSubscriptions(scope: self.scope(), topic: self.topic()) }
        }
        for returnedTopic in [arn("different"), ""] {
            let stub = SNSStub(subscriptionPages: [.init(subscriptions: [
                .init(subscriptionArn: "PendingConfirmation", topicArn: returnedTopic)
            ])])
            await assertSNSError(.invalidResponse) { _ = try await self.service(stub).loadSubscriptions(scope: self.scope(), topic: self.topic()) }
        }
    }

    func testSubscriptionPaginationRejectsCyclesLimitAndRepeatedConfirmedARN() async {
        let confirmed = SNS.Subscription(subscriptionArn: arn("alerts") + ":confirmed-1")
        let cases: [([SNS.ListSubscriptionsByTopicResponse], SNSError)] = [
            ([.init(nextToken: "again"), .init(nextToken: "again")], .incompletePagination),
            ((1...100).map { .init(nextToken: "page-\($0)") }, .incompletePagination),
            ([.init(nextToken: "next", subscriptions: [confirmed]), .init(subscriptions: [confirmed])], .invalidResponse)
        ]
        for (pages, expected) in cases {
            let stub = SNSStub(subscriptionPages: pages)
            await assertSNSError(expected) { _ = try await self.service(stub).loadSubscriptions(scope: self.scope(), topic: self.topic()) }
            let requests = await stub.requests()
            XCTAssertEqual(requests.subscriptions.count, pages.count)
        }
    }

    func testLaterSubscriptionPageFailureDoesNotPublishPartialRows() async {
        let stub = SNSStub(
            subscriptionPages: [.init(nextToken: "next", subscriptions: [.init(subscriptionArn: "PendingConfirmation")])],
            failure: SNSErrorType.authorizationErrorException, failingSubscriptionPage: 2
        )
        await assertRequestError(.subscriptionsPermission) {
            _ = try await self.service(stub).loadSubscriptions(scope: self.scope(), topic: self.topic())
        }
        let requests = await stub.requests()
        XCTAssertEqual(requests.subscriptions.count, 2)
    }

    func testInvalidScopeOrSelectedNameDoesNotIssueRequests() async {
        let stub = SNSStub()
        let service = service(stub)
        for invalid in [
            scope(account: "-"), scope(region: ""), scope(partition: "aws-cn"),
            scope(region: "cn-north-1", partition: "aws--cn"),
            scope(principal: "arn:aws:sts::999988887777:assumed-role/Test/session")
        ] {
            await assertSNSError(.invalidScope) { _ = try await service.loadTopics(scope: invalid) }
        }
        for selected in [
            SNSTopic(arn: arn("alerts", region: "eu-west-1"), name: "alerts"),
            SNSTopic(arn: arn("alerts"), name: "different")
        ] {
            await assertSNSError(.invalidResponse) { _ = try await service.loadAttributes(scope: self.scope(), topic: selected) }
            await assertSNSError(.invalidResponse) { _ = try await service.loadTags(scope: self.scope(), topic: selected) }
            await assertSNSError(.invalidResponse) { _ = try await service.loadSubscriptions(scope: self.scope(), topic: selected) }
        }
        let requests = await stub.requests()
        XCTAssertTrue(requests.topics.isEmpty)
        XCTAssertTrue(requests.attributes.isEmpty)
        XCTAssertTrue(requests.tags.isEmpty)
        XCTAssertTrue(requests.subscriptions.isEmpty)
    }

    func testChinaAndGovCloudTopicARNsMatchTheSelectedPartition() async throws {
        for (partition, region) in [("aws-cn", "cn-north-1"), ("aws-us-gov", "us-gov-west-1")] {
            let topicARN = "arn:\(partition):sns:\(region):111122223333:alerts"
            let stub = SNSStub(topicPages: [.init(topics: [.init(topicArn: topicARN)])])
            let rows = try await service(stub).loadTopics(scope: scope(region: region, partition: partition))
            XCTAssertEqual(rows.map(\.arn), [topicARN])
        }
    }

    func testCancellationAfterEachOperationDoesNotPublishResponse() async {
        for operation in ["list", "attributes", "tags", "subscriptions"] {
            let gate = TestGate()
            let service = AWSSNSService(
                topicLoader: { _ in await gate.wait(); return .init() },
                attributeLoader: { _ in await gate.wait(); return .init() },
                tagLoader: { _ in await gate.wait(); return .init() },
                subscriptionLoader: { _ in await gate.wait(); return .init() }
            )
            let scope = scope()
            let topic = topic()
            let task = Task {
                switch operation {
                case "list": _ = try await service.loadTopics(scope: scope)
                case "attributes": _ = try await service.loadAttributes(scope: scope, topic: topic)
                case "tags": _ = try await service.loadTags(scope: scope, topic: topic)
                default: _ = try await service.loadSubscriptions(scope: scope, topic: topic)
                }
            }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do {
                try await task.value
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testPermissionErrorsIdentifyTheFourReadOnlyIAMActions() async {
        let stub = SNSStub(failure: SNSErrorType.authorizationErrorException)
        let service = service(stub)
        await assertRequestError(.listPermission) { _ = try await service.loadTopics(scope: self.scope()) }
        await assertRequestError(.attributesPermission) { _ = try await service.loadAttributes(scope: self.scope(), topic: self.topic()) }
        await assertRequestError(.tagsPermission) { _ = try await service.loadTags(scope: self.scope(), topic: self.topic()) }
        await assertRequestError(.subscriptionsPermission) { _ = try await service.loadSubscriptions(scope: self.scope(), topic: self.topic()) }

        XCTAssertTrue(AWSSNSService.RequestError.listPermission.localizedDescription.contains("sns:ListTopics"))
        XCTAssertTrue(AWSSNSService.RequestError.attributesPermission.localizedDescription.contains("sns:GetTopicAttributes"))
        XCTAssertTrue(AWSSNSService.RequestError.tagsPermission.localizedDescription.contains("sns:ListTagsForResource"))
        XCTAssertTrue(AWSSNSService.RequestError.subscriptionsPermission.localizedDescription.contains("sns:ListSubscriptionsByTopic"))
        let requests = await stub.requests()
        XCTAssertEqual(requests.topics.count, 1)
        XCTAssertEqual(requests.attributes.count, 1)
        XCTAssertEqual(requests.tags.count, 1)
        XCTAssertEqual(requests.subscriptions.count, 1)
    }

    func testNetworkCredentialsThrottleAndUnknownErrorsAreSanitized() async {
        let cases: [(Error, AWSSNSService.RequestError)] = [
            (URLError(.notConnectedToInternet), .network),
            (AWSResponseError(errorCode: "ExpiredToken"), .credentials),
            (SNSErrorType.throttledException, .throttled),
            (SNSErrorType.notFoundException, .notFound),
            (NSError(domain: "private-endpoint@example.invalid", code: 1), .failed),
            (SNSErrorType.invalidParameterException, .failed)
        ]
        for (failure, expected) in cases {
            let stub = SNSStub(failure: failure)
            await assertRequestError(expected) { _ = try await self.service(stub).loadTopics(scope: self.scope()) }
        }
    }

    private func service(_ stub: SNSStub) -> AWSSNSService {
        AWSSNSService(
            topicLoader: { try await stub.topics($0) }, attributeLoader: { try await stub.attributes($0) },
            tagLoader: { try await stub.tags($0) }, subscriptionLoader: { try await stub.subscriptions($0) }
        )
    }

    private func arn(_ name: String, region: String = "us-east-1") -> String {
        "arn:aws:sns:\(region):111122223333:\(name)"
    }

    private func topic(_ name: String = "alerts") -> SNSTopic {
        SNSTopic(arn: arn(name), name: name)
    }

    private func scope(
        account: String = "111122223333", region: String = "us-east-1",
        partition: String = "aws", principal: String? = nil
    ) -> SNSScope {
        SNSScope(
            profile: AWSProfile(name: "work", region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
            identity: AWSIdentity(account: account, arn: principal ?? "arn:\(partition):sts::\(account):assumed-role/Test/session", userID: "example"),
            region: region,
            paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/config", "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials"])
        )
    }

    private func assertSNSError(
        _ expected: SNSError, file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected SNSError", file: file, line: line)
        } catch {
            guard let actual = error as? SNSError else { return XCTFail("Unexpected error: \(error)", file: file, line: line) }
            switch (actual, expected) {
            case (.invalidScope, .invalidScope), (.invalidResponse, .invalidResponse), (.incompletePagination, .incompletePagination): break
            default: XCTFail("Wrong SNS error: \(actual)", file: file, line: line)
            }
        }
    }

    private func assertRequestError(
        _ expected: AWSSNSService.RequestError, file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected request error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AWSSNSService.RequestError, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("private-endpoint@example.invalid"), file: file, line: line)
        }
    }
}

private actor SNSStub {
    private var topicPages: [SNS.ListTopicsResponse]
    private var attributeResponse: SNS.GetTopicAttributesResponse
    private var tagResponse: SNS.ListTagsForResourceResponse
    private var subscriptionPages: [SNS.ListSubscriptionsByTopicResponse]
    private let failure: Error?
    private let failingSubscriptionPage: Int?
    private var topicRequests: [SNS.ListTopicsInput] = []
    private var attributeRequests: [SNS.GetTopicAttributesInput] = []
    private var tagRequests: [SNS.ListTagsForResourceRequest] = []
    private var subscriptionRequests: [SNS.ListSubscriptionsByTopicInput] = []

    init(
        topicPages: [SNS.ListTopicsResponse] = [],
        attributes: SNS.GetTopicAttributesResponse = .init(),
        tags: SNS.ListTagsForResourceResponse = .init(),
        subscriptionPages: [SNS.ListSubscriptionsByTopicResponse] = [],
        failure: Error? = nil, failingSubscriptionPage: Int? = nil
    ) {
        self.topicPages = topicPages
        attributeResponse = attributes
        tagResponse = tags
        self.subscriptionPages = subscriptionPages
        self.failure = failure
        self.failingSubscriptionPage = failingSubscriptionPage
    }

    func topics(_ request: SNS.ListTopicsInput) throws -> SNS.ListTopicsResponse {
        topicRequests.append(request)
        if let failure { throw failure }
        guard !topicPages.isEmpty else { throw SNSError.invalidResponse }
        return topicPages.removeFirst()
    }

    func attributes(_ request: SNS.GetTopicAttributesInput) throws -> SNS.GetTopicAttributesResponse {
        attributeRequests.append(request)
        if let failure { throw failure }
        return attributeResponse
    }

    func tags(_ request: SNS.ListTagsForResourceRequest) throws -> SNS.ListTagsForResourceResponse {
        tagRequests.append(request)
        if let failure { throw failure }
        return tagResponse
    }

    func subscriptions(_ request: SNS.ListSubscriptionsByTopicInput) throws -> SNS.ListSubscriptionsByTopicResponse {
        subscriptionRequests.append(request)
        if let failure, failingSubscriptionPage == nil || failingSubscriptionPage == subscriptionRequests.count { throw failure }
        guard !subscriptionPages.isEmpty else { throw SNSError.invalidResponse }
        return subscriptionPages.removeFirst()
    }

    func requests() -> (
        topics: [SNS.ListTopicsInput], attributes: [SNS.GetTopicAttributesInput],
        tags: [SNS.ListTagsForResourceRequest], subscriptions: [SNS.ListSubscriptionsByTopicInput]
    ) {
        (topicRequests, attributeRequests, tagRequests, subscriptionRequests)
    }
}
