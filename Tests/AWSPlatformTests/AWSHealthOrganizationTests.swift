import Foundation
import SotoCore
import SotoHealth
import XCTest
@testable import AWSPlatform

final class AWSHealthOrganizationTests: XCTestCase {
    func testOrganizationPaginationExcludesPublicEventsAndFiltersAtAWS() async throws {
        let probe = OrganizationHealthProbe()
        let service = AWSHealthService(organizationOperations: probe.operations)
        var scope = organizationHealthScope()
        scope.organizationAccountFilter = "444455556666"
        let events = try await service.loadEvents(scope: scope)
        XCTAssertEqual(events.map(\.arn), [organizationHealthEvent().arn])
        let requests = await probe.eventRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.filter?.awsAccountIds }, [["444455556666"], ["444455556666"]])
        XCTAssertEqual(requests.last?.nextToken, "page2")
        XCTAssertEqual(requests.first?.maxResults, 100)
        XCTAssertNil(events.first?.affectedAccountID)
    }

    func testAffectedAccountsPaginateDeduplicateAndSort() async throws {
        let probe = OrganizationHealthProbe()
        let service = AWSHealthService(organizationOperations: probe.operations)
        let accounts = try await service.loadAffectedAccounts(scope: organizationHealthScope(), event: organizationHealthEvent())
        XCTAssertEqual(accounts, ["444455556666", "777788889999"])
        let requests = await probe.accountRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.eventArn, organizationHealthEvent().arn)
    }

    func testMalformedAccountAndForeignEventCannotProduceAffectedAccountChoices() async {
        let probe = OrganizationHealthProbe()
        var operations = probe.operations
        operations.accounts = { _ in .init(affectedAccounts: ["invalid"], eventScopeCode: .accountSpecific) }
        let service = AWSHealthService(organizationOperations: operations)
        do { _ = try await service.loadAffectedAccounts(scope: organizationHealthScope(), event: organizationHealthEvent()); XCTFail("Malformed account accepted") }
        catch { XCTAssertEqual(error as? HealthError, .invalidResponse) }
        let foreign = HealthEvent(arn: "arn:aws-cn:health:cn-northwest-1::event/EC2/AWS_EC2_MAINTENANCE/id", service: "EC2",
                                  typeCode: "AWS_EC2_MAINTENANCE", category: "scheduledChange", status: "upcoming", region: "cn-northwest-1")
        do { _ = try await service.loadAffectedAccounts(scope: organizationHealthScope(), event: foreign); XCTFail("Foreign partition accepted") }
        catch { XCTAssertEqual(error as? HealthError, .invalidResponse) }
    }

    func testContinuationFailureNeverReturnsPartialAffectedAccounts() async {
        let probe = OrganizationHealthProbe()
        var operations = probe.operations
        operations.accounts = { request in
            if request.nextToken != nil { throw AWSResponseError(errorCode: "AccessDeniedException") }
            return .init(affectedAccounts: ["444455556666"], eventScopeCode: .accountSpecific, nextToken: "next")
        }
        let service = AWSHealthService(organizationOperations: operations)
        do { _ = try await service.loadAffectedAccounts(scope: organizationHealthScope(), event: organizationHealthEvent()); XCTFail("Partial accounts accepted") }
        catch { XCTAssertEqual(error as? AWSHealthService.RequestError, .organizationAccountsPermission) }
    }

    func testDetailsAndEntitiesBindMemberAccountWithoutChangingCallerProfile() async throws {
        let probe = OrganizationHealthProbe()
        let service = AWSHealthService(organizationOperations: probe.operations)
        var event = organizationHealthEvent()
        event.affectedAccountID = "444455556666"
        let scope = organizationHealthScope()
        let details = try await service.loadDetails(scope: scope, event: event)
        let entities = try await service.loadEntities(scope: scope, event: event)
        XCTAssertEqual(details.event.affectedAccountID, event.affectedAccountID)
        XCTAssertEqual(details.description, "Member maintenance")
        XCTAssertEqual(entities.map(\.accountID), ["444455556666", "444455556666"])
        let detailRequest = await probe.detailRequests.first
        let entityRequests = await probe.entityRequests
        XCTAssertEqual(detailRequest?.organizationEventDetailFilters.first?.awsAccountId, event.affectedAccountID)
        XCTAssertEqual(entityRequests.first?.organizationEntityAccountFilters?.first?.awsAccountId, event.affectedAccountID)
        XCTAssertEqual(entityRequests.last?.nextToken, "page2")
        XCTAssertEqual(scope.profileName, "management")
        XCTAssertEqual(scope.accountID, "111122223333")
    }

    func testInvalidAccountFilterAndMissingDetailAccountNeverCallAWS() async {
        let probe = OrganizationHealthProbe()
        let service = AWSHealthService(organizationOperations: probe.operations)
        var scope = organizationHealthScope()
        for value in ["123", "１２３４５６７８９０１２", "44445555666x"] {
            scope.organizationAccountFilter = value
            do { _ = try await service.loadEvents(scope: scope); XCTFail("Invalid filter accepted") }
            catch { XCTAssertEqual(error as? HealthError, .invalidAccountFilter) }
        }
        scope.organizationAccountFilter = nil
        do { _ = try await service.loadDetails(scope: scope, event: organizationHealthEvent()); XCTFail("Missing account accepted") }
        catch { XCTAssertEqual(error as? HealthError, .invalidScope) }
        do { _ = try await service.loadEntities(scope: scope, event: organizationHealthEvent()); XCTFail("Missing account accepted") }
        catch { XCTAssertEqual(error as? HealthError, .invalidScope) }
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0, 0])
    }

    func testRepeatedTokensNeverReturnPartialLists() async {
        for operation in 0..<3 {
            let probe = OrganizationHealthProbe(repeatTokens: true)
            let service = AWSHealthService(organizationOperations: probe.operations)
            var event = organizationHealthEvent()
            event.affectedAccountID = "444455556666"
            do {
                switch operation {
                case 0: _ = try await service.loadEvents(scope: organizationHealthScope())
                case 1: _ = try await service.loadAffectedAccounts(scope: organizationHealthScope(), event: event)
                default: _ = try await service.loadEntities(scope: organizationHealthScope(), event: event)
                }
                XCTFail("Partial result returned")
            } catch { XCTAssertEqual(error as? HealthError, .incompletePagination) }
        }
    }

    func testMismatchedDetailAndResourceAccountsAreRejected() async {
        let probe = OrganizationHealthProbe()
        var operations = probe.operations
        operations.details = { _ in .init(successfulSet: [.init(awsAccountId: "777788889999", event: organizationRawEvent())]) }
        operations.entities = { _ in .init(entities: [.init(awsAccountId: "777788889999", entityArn: "arn:aws:health:us-east-1:777788889999:entity/id", eventArn: organizationHealthEvent().arn)]) }
        let service = AWSHealthService(organizationOperations: operations)
        var event = organizationHealthEvent()
        event.affectedAccountID = "444455556666"
        do { _ = try await service.loadDetails(scope: organizationHealthScope(), event: event); XCTFail("Foreign details accepted") }
        catch { XCTAssertEqual(error as? HealthError, .invalidResponse) }
        do { _ = try await service.loadEntities(scope: organizationHealthScope(), event: event); XCTFail("Foreign entities accepted") }
        catch { XCTAssertEqual(error as? HealthError, .invalidResponse) }
    }

    func testFailedSetsAreSanitizedAndDoNotReturnPartialResources() async {
        let probe = OrganizationHealthProbe()
        var operations = probe.operations
        operations.details = { _ in .init(failedSet: [.init(awsAccountId: "444455556666", errorMessage: "SECRET", errorName: "AccessDeniedException", eventArn: organizationHealthEvent().arn)]) }
        operations.entities = { _ in .init(entities: [.init(entityValue: "partial")], failedSet: [.init(awsAccountId: "444455556666", errorMessage: "SECRET", errorName: "AccessDeniedException", eventArn: organizationHealthEvent().arn)]) }
        let service = AWSHealthService(organizationOperations: operations)
        var event = organizationHealthEvent()
        event.affectedAccountID = "444455556666"
        do { _ = try await service.loadDetails(scope: organizationHealthScope(), event: event); XCTFail("Failed details returned") }
        catch { XCTAssertEqual(error as? AWSHealthService.RequestError, .organizationDetailPermission) }
        do { _ = try await service.loadEntities(scope: organizationHealthScope(), event: event); XCTFail("Partial resources returned") }
        catch { XCTAssertEqual(error as? AWSHealthService.RequestError, .organizationEntitiesPermission) }
    }

    func testOrganizationPermissionsSupportAndSetupFailuresRemainActionable() async {
        let cases: [(String, AWSHealthService.RequestError)] = [
            ("AccessDeniedException", .organizationListPermission), ("SubscriptionRequiredException", .subscriptionRequired),
            ("HealthServiceAccessNotEnabledException", .organizationUnavailable), ("AWSOrganizationsNotInUseException", .organizationUnavailable)
        ]
        for (code, expected) in cases {
            let probe = OrganizationHealthProbe()
            var operations = probe.operations
            operations.events = { _ in throw AWSResponseError(errorCode: code) }
            let service = AWSHealthService(organizationOperations: operations)
            do { _ = try await service.loadEvents(scope: organizationHealthScope()); XCTFail("Expected error") }
            catch {
                XCTAssertEqual(error as? AWSHealthService.RequestError, expected)
                XCTAssertFalse(error.localizedDescription.contains("SECRET"))
            }
        }
    }

    func testCancelledQueriesNeverReachLoader() async {
        let probe = OrganizationHealthProbe()
        let service = AWSHealthService(organizationOperations: probe.operations)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.loadEvents(scope: organizationHealthScope())
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0, 0])
    }
}

func organizationHealthScope(profile: String = "management") -> HealthScope {
    var scope = HealthScope(
        profile: AWSProfile(name: profile, region: "eu-west-1", ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
        identity: AWSIdentity(account: "111122223333", arn: "arn:aws:sts::111122223333:assumed-role/ReadOnly/test", userID: "test"),
        paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/mock-health-config", "AWS_SHARED_CREDENTIALS_FILE": "/tmp/mock-health-credentials"])
    )
    scope.queryMode = .organization
    return scope
}

func organizationHealthEvent(status: String = "upcoming") -> HealthEvent {
    HealthEvent(arn: "arn:aws:health:us-east-1::event/EC2/AWS_EC2_MAINTENANCE/id", service: "EC2", typeCode: "AWS_EC2_MAINTENANCE", category: "scheduledChange", status: status, region: "us-east-1")
}

func organizationRawEvent() -> Health.Event {
    .init(arn: organizationHealthEvent().arn, eventScopeCode: .accountSpecific, eventTypeCategory: .scheduledChange,
          eventTypeCode: "AWS_EC2_MAINTENANCE", region: "us-east-1", service: "EC2", statusCode: .upcoming)
}

private actor OrganizationHealthProbe {
    var eventRequests: [Health.DescribeEventsForOrganizationRequest] = []
    var accountRequests: [Health.DescribeAffectedAccountsForOrganizationRequest] = []
    var detailRequests: [Health.DescribeEventDetailsForOrganizationRequest] = []
    var entityRequests: [Health.DescribeAffectedEntitiesForOrganizationRequest] = []
    let repeatTokens: Bool

    init(repeatTokens: Bool = false) { self.repeatTokens = repeatTokens }

    nonisolated var operations: AWSHealthService.OrganizationOperations {
        .init(events: { try await self.events($0) }, accounts: { try await self.accounts($0) },
              details: { try await self.details($0) }, entities: { try await self.entities($0) })
    }

    func counts() -> [Int] { [eventRequests.count, accountRequests.count, detailRequests.count, entityRequests.count] }

    func events(_ request: Health.DescribeEventsForOrganizationRequest) throws -> Health.DescribeEventsForOrganizationResponse {
        eventRequests.append(request)
        if repeatTokens { return .init(events: [], nextToken: "repeat") }
        if request.nextToken == nil { return .init(events: [.init(arn: "public", eventScopeCode: .public)], nextToken: "page2") }
        return .init(events: [.init(arn: organizationHealthEvent().arn, eventScopeCode: .accountSpecific,
                                   eventTypeCategory: .scheduledChange, eventTypeCode: "AWS_EC2_MAINTENANCE",
                                   region: "us-east-1", service: "EC2", statusCode: .upcoming)])
    }

    func accounts(_ request: Health.DescribeAffectedAccountsForOrganizationRequest) throws -> Health.DescribeAffectedAccountsForOrganizationResponse {
        accountRequests.append(request)
        if repeatTokens { return .init(affectedAccounts: [], eventScopeCode: .accountSpecific, nextToken: "repeat") }
        return request.nextToken == nil
            ? .init(affectedAccounts: ["777788889999"], eventScopeCode: .accountSpecific, nextToken: "page2")
            : .init(affectedAccounts: ["444455556666", "777788889999"], eventScopeCode: .accountSpecific)
    }

    func details(_ request: Health.DescribeEventDetailsForOrganizationRequest) throws -> Health.DescribeEventDetailsForOrganizationResponse {
        detailRequests.append(request)
        return .init(successfulSet: [.init(awsAccountId: request.organizationEventDetailFilters.first?.awsAccountId,
                                           event: organizationRawEvent(), eventDescription: .init(latestDescription: "Member maintenance"))])
    }

    func entities(_ request: Health.DescribeAffectedEntitiesForOrganizationRequest) throws -> Health.DescribeAffectedEntitiesForOrganizationResponse {
        entityRequests.append(request)
        if repeatTokens { return .init(entities: [], nextToken: "repeat") }
        let id = request.nextToken == nil ? "first" : "second"
        return .init(entities: [.init(awsAccountId: "444455556666", entityArn: "arn:aws:health:us-east-1:444455556666:entity/\(id)",
                                      entityValue: "i-\(id)", eventArn: organizationHealthEvent().arn)],
                     nextToken: request.nextToken == nil ? "page2" : nil)
    }
}
