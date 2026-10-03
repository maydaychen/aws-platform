import XCTest
@testable import AWSPlatform

@MainActor
final class SNSRelationshipViewModelTests: XCTestCase {
    func testEmptyScopeNeverQueriesAndClearsPreviouslyLoadedData() async {
        let probe = RelationshipProbe()
        let vm = makeViewModel(probe)
        let scope = relationshipScope()
        let topic = relationshipTopic("main", scope: scope)
        vm.load(scope: nil, topic: topic)
        vm.refresh()
        await vm.waitForLoad()
        var calls = await probe.count()
        XCTAssertEqual(calls, 0)
        vm.load(scope: scope, topic: topic)
        await vm.waitForLoad()
        XCTAssertFalse(vm.sources.isEmpty)
        vm.load(scope: nil, topic: topic)
        XCTAssertNil(vm.scope)
        XCTAssertNil(vm.topic)
        XCTAssertTrue(vm.sources.isEmpty)
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertFalse(vm.isLoading)
        calls = await probe.count()
        XCTAssertEqual(calls, 1)
    }

    func testSameScopeAndTopicLoadOnceAndExplicitRefreshRequestsAgain() async {
        let gate = TestGate()
        let probe = RelationshipProbe(firstGate: gate)
        let vm = makeViewModel(probe)
        let scope = relationshipScope()
        let topic = relationshipTopic("main", scope: scope)
        vm.load(scope: scope, topic: topic)
        await gate.waitForEntry()
        vm.load(scope: scope, topic: topic)
        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.hasLoaded)
        await gate.open()
        await vm.waitForLoad()
        vm.load(scope: scope, topic: topic)
        var calls = await probe.count()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(vm.hasLoaded)
        XCTAssertEqual(vm.sources.map(\.alarm.name), ["main-source-1"])
        vm.refresh()
        XCTAssertTrue(vm.sources.isEmpty, "Old links are cleared while a fresh upstream check runs")
        await vm.waitForLoad()
        calls = await probe.count()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(vm.sources.map(\.alarm.name), ["main-source-2"])
    }

    func testEmptySuccessfulScanIsDifferentFromFailedIncompleteScan() async {
        let probe = RelationshipProbe(empty: true)
        let vm = makeViewModel(probe)
        let scope = relationshipScope()
        vm.load(scope: scope, topic: relationshipTopic("main", scope: scope))
        await vm.waitForLoad()
        XCTAssertTrue(vm.hasLoaded)
        XCTAssertTrue(vm.sources.isEmpty)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isLoading)
    }

    func testFailedRefreshClearsSourcesAndDoesNotAutoRetryOnReentry() async {
        let probe = RelationshipProbe(failures: [2])
        let vm = makeViewModel(probe)
        let scope = relationshipScope()
        let topic = relationshipTopic("main", scope: scope)
        vm.load(scope: scope, topic: topic)
        await vm.waitForLoad()
        XCTAssertFalse(vm.sources.isEmpty)
        vm.refresh()
        await vm.waitForLoad()
        XCTAssertTrue(vm.sources.isEmpty)
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertTrue(vm.error?.contains("incomplete") == true)
        vm.load(scope: scope, topic: topic)
        let failedCalls = await probe.count()
        XCTAssertEqual(failedCalls, 2)
        vm.refresh()
        await vm.waitForLoad()
        XCTAssertTrue(vm.hasLoaded)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.sources.isEmpty)
    }

    func testUntrustedErrorAndNetworkURLAreNeverDisplayed() async {
        for failure in [RelationshipTestFailure.unsafe, .raw, .network] {
            let vm = SNSRelationshipViewModel(loader: { _ in try failure.result() })
            let scope = relationshipScope()
            vm.load(scope: scope, topic: relationshipTopic("main", scope: scope))
            await vm.waitForLoad()
            XCTAssertFalse(vm.hasLoaded)
            XCTAssertTrue(vm.error?.contains("incomplete") == true)
            XCTAssertFalse(vm.error?.contains("endpoint-private") == true)
            XCTAssertTrue(vm.sources.isEmpty)
        }
    }

    func testWhitelistedPermissionPaginationAndCancellationErrorsStayUseful() async {
        let errors: [(RelationshipTestFailure, String)] = [
            (.permission, "cloudwatch:DescribeAlarms"),
            (.pagination, "complete alarm result"),
            (.cancelled, "cancelled")
        ]
        for (failure, expected) in errors {
            let vm = SNSRelationshipViewModel(loader: { _ in try failure.result() })
            let scope = relationshipScope()
            vm.load(scope: scope, topic: relationshipTopic("main", scope: scope))
            await vm.waitForLoad()
            XCTAssertTrue(vm.error?.contains(expected) == true)
            XCTAssertFalse(vm.hasLoaded)
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testTopicChangeClearsAndLoadsItsOwnRelationships() async {
        let probe = RelationshipProbe()
        let vm = makeViewModel(probe)
        let scope = relationshipScope()
        vm.load(scope: scope, topic: relationshipTopic("main", scope: scope))
        await vm.waitForLoad()
        vm.load(scope: scope, topic: relationshipTopic("secondary", scope: scope))
        XCTAssertTrue(vm.sources.isEmpty)
        await vm.waitForLoad()
        XCTAssertEqual(vm.sources.map(\.alarm.name), ["secondary-source-2"])
        XCTAssertEqual(vm.topic?.name, "secondary")
        let calls = await probe.count()
        XCTAssertEqual(calls, 2)
    }

    func testProfilePrincipalRegionAccountAndPathsAreSeparateContexts() async {
        let probe = RelationshipProbe()
        let vm = makeViewModel(probe)
        let scopes = [
            relationshipScope(), relationshipScope(profile: "other"), relationshipScope(role: "AnotherRole"),
            relationshipScope(region: "eu-west-1"), relationshipScope(account: "444455556666"),
            relationshipScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/other-config"])),
            relationshipScope(paths: AWSConfigurationPaths(environment: ["AWS_SHARED_CREDENTIALS_FILE": "/tmp/other-credentials"]))
        ]
        for scope in scopes {
            let topic = relationshipTopic("main", scope: scope)
            vm.load(scope: scope, topic: topic)
            XCTAssertTrue(vm.sources.isEmpty)
            await vm.waitForLoad()
            XCTAssertTrue(vm.hasLoaded)
            XCTAssertEqual(vm.sources.first?.target.scope, scope)
            vm.load(scope: scope, topic: topic)
        }
        let calls = await probe.count()
        XCTAssertEqual(calls, scopes.count)
    }

    func testLateOldScopeSuccessOrErrorCannotPublish() async {
        for shouldFail in [false, true] {
            let gate = TestGate()
            let probe = RelationshipProbe(firstGate: gate, failures: shouldFail ? [1] : [])
            let vm = makeViewModel(probe)
            let firstScope = relationshipScope()
            vm.load(scope: firstScope, topic: relationshipTopic("main", scope: firstScope))
            await gate.waitForEntry()
            let waiting = Task { await vm.waitForLoad() }
            await Task.yield()
            let nextScope = relationshipScope(profile: "other", region: "eu-west-1")
            vm.load(scope: nextScope, topic: relationshipTopic("secondary", scope: nextScope))
            await vm.waitForLoad()
            await gate.open()
            await waiting.value
            XCTAssertEqual(vm.scope, nextScope)
            XCTAssertEqual(vm.sources.map(\.alarm.name), ["secondary-source-2"])
            XCTAssertTrue(vm.hasLoaded)
            XCTAssertFalse(vm.isLoading)
            XCTAssertNil(vm.error)
        }
    }

    func testLateOldTopicSuccessOrErrorCannotPublish() async {
        for shouldFail in [false, true] {
            let gate = TestGate()
            let probe = RelationshipProbe(firstGate: gate, failures: shouldFail ? [1] : [])
            let vm = makeViewModel(probe)
            let scope = relationshipScope()
            vm.load(scope: scope, topic: relationshipTopic("main", scope: scope))
            await gate.waitForEntry()
            let waiting = Task { await vm.waitForLoad() }
            await Task.yield()
            vm.load(scope: scope, topic: relationshipTopic("secondary", scope: scope))
            await vm.waitForLoad()
            await gate.open()
            await waiting.value
            XCTAssertEqual(vm.sources.map(\.alarm.name), ["secondary-source-2"])
            XCTAssertNil(vm.error)
            XCTAssertTrue(vm.hasLoaded)
        }
    }

    func testResetInvalidatesCancelledLoaderThatStillReturnsOrThrows() async {
        for shouldFail in [false, true] {
            let gate = TestGate()
            let probe = RelationshipProbe(firstGate: gate, failures: shouldFail ? [1] : [])
            let vm = makeViewModel(probe)
            let scope = relationshipScope()
            vm.load(scope: scope, topic: relationshipTopic("main", scope: scope))
            await gate.waitForEntry()
            let waiting = Task { await vm.waitForLoad() }
            await Task.yield()
            vm.reset()
            await gate.open()
            await waiting.value
            XCTAssertNil(vm.scope)
            XCTAssertNil(vm.topic)
            XCTAssertTrue(vm.sources.isEmpty)
            XCTAssertFalse(vm.hasLoaded)
            XCTAssertFalse(vm.isLoading)
            XCTAssertNil(vm.error)
        }
    }

    func testRefreshInvalidatesSameScopeOlderRequest() async {
        let gate = TestGate()
        let probe = RelationshipProbe(firstGate: gate, failures: [1])
        let vm = makeViewModel(probe)
        let scope = relationshipScope()
        vm.load(scope: scope, topic: relationshipTopic("main", scope: scope))
        await gate.waitForEntry()
        let waiting = Task { await vm.waitForLoad() }
        await Task.yield()
        vm.refresh()
        await vm.waitForLoad()
        await gate.open()
        await waiting.value
        XCTAssertEqual(vm.sources.map(\.alarm.name), ["main-source-2"])
        XCTAssertNil(vm.error)
        XCTAssertTrue(vm.hasLoaded)
    }

    func testFailedUpstreamDoesNotAlterExistingSNSSubscriptions() async {
        let scope = relationshipScope()
        let topic = relationshipTopic("main", scope: scope)
        let subscription = SNSSubscription(id: "pending", arn: "PendingConfirmation", protocolName: "email",
                                           endpoint: "example@example.invalid", topicARN: topic.arn, status: "Pending confirmation")
        let snsVM = SNSViewModel(listLoader: { _ in [topic] }, attributeLoader: { _, _ in [:] },
                                tagLoader: { _, _ in [:] }, subscriptionLoader: { _, _ in [subscription] })
        snsVM.configure(scope: scope)
        await snsVM.loadTopics()
        snsVM.selectedTopic = topic
        await snsVM.waitForDetails()
        let vm = SNSRelationshipViewModel(loader: { _ in throw AWSAlarmService.RequestError.listPermission })
        vm.load(scope: scope, topic: topic)
        await vm.waitForLoad()
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(snsVM.subscriptions, [subscription])
        XCTAssertNil(snsVM.subscriptionsError)
        XCTAssertEqual(snsVM.selectedTopic, topic)
    }

    private func makeViewModel(_ probe: RelationshipProbe) -> SNSRelationshipViewModel {
        SNSRelationshipViewModel(loader: { try await probe.load($0) })
    }
}

private func relationshipScope(
    profile: String = "work", role: String = "ReadOnly", region: String = "us-east-1", account: String = "111122223333",
    paths: AWSConfigurationPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/relationship-config"])
) -> SNSScope {
    SNSScope(
        profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
        identity: AWSIdentity(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/test", userID: "test"),
        region: region, paths: paths
    )
}

private func relationshipTopic(_ name: String, scope: SNSScope) -> SNSTopic {
    SNSTopic(arn: "arn:aws:sns:\(scope.region):\(scope.accountID):\(name)", name: name)
}

private actor RelationshipProbe {
    private var calls = 0
    private let firstGate: TestGate?
    private let failures: Set<Int>
    private let empty: Bool

    init(firstGate: TestGate? = nil, failures: Set<Int> = [], empty: Bool = false) {
        self.firstGate = firstGate
        self.failures = failures
        self.empty = empty
    }

    func count() -> Int { calls }

    func load(_ scope: SNSScope) async throws -> [CloudWatchAlarm] {
        calls += 1
        let call = calls
        if call == 1 { await firstGate?.wait() }
        if failures.contains(call) { throw AlarmError.incompletePagination }
        if empty { return [] }
        return ["main", "secondary"].map { topicName in
            let name = "\(topicName)-source-\(call)"
            return CloudWatchAlarm(
                arn: "arn:aws:cloudwatch:\(scope.region):\(scope.accountID):alarm:\(name)", name: name,
                kind: .metric, state: "ALARM", actionsEnabled: true,
                alarmActions: [relationshipTopic(topicName, scope: scope).arn]
            )
        }
    }
}

private struct UnsafeRelationshipError: LocalizedError {
    var errorDescription: String? { "endpoint-private@example.invalid" }
}

private enum RelationshipTestFailure: Sendable {
    case unsafe, raw, network, permission, pagination, cancelled

    func result() throws -> [CloudWatchAlarm] {
        switch self {
        case .unsafe: throw UnsafeRelationshipError()
        case .raw:
            throw NSError(domain: "endpoint-private@example.invalid", code: 123,
                          userInfo: [NSLocalizedDescriptionKey: "endpoint-private@example.invalid"])
        case .network:
            throw URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://endpoint-private.example.invalid/path"])
        case .permission: throw AWSAlarmService.RequestError.listPermission
        case .pagination: throw AlarmError.incompletePagination
        case .cancelled: throw CancellationError()
        }
    }
}
