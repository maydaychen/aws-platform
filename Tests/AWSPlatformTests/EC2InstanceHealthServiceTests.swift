import Foundation
import SotoCore
import SotoEC2
import XCTest
@testable import AWSPlatform

final class EC2InstanceHealthServiceTests: XCTestCase {
    func testScanFollowsEmptyAndPopulatedPagesAndIgnoresForeignInstances() async throws {
        let probe = HealthProbe { request, _ in
            switch request.nextToken {
            case nil: return .init(instanceStatuses: [Self.status("i-first"), Self.status("i-foreign")], nextToken: "empty")
            case "empty": return .init(instanceStatuses: [], nextToken: "last")
            default: return .init(instanceStatuses: [Self.status("i-second")])
            }
        }
        let result = try await probe.service.load(instanceIds: ["i-first", "i-second"])
        XCTAssertEqual(result.health.keys.sorted(), ["i-first", "i-second"])
        XCTAssertTrue(result.errors.isEmpty)
        let requests = await probe.requests
        XCTAssertEqual(requests.map(\.nextToken), [nil, "empty", "last"])
        XCTAssertTrue(requests.allSatisfy { $0.includeAllInstances == true && $0.maxResults == 100 && $0.instanceIds == nil })
    }

    func testMissingInstanceIsRecoveredOnceWithoutFetchingOtherDetails() async throws {
        let probe = HealthProbe { request, _ in
            if let ids = request.instanceIds {
                XCTAssertEqual(ids, ["i-second"])
                XCTAssertNil(request.maxResults)
                XCTAssertNil(request.nextToken)
                return .init(instanceStatuses: [Self.status("i-second"), Self.status("i-foreign")])
            }
            return .init(instanceStatuses: [Self.status("i-first")])
        }
        let result = try await probe.service.load(instanceIds: ["i-first", "i-second"])
        XCTAssertEqual(result.health.count, 2)
        XCTAssertTrue(result.errors.isEmpty)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testLaterPageFailureKeepsSuccessfulPageAndOnlyRetriesMissingIDs() async throws {
        let probe = HealthProbe { request, _ in
            if request.instanceIds != nil { return .init(instanceStatuses: [Self.status("i-second")]) }
            if request.nextToken != nil { throw AWSResponseError(errorCode: "AccessDenied") }
            return .init(instanceStatuses: [Self.status("i-first")], nextToken: "next")
        }
        let result = try await probe.service.load(instanceIds: ["i-first", "i-second"])
        XCTAssertEqual(result.health.count, 2)
        XCTAssertTrue(result.errors.isEmpty)
        let requests = await probe.requests
        XCTAssertEqual(requests.last?.instanceIds, ["i-second"])
        XCTAssertEqual(requests.count, 3)
    }

    func testRecoveryIsBatchedAt100AndFailureDoesNotDiscardOtherBatches() async throws {
        let ids = (0..<251).map { "i-\($0)" }
        let probe = HealthProbe { request, index in
            guard let requested = request.instanceIds else { throw URLError(.notConnectedToInternet) }
            XCTAssertLessThanOrEqual(requested.count, 100)
            XCTAssertNil(request.maxResults)
            XCTAssertNil(request.nextToken)
            if index == 2 { throw EC2HealthTestAWSFailure("AccessDenied") }
            return .init(instanceStatuses: requested.map(Self.status))
        }
        let result = try await probe.service.load(instanceIds: ids)
        XCTAssertEqual(result.health.count, 151)
        XCTAssertEqual(result.errors.count, 100)
        XCTAssertTrue(result.errors.values.allSatisfy { $0.contains("permission denied") && !$0.contains("SENSITIVE_DETAIL") })
        let requests = await probe.requests
        XCTAssertEqual(requests.compactMap { $0.instanceIds?.count }, [100, 100, 51])
        XCTAssertEqual(requests.count, 4)
    }

    func testMissingRecordAfterRecoveryIsExplicitAndDoesNotRetryAgain() async throws {
        let probe = HealthProbe { _, _ in .init() }
        let result = try await probe.service.load(instanceIds: ["i-first"])
        XCTAssertTrue(result.health.isEmpty)
        XCTAssertEqual(result.errors, ["i-first": EC2InstanceHealthResult.notReturned])
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testMissingCheckFieldsAreRetriedAndRemainErrorsWhileKnownEventsAreKept() async throws {
        let partials: [EC2.InstanceStatus] = [
            .init(instanceId: "i-first"),
            .init(instanceId: "i-first", instanceStatus: .init(status: .ok)),
            .init(instanceId: "i-first", systemStatus: .init(status: .ok)),
            .init(events: [.init(code: .instanceReboot, instanceEventId: "event-1")], instanceId: "i-first")
        ]
        for partial in partials {
            let probe = HealthProbe { _, _ in .init(instanceStatuses: [partial]) }
            let result = try await probe.service.load(instanceIds: ["i-first"])
            XCTAssertEqual(result.errors["i-first"], EC2InstanceHealthResult.notReturned)
            XCTAssertFalse(result.health["i-first"]?.hasStatusChecks ?? true)
            XCTAssertFalse(result.health["i-first"]?.isNotApplicable ?? true)
            XCTAssertEqual(result.health["i-first"]?.events.count, partial.events?.count ?? 0)
            let requests = await probe.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testDuplicateIncompleteStatusCannotReplaceCompleteSuccess() async throws {
        let probe = HealthProbe { _, _ in .init(instanceStatuses: [Self.status("i-first"), .init(instanceId: "i-first")]) }
        let result = try await probe.service.load(instanceIds: ["i-first"])
        XCTAssertEqual(result.health["i-first"]?.summary, "Checks passed")
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testIncompleteRecoveryDoesNotDiscardAlreadyKnownScheduledEvents() async throws {
        let probe = HealthProbe { request, _ in
            let events: [EC2.InstanceStatusEvent] = request.instanceIds == nil ? [.init(code: .instanceReboot, instanceEventId: "event-1")] : []
            return .init(instanceStatuses: [.init(events: events, instanceId: "i-first")])
        }
        let result = try await probe.service.load(instanceIds: ["i-first"])
        XCTAssertEqual(result.health["i-first"]?.events.map(\.eventId), ["event-1"])
        XCTAssertTrue(result.health["i-first"]?.needsAttention == true)
        XCTAssertEqual(result.errors["i-first"], EC2InstanceHealthResult.notReturned)
    }

    func testIncompleteRecoveryDoesNotDiscardAlreadyKnownImpairedCheckFields() async throws {
        let probe = HealthProbe { request, _ in
            if request.instanceIds == nil {
                return .init(instanceStatuses: [.init(attachedEbsStatus: .init(status: .impaired), instanceId: "i-first",
                                                     systemStatus: .init(status: .impaired))])
            }
            return .init(instanceStatuses: [.init(instanceId: "i-first")])
        }
        let result = try await probe.service.load(instanceIds: ["i-first"])
        XCTAssertEqual(result.health["i-first"]?.systemStatus, "impaired")
        XCTAssertEqual(result.health["i-first"]?.attachedEBSStatus, "impaired")
        XCTAssertTrue(result.health["i-first"]?.needsAttention == true)
        XCTAssertEqual(result.errors["i-first"], EC2InstanceHealthResult.notReturned)
    }

    func testLoopAndWhitespaceTokensStopScanThenRecoverMissingInstances() async throws {
        for token in ["loop", " ", "\t"] {
            let probe = HealthProbe { request, _ in
                if request.instanceIds != nil { return .init(instanceStatuses: [Self.status("i-first")]) }
                return .init(nextToken: token)
            }
            let result = try await probe.service.load(instanceIds: ["i-first"])
            XCTAssertEqual(result.health["i-first"]?.summary, "Checks passed")
            XCTAssertTrue(result.errors.isEmpty)
            let requests = await probe.requests
            XCTAssertLessThanOrEqual(requests.count, 3)
        }
    }

    func testPageBudgetIsBoundedBeforeSingleRecoveryPass() async throws {
        let probe = HealthProbe { request, index in
            if request.instanceIds != nil { return .init(instanceStatuses: [Self.status("i-first")]) }
            return .init(nextToken: "page-\(index)")
        }
        let result = try await probe.service.load(instanceIds: ["i-first"])
        XCTAssertEqual(result.health["i-first"]?.summary, "Checks passed")
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1_001)
        XCTAssertEqual(requests.filter { $0.instanceIds != nil }.count, 1)
    }

    func testEmptyAndDuplicateInputDoNotCauseUnboundedOrUnnecessaryCalls() async throws {
        let probe = HealthProbe { request, _ in
            if request.instanceIds != nil { XCTAssertEqual(request.instanceIds, ["i-first"]) }
            return .init()
        }
        let empty = try await probe.service.load(instanceIds: [])
        XCTAssertTrue(empty.health.isEmpty)
        XCTAssertTrue(empty.errors.isEmpty)
        let emptyRequests = await probe.requests
        XCTAssertTrue(emptyRequests.isEmpty)
        _ = try await probe.service.load(instanceIds: ["i-first", "i-first"])
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testPermanentFailureCategoriesAreSanitized() async throws {
        let cases: [(Error, String)] = [
            (EC2HealthTestAWSFailure("UnauthorizedOperation"), "AWS permission denied. Check the selected profile and IAM permissions."),
            (EC2HealthTestAWSFailure("ExpiredToken"), "AWS credentials are unavailable or invalid. Check `~/.aws/config` and `~/.aws/credentials`."),
            (EC2HealthTestAWSFailure("RequestLimitExceeded"), "AWS API rate limit reached. Wait a moment and retry."),
            (URLError(.notConnectedToInternet), "Unable to connect to AWS. Check your network, proxy and endpoint settings, then retry."),
            (NSError(domain: "SENSITIVE_DETAIL", code: 1), "Unable to load EC2 status checks.")
        ]
        for (error, expected) in cases {
            let probe = HealthProbe { _, _ in throw error }
            let result = try await probe.service.load(instanceIds: ["i-first"])
            XCTAssertEqual(result.errors, ["i-first": expected])
            XCTAssertTrue(result.health.isEmpty)
        }
    }

    func testCancellationOfLateScanResponseDoesNotRecoverOrReturnStatuses() async {
        let gate = TestGate()
        let probe = HealthProbe { _, _ in .init() }
        let service = EC2InstanceHealthService { request in
            await gate.wait()
            return try await probe.request(request)
        }
        let task = Task { try await service.load(instanceIds: ["i-first"]) }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Cancelled response accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testCancellationDuringRecoveryDoesNotReturnPartialResults() async {
        let gate = TestGate()
        let service = EC2InstanceHealthService { request in
            if request.instanceIds != nil { await gate.wait() }
            return .init(instanceStatuses: [Self.status("i-first")])
        }
        let task = Task { try await service.load(instanceIds: ["i-first", "i-second"]) }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Cancelled recovery accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testDetailUsesOneExactIDAndNeverAccountScanOrOtherInstanceResponse() async throws {
        let probe = HealthProbe { request, _ in
            XCTAssertEqual(request.instanceIds, ["i-selected"])
            XCTAssertTrue(request.includeAllInstances == true)
            XCTAssertNil(request.maxResults)
            XCTAssertNil(request.nextToken)
            return .init(instanceStatuses: [Self.status("i-other"), Self.status("i-selected")])
        }
        let health = try await probe.service.loadDetail(instanceId: "i-selected")
        XCTAssertEqual(health?.summary, "Checks passed")
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testOnlyExplicitNotApplicableIsClassifiedAsNotApplicable() {
        XCTAssertTrue(EC2InstanceHealth(systemStatus: "not-applicable", instanceStatus: "not-applicable", attachedEBSStatus: nil, events: []).isNotApplicable)
        for (system, instance) in [(nil, nil), ("ok", nil), (nil, "ok"), ("", ""), ("not-applicable", nil)] as [(String?, String?)] {
            let health = EC2InstanceHealth(systemStatus: system, instanceStatus: instance, attachedEBSStatus: nil, events: [])
            XCTAssertFalse(health.hasStatusChecks)
            XCTAssertFalse(health.isNotApplicable)
        }
    }

    private static func status(_ id: String) -> EC2.InstanceStatus {
        .init(instanceId: id, instanceStatus: .init(status: .ok), systemStatus: .init(status: .ok))
    }
}

private actor HealthProbe {
    typealias Responder = @Sendable (EC2.DescribeInstanceStatusRequest, Int) throws -> EC2.DescribeInstanceStatusResult
    private let responder: Responder
    private(set) var requests: [EC2.DescribeInstanceStatusRequest] = []
    init(_ responder: @escaping Responder) { self.responder = responder }
    nonisolated var service: EC2InstanceHealthService { .init(statuses: { try await self.request($0) }) }

    func request(_ request: EC2.DescribeInstanceStatusRequest) throws -> EC2.DescribeInstanceStatusResult {
        let index = requests.count
        requests.append(request)
        return try responder(request, index)
    }
}

struct EC2HealthTestAWSFailure: AWSErrorType {
    let errorCode: String
    var context: AWSErrorContext? { nil }
    var description: String { "SENSITIVE_DETAIL" }
    init(_ errorCode: String) { self.errorCode = errorCode }
    init?(errorCode: String, context: AWSErrorContext) { self.errorCode = errorCode }
}
