import Foundation
import SotoCore
import SotoHealth
import XCTest
@testable import AWSPlatform

final class AWSHealthServiceTests: XCTestCase {
    func testAllPagesIncludingEmptyPagesKeepOnlyAccountEventsAndUpcomingChanges() async throws {
        let future = Date(timeIntervalSince1970: 4_000_000_000)
        let upcoming = Health.Event(
            arn: arn("future"), availabilityZone: "eu-west-1a", eventScopeCode: .accountSpecific,
            eventTypeCategory: .scheduledChange, eventTypeCode: "AWS_EC2_MAINTENANCE",
            lastUpdatedTime: future, region: "eu-west-1", service: "EC2", startTime: future, statusCode: .upcoming
        )
        let stub = HealthStub(eventPages: [
            .init(events: [rawEvent("older")], nextToken: "empty-page"),
            .init(events: [], nextToken: "last-page"),
            .init(events: [upcoming, .init(arn: "malformed-public", eventScopeCode: .public),
                           .init(eventScopeCode: Health.EventScopeCode.none), .init()])
        ])
        let events = try await service(stub).loadEvents(scope: scope())
        XCTAssertEqual(events.map(\.arn), [arn("future"), arn("older")])
        XCTAssertEqual(events[0].status, "upcoming")
        XCTAssertEqual(events[0].category, "scheduledChange")
        XCTAssertEqual(events[0].startTime, future)
        XCTAssertEqual(events[0].availabilityZone, "eu-west-1a")
        XCTAssertEqual(events[0].region, "eu-west-1")
        let requests = await stub.requests()
        XCTAssertEqual(requests.events.map(\.nextToken), [nil, "empty-page", "last-page"])
        for request in requests.events {
            XCTAssertEqual(request.locale, "en")
            XCTAssertEqual(request.maxResults, 100)
            XCTAssertNil(request.filter, "No region, status or time cutoff should hide account events")
        }
        XCTAssertTrue(requests.details.isEmpty)
        XCTAssertTrue(requests.entities.isEmpty)
    }

    func testOptionalEventFieldsStayUnknownAndBlankOrCurrentARNAccountIsAccepted() async throws {
        for (account, region) in [("", "global"), ("111122223333", "global"), ("", ""), ("111122223333", "")] {
            let raw = Health.Event(
                arn: arn("minimal", region: region, account: account), eventScopeCode: .accountSpecific,
                eventTypeCode: "AWS_EC2_MAINTENANCE", service: "EC2"
            )
            let events = try await service(HealthStub(eventPages: [.init(events: [raw])])).loadEvents(scope: scope())
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events[0].category, "Unknown")
            XCTAssertEqual(events[0].status, "Unknown")
            XCTAssertEqual(events[0].region, "Unknown")
            XCTAssertNil(events[0].startTime)
            XCTAssertNil(events[0].endTime)
        }
    }

    func testRejectsMalformedCrossAccountAndCrossPartitionEventARNs() async {
        let invalidARNs = [
            "not-an-arn", arn("id", account: "444455556666"), arn("id", partition: "aws-cn"),
            "arn:aws:sns:us-east-1::event/EC2/AWS_EC2_MAINTENANCE/id",
            "arn:aws:health:us-east-1::event/EC2/AWS_EC2_MAINTENANCE/",
            "arn:aws:health:us-east-1::event/EC2/AWS_EC2_MAINTENANCE/id/extra",
            "arn:aws:health:us-east-1::event/LAMBDA/AWS_EC2_MAINTENANCE/id",
            "arn:aws:health:us-east-1::event/EC2/WRONG_TYPE/id"
        ]
        for value in invalidARNs {
            let stub = HealthStub(eventPages: [.init(events: [rawEvent("id", arn: value)])])
            await assertError(HealthError.invalidResponse) { _ = try await self.service(stub).loadEvents(scope: self.scope()) }
        }
    }

    func testMissingRequiredEventFieldsAndDuplicateARNRejectWholeList() async {
        let invalidEvents: [Health.Event] = [
            .init(eventScopeCode: .accountSpecific, eventTypeCode: "AWS_EC2_MAINTENANCE", service: "EC2"),
            .init(arn: arn("id"), eventScopeCode: .accountSpecific, service: "EC2"),
            .init(arn: arn("id"), eventScopeCode: .accountSpecific, eventTypeCode: "AWS_EC2_MAINTENANCE")
        ]
        for event in invalidEvents {
            let stub = HealthStub(eventPages: [.init(events: [rawEvent("valid"), event])])
            await assertError(HealthError.invalidResponse) { _ = try await self.service(stub).loadEvents(scope: self.scope()) }
        }
        let stub = HealthStub(eventPages: [
            .init(events: [rawEvent("duplicate")], nextToken: "next"), .init(events: [rawEvent("duplicate")])
        ])
        await assertError(HealthError.invalidResponse) { _ = try await self.service(stub).loadEvents(scope: self.scope()) }
    }

    func testListPaginationCyclesAndPageLimitNeverReturnPartialResults() async {
        let cases: [[Health.DescribeEventsResponse]] = [
            [.init(events: [rawEvent("first")], nextToken: "repeat"), .init(nextToken: "repeat")],
            (1...100).map { .init(nextToken: "page-\($0)") }
        ]
        for pages in cases {
            let stub = HealthStub(eventPages: pages)
            await assertError(HealthError.incompletePagination) { _ = try await self.service(stub).loadEvents(scope: self.scope()) }
            let requests = await stub.requests()
            XCTAssertEqual(requests.events.count, pages.count)
        }
    }

    func testDetailsRequestOneExactARNAndPreserveDescriptionAndMetadata() async throws {
        let stub = HealthStub(detailResponse: .init(successfulSet: [
            .init(event: rawEvent("selected"), eventDescription: .init(latestDescription: "Scheduled maintenance"),
                  eventMetadata: ["plannedEnd": "TBD"])
        ]))
        let details = try await service(stub).loadDetails(scope: scope(), event: event("selected"))
        XCTAssertEqual(details.event.arn, arn("selected"))
        XCTAssertEqual(details.description, "Scheduled maintenance")
        XCTAssertEqual(details.metadata, ["plannedEnd": "TBD"])
        let requests = await stub.requests()
        XCTAssertEqual(requests.details.count, 1)
        XCTAssertEqual(requests.details[0].eventArns, [arn("selected")])
        XCTAssertEqual(requests.details[0].locale, "en")
        XCTAssertTrue(requests.events.isEmpty)
        XCTAssertTrue(requests.entities.isEmpty)
    }

    func testMissingDescriptionAndMetadataStayAbsent() async throws {
        let stub = HealthStub(detailResponse: .init(successfulSet: [.init(event: rawEvent())]))
        let details = try await service(stub).loadDetails(scope: scope(), event: event())
        XCTAssertNil(details.description)
        XCTAssertTrue(details.metadata.isEmpty)
    }

    func testDetailsRejectMissingMultipleMismatchedAndNonAccountResults() async {
        let cases: [Health.DescribeEventDetailsResponse] = [
            .init(), .init(successfulSet: [.init()]),
            .init(successfulSet: [.init(event: rawEvent()), .init(event: rawEvent())]),
            .init(successfulSet: [.init(event: rawEvent("other"))]),
            .init(successfulSet: [.init(event: rawEvent(eventScope: .public))]),
            .init(successfulSet: [.init(event: rawEvent(eventScope: Health.EventScopeCode.none))]),
            .init(successfulSet: [.init(event: rawEvent(eventScope: nil))]),
            .init(failedSet: [.init(errorName: "AccessDenied", eventArn: arn("other"))])
        ]
        for response in cases {
            await assertError(HealthError.invalidResponse) {
                _ = try await self.service(HealthStub(detailResponse: response)).loadDetails(scope: self.scope(), event: self.event())
            }
        }
    }

    func testPartialDetailFailureNeverPublishesSuccessOrRawFailureMessage() async {
        let cases: [(String, AWSHealthService.RequestError)] = [
            ("AccessDeniedException", .detailPermission), ("SubscriptionRequiredException", .subscriptionRequired),
            ("ExpiredToken", .credentials), ("private-token-error", .failed)
        ]
        for (code, expected) in cases {
            let response = Health.DescribeEventDetailsResponse(
                failedSet: [.init(errorMessage: "private-token-error secret request payload", errorName: code, eventArn: arn("id"))],
                successfulSet: [.init(event: rawEvent(), eventMetadata: ["private": "must-not-return"])]
            )
            await assertError(expected) {
                _ = try await self.service(HealthStub(detailResponse: response)).loadDetails(scope: self.scope(), event: self.event())
            }
        }
    }

    func testEntitiesPaginateEmptyPagesAndRequestOnlySelectedEvent() async throws {
        let updated = Date(timeIntervalSince1970: 1_780_000_000)
        let stub = HealthStub(entityPages: [
            .init(entities: [.init(awsAccountId: "111122223333", entityArn: entityARN("one"), entityValue: "i-one",
                                  eventArn: arn("id"), lastUpdatedTime: updated, statusCode: .pending)], nextToken: "empty"),
            .init(nextToken: "last"),
            .init(entities: [.init(entityArn: entityARN("two"), eventArn: arn("id"))])
        ])
        let entities = try await service(stub).loadEntities(scope: scope(), event: event())
        XCTAssertEqual(entities.count, 2)
        let first = try XCTUnwrap(entities.first { $0.id == entityARN("one") })
        XCTAssertEqual(first.value, "i-one")
        XCTAssertEqual(first.status, "PENDING")
        XCTAssertEqual(first.accountID, "111122223333")
        XCTAssertEqual(first.lastUpdatedTime, updated)
        let second = try XCTUnwrap(entities.first { $0.id == entityARN("two") })
        XCTAssertNil(second.accountID, "Missing account must not be invented from the selected profile")
        XCTAssertEqual(second.value, "Unknown")
        XCTAssertEqual(second.status, "Unknown")
        let requests = await stub.requests()
        XCTAssertEqual(requests.entities.map(\.nextToken), [nil, "empty", "last"])
        for request in requests.entities {
            XCTAssertEqual(request.filter.eventArns, [arn("id")])
            XCTAssertNil(request.filter.entityArns)
            XCTAssertNil(request.filter.statusCodes)
            XCTAssertNil(request.filter.lastUpdatedTimes)
            XCTAssertEqual(request.locale, "en")
            XCTAssertEqual(request.maxResults, 100)
        }
    }

    func testEntityAccountAndEventMismatchesAreRejectedEvenIfOtherEntitiesAreValid() async {
        let cases: [Health.AffectedEntity] = [
            .init(awsAccountId: "444455556666", entityArn: entityARN("bad"), eventArn: arn("id")),
            .init(entityArn: entityARN("bad", account: "444455556666"), eventArn: arn("id")),
            .init(entityArn: entityARN("bad"), eventArn: arn("other")),
            .init(entityArn: entityARN("bad")), .init(eventArn: arn("id")),
            .init(entityArn: "malformed", eventArn: arn("id"))
        ]
        for raw in cases {
            let stub = HealthStub(entityPages: [.init(entities: [entity("valid"), raw])])
            await assertError(HealthError.invalidResponse) {
                _ = try await self.service(stub).loadEntities(scope: self.scope(), event: self.event())
            }
        }
    }

    func testEntitiesAllowBlankAccountWithoutInventingItAndRejectDuplicates() async throws {
        let stub = HealthStub(entityPages: [.init(entities: [
            .init(awsAccountId: "", entityArn: entityARN("one", account: ""), eventArn: arn("id"))
        ])])
        let entities = try await service(stub).loadEntities(scope: scope(), event: event())
        XCTAssertNil(entities[0].accountID)
        let duplicate = HealthStub(entityPages: [
            .init(entities: [entity("one")], nextToken: "next"), .init(entities: [entity("one")])
        ])
        await assertError(HealthError.invalidResponse) {
            _ = try await self.service(duplicate).loadEntities(scope: self.scope(), event: self.event())
        }
    }

    func testEntityPaginationCyclesAndPageLimitNeverReturnPartialResults() async {
        let cases: [[Health.DescribeAffectedEntitiesResponse]] = [
            [.init(entities: [entity("one")], nextToken: "repeat"), .init(nextToken: "repeat")],
            (1...100).map { .init(nextToken: "page-\($0)") }
        ]
        for pages in cases {
            let stub = HealthStub(entityPages: pages)
            await assertError(HealthError.incompletePagination) {
                _ = try await self.service(stub).loadEntities(scope: self.scope(), event: self.event())
            }
            let requests = await stub.requests()
            XCTAssertEqual(requests.entities.count, pages.count)
        }
    }

    func testInvalidScopeAndForeignSelectedARNMakeNoRequests() async {
        let stub = HealthStub()
        let service = service(stub)
        for invalid in [scope(account: ""), scope(principal: "arn:aws:sts::444455556666:assumed-role/Test/session"), scope(profile: "")] {
            await assertError(HealthError.invalidScope) { _ = try await service.loadEvents(scope: invalid) }
            await assertError(HealthError.invalidScope) { _ = try await service.loadDetails(scope: invalid, event: self.event()) }
            await assertError(HealthError.invalidScope) { _ = try await service.loadEntities(scope: invalid, event: self.event()) }
        }
        let foreign = HealthEvent(arn: arn("id", account: "444455556666"), service: "EC2", typeCode: "AWS_EC2_MAINTENANCE",
                                  category: "scheduledChange", status: "open", region: "us-east-1")
        await assertError(HealthError.invalidResponse) { _ = try await service.loadDetails(scope: self.scope(), event: foreign) }
        await assertError(HealthError.invalidResponse) { _ = try await service.loadEntities(scope: self.scope(), event: foreign) }
        let requests = await stub.requests()
        XCTAssertTrue(requests.events.isEmpty)
        XCTAssertTrue(requests.details.isEmpty)
        XCTAssertTrue(requests.entities.isEmpty)
    }

    func testKnownPartitionEndpointsAndEventsIgnoreProfileResourceRegion() async throws {
        let cases = [("aws", "us-east-1", "https://health.us-east-1.amazonaws.com"),
                     ("aws-cn", "cn-northwest-1", "https://health.cn-northwest-1.amazonaws.com.cn"),
                     ("aws-us-gov", "us-gov-west-1", "https://health.us-gov-west-1.amazonaws.com")]
        for (partition, region, url) in cases {
            let selected = scope(partition: partition)
            XCTAssertEqual(try selected.endpoint(), HealthEndpoint(partition: partition, region: region, url: url))
            let eventARN = arn("id", region: region, partition: partition)
            let stub = HealthStub(eventPages: [.init(events: [rawEvent(arn: eventARN)])])
            let events = try await service(stub).loadEvents(scope: selected)
            XCTAssertEqual(events.map(\.arn), [eventARN])
        }
        let stub = HealthStub()
        await assertError(HealthError.unsupportedPartition) { _ = try await self.service(stub).loadEvents(scope: self.scope(partition: "aws-iso")) }
        let requests = await stub.requests()
        XCTAssertTrue(requests.events.isEmpty)
    }

    func testPermissionErrorsNameOnlyTheRequestedReadAction() async {
        let service = service(HealthStub(failure: AWSResponseError(errorCode: "AccessDeniedException")))
        await assertError(AWSHealthService.RequestError.listPermission) { _ = try await service.loadEvents(scope: self.scope()) }
        await assertError(AWSHealthService.RequestError.detailPermission) { _ = try await service.loadDetails(scope: self.scope(), event: self.event()) }
        await assertError(AWSHealthService.RequestError.entitiesPermission) { _ = try await service.loadEntities(scope: self.scope(), event: self.event()) }
        XCTAssertTrue(AWSHealthService.RequestError.listPermission.localizedDescription.contains("health:DescribeEvents"))
        XCTAssertTrue(AWSHealthService.RequestError.detailPermission.localizedDescription.contains("health:DescribeEventDetails"))
        XCTAssertTrue(AWSHealthService.RequestError.entitiesPermission.localizedDescription.contains("health:DescribeAffectedEntities"))
    }

    func testSupportPlanCredentialNetworkThrottleAndUnknownFailuresAreSanitizedForEveryOperation() async {
        let cases: [(Error, AWSHealthService.RequestError)] = [
            (AWSResponseError(errorCode: "SubscriptionRequiredException"), .subscriptionRequired),
            (AWSResponseError(errorCode: "ExpiredToken"), .credentials),
            (AWSResponseError(errorCode: "ThrottlingException"), .throttled),
            (URLError(.notConnectedToInternet), .network),
            (NSError(domain: "private-token-error", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-token-error"]), .failed)
        ]
        for (failure, expected) in cases {
            let service = service(HealthStub(failure: failure))
            await assertError(expected) { _ = try await service.loadEvents(scope: self.scope()) }
            await assertError(expected) { _ = try await service.loadDetails(scope: self.scope(), event: self.event()) }
            await assertError(expected) { _ = try await service.loadEntities(scope: self.scope(), event: self.event()) }
        }
        let service = service(HealthStub(failure: HealthErrorType.invalidPaginationToken))
        await assertError(HealthError.incompletePagination) { _ = try await service.loadEvents(scope: self.scope()) }
        await assertError(HealthError.incompletePagination) { _ = try await service.loadEntities(scope: self.scope(), event: self.event()) }
    }

    func testCancellationBeforeRequestMakesNoCalls() async {
        for operation in 0..<3 {
            let gate = TestGate()
            let stub = HealthStub()
            let service = service(stub)
            let selectedScope = scope()
            let selectedEvent = event()
            let task = Task {
                await gate.wait()
                switch operation {
                case 0: _ = try await service.loadEvents(scope: selectedScope)
                case 1: _ = try await service.loadDetails(scope: selectedScope, event: selectedEvent)
                default: _ = try await service.loadEntities(scope: selectedScope, event: selectedEvent)
                }
            }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
            let requests = await stub.requests()
            XCTAssertTrue(requests.events.isEmpty)
            XCTAssertTrue(requests.details.isEmpty)
            XCTAssertTrue(requests.entities.isEmpty)
        }
    }

    func testCancellationAfterResponseIsPreservedForEveryOperation() async {
        for operation in 0..<3 {
            let gate = TestGate()
            let service = AWSHealthService(
                eventLoader: { _ in await gate.wait(); return .init() },
                detailLoader: { _ in await gate.wait(); return .init() },
                entityLoader: { _ in await gate.wait(); return .init() }
            )
            let selectedScope = scope()
            let selectedEvent = event()
            let task = Task {
                switch operation {
                case 0: _ = try await service.loadEvents(scope: selectedScope)
                case 1: _ = try await service.loadDetails(scope: selectedScope, event: selectedEvent)
                default: _ = try await service.loadEntities(scope: selectedScope, event: selectedEvent)
                }
            }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    private func arn(_ id: String, region: String = "us-east-1", account: String = "", partition: String = "aws") -> String {
        "arn:\(partition):health:\(region):\(account):event/EC2/AWS_EC2_MAINTENANCE/\(id)"
    }

    private func entityARN(_ id: String, account: String = "111122223333") -> String {
        "arn:aws:health:us-east-1:\(account):entity/\(id)"
    }

    private func rawEvent(_ id: String = "id", arn suppliedARN: String? = nil, eventScope: Health.EventScopeCode? = .accountSpecific) -> Health.Event {
        .init(arn: suppliedARN ?? arn(id), eventScopeCode: eventScope, eventTypeCategory: .scheduledChange,
              eventTypeCode: "AWS_EC2_MAINTENANCE", region: "us-east-1", service: "EC2", statusCode: .open)
    }

    private func event(_ id: String = "id") -> HealthEvent {
        .init(arn: arn(id), service: "EC2", typeCode: "AWS_EC2_MAINTENANCE", category: "scheduledChange", status: "open", region: "us-east-1")
    }

    private func entity(_ id: String) -> Health.AffectedEntity {
        .init(awsAccountId: "111122223333", entityArn: entityARN(id), entityValue: "i-\(id)", eventArn: arn("id"))
    }

    private func scope(account: String = "111122223333", principal: String? = nil, profile: String = "work", partition: String = "aws") -> HealthScope {
        HealthScope(
            profile: AWSProfile(name: profile, region: "ap-southeast-1", ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
            identity: AWSIdentity(account: account, arn: principal ?? "arn:\(partition):sts::\(account):assumed-role/Test/session", userID: "example"),
            paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/config", "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials"])
        )
    }

    private func service(_ stub: HealthStub) -> AWSHealthService {
        AWSHealthService(eventLoader: { try await stub.events($0) }, detailLoader: { try await stub.details($0) },
                         entityLoader: { try await stub.entities($0) })
    }

    private func assertError<E: Error & Equatable>(
        _ expected: E, file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("private-token-error"), file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("secret request payload"), file: file, line: line)
        }
    }
}

private actor HealthStub {
    private var eventPages: [Health.DescribeEventsResponse]
    private let detailResponse: Health.DescribeEventDetailsResponse
    private var entityPages: [Health.DescribeAffectedEntitiesResponse]
    private let failure: Error?
    private var eventRequests: [Health.DescribeEventsRequest] = []
    private var detailRequests: [Health.DescribeEventDetailsRequest] = []
    private var entityRequests: [Health.DescribeAffectedEntitiesRequest] = []

    init(eventPages: [Health.DescribeEventsResponse] = [], detailResponse: Health.DescribeEventDetailsResponse = .init(),
         entityPages: [Health.DescribeAffectedEntitiesResponse] = [], failure: Error? = nil) {
        self.eventPages = eventPages
        self.detailResponse = detailResponse
        self.entityPages = entityPages
        self.failure = failure
    }

    func events(_ request: Health.DescribeEventsRequest) throws -> Health.DescribeEventsResponse {
        eventRequests.append(request)
        if let failure { throw failure }
        guard !eventPages.isEmpty else { throw HealthError.invalidResponse }
        return eventPages.removeFirst()
    }

    func details(_ request: Health.DescribeEventDetailsRequest) throws -> Health.DescribeEventDetailsResponse {
        detailRequests.append(request)
        if let failure { throw failure }
        return detailResponse
    }

    func entities(_ request: Health.DescribeAffectedEntitiesRequest) throws -> Health.DescribeAffectedEntitiesResponse {
        entityRequests.append(request)
        if let failure { throw failure }
        guard !entityPages.isEmpty else { throw HealthError.invalidResponse }
        return entityPages.removeFirst()
    }

    func requests() -> (events: [Health.DescribeEventsRequest], details: [Health.DescribeEventDetailsRequest], entities: [Health.DescribeAffectedEntitiesRequest]) {
        (eventRequests, detailRequests, entityRequests)
    }
}
