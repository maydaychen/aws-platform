import XCTest
@testable import AWSPlatform

@MainActor
final class ResourceRelationshipsViewModelTests: XCTestCase {
    func testConfigureIsManualAndNilInvalidAndUnsupportedReferencesMakeNoRequests() async {
        let probe = RelationshipStateProbe()
        let vm = makeVM(probe)
        vm.load()
        vm.refresh()
        vm.scanReverse()
        vm.configure(reference: relationStateReference())
        XCTAssertNil(vm.result)
        var count = await probe.requests().count
        XCTAssertEqual(count, 0)
        for reference in [relationStateReference(account: ""), relationStateReference(resourceID: "bad-instance"),
                          relationStateReference(service: .lambda, resourceID: "arn:aws:lambda:us-east-1:111122223333:function:example")] {
            vm.configure(reference: reference)
            vm.load()
            await vm.waitForLoad()
            XCTAssertNil(vm.result)
            XCTAssertNotNil(vm.error)
        }
        vm.configure(reference: nil)
        vm.load()
        count = await probe.requests().count
        XCTAssertEqual(count, 0)
        XCTAssertNil(vm.reference)
    }

    func testLoadDeduplicatesAndEqualConfigurationPreservesPendingAndLoadedResult() async {
        let gate = TestGate()
        let probe = RelationshipStateProbe(gate: gate)
        let vm = makeVM(probe)
        let reference = relationStateReference()
        vm.configure(reference: reference)
        vm.load()
        await gate.waitForEntry()
        vm.load()
        vm.configure(reference: reference)
        XCTAssertTrue(vm.isLoading)
        await gate.open()
        await vm.waitForLoad()
        let result = vm.result
        XCTAssertNotNil(result)
        vm.configure(reference: reference)
        vm.load()
        await vm.waitForLoad()
        XCTAssertEqual(vm.result, result)
        let count = await probe.requests().count
        XCTAssertEqual(count, 1)
    }

    func testReverseQueriesRequireManualActionAndRefreshPreservesExplicitMode() async {
        let probe = RelationshipStateProbe()
        let vm = makeVM(probe)
        vm.configure(reference: relationStateReference())
        vm.load()
        await vm.waitForLoad()
        vm.refresh()
        await vm.waitForLoad()
        vm.scanReverse()
        await vm.waitForLoad()
        vm.refresh()
        await vm.waitForLoad()
        let requests = await probe.requests()
        XCTAssertEqual(requests.map { $0.1 }, [false, false, true, true])
        XCTAssertTrue(vm.includesReverse)
    }

    func testExploreOnlyKnownSameScopeNodesAndBackRestoresSnapshotWithoutQuery() async throws {
        let probe = RelationshipStateProbe()
        let vm = makeVM(probe)
        let source = relationStateReference()
        vm.configure(reference: source)
        vm.scanReverse()
        await vm.waitForLoad()
        let original = try XCTUnwrap(vm.result)
        let child = try XCTUnwrap(original.sections.first?.nodes.first?.reference)
        vm.explore(reference: relationStateReference(resourceID: "i-87654321"))
        vm.explore(reference: relationStateReference(service: .securityGroups, resourceID: "sg-12345678", region: "us-west-2"))
        vm.explore(reference: relationStateReference(service: .securityGroups, resourceID: "sg-12345678", account: "444455556666"))
        XCTAssertEqual(vm.reference, source)
        vm.explore(reference: child)
        await vm.waitForLoad()
        XCTAssertEqual(vm.reference, child)
        XCTAssertTrue(vm.canGoBack)
        XCTAssertFalse(vm.includesReverse)
        vm.back()
        vm.load()
        await vm.waitForLoad()
        XCTAssertEqual(vm.reference, source)
        XCTAssertEqual(vm.result, original)
        XCTAssertTrue(vm.includesReverse)
        XCTAssertFalse(vm.canGoBack)
        let requests = await probe.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.1 }, [true, false])
    }

    func testDNSRegionQueryIsExplicitSingleRegionAndBackUsesPreviousSnapshot() async throws {
        let probe = RelationshipStateProbe()
        let vm = makeVM(probe)
        let reference = relationStateReference(service: .route53, resourceID: "ZEXAMPLE")
        vm.configure(reference: reference)
        vm.load()
        await vm.waitForLoad()
        let original = try XCTUnwrap(vm.result)
        vm.queryRegion("cn-north-1")
        vm.queryRegion("invalid-region")
        XCTAssertEqual(vm.result, original)
        XCTAssertEqual(vm.reference, reference)
        XCTAssertNotNil(vm.error)
        vm.queryRegion("us-east-1")
        vm.scanReverse()
        var count = await probe.requests().count
        XCTAssertEqual(count, 1)
        vm.queryRegion(" us-west-2 ")
        await vm.waitForLoad()
        XCTAssertEqual(vm.reference?.scope.region, "us-west-2")
        XCTAssertEqual(vm.reference?.scope.profile, reference.scope.profile)
        XCTAssertEqual(vm.reference?.resourceID, reference.resourceID)
        XCTAssertNil(vm.error)
        count = await probe.requests().count
        XCTAssertEqual(count, 2)
        vm.back()
        XCTAssertEqual(vm.result, original)
        XCTAssertEqual(vm.reference, reference)
        vm.configure(reference: relationStateReference())
        vm.queryRegion("us-west-2")
        count = await probe.requests().count
        XCTAssertEqual(count, 2)
    }

    func testChangingOuterIdentityPathsOrRegionClearsHistoryAndNeverLoadsAutomatically() async throws {
        let probe = RelationshipStateProbe()
        let vm = makeVM(probe)
        for changed in [relationStateReference(profile: "other"), relationStateReference(region: "us-west-2"),
                        relationStateReference(account: "444455556666"), relationStateReference(configPath: "/tmp/relations-other-config")] {
            vm.configure(reference: relationStateReference())
            vm.load()
            await vm.waitForLoad()
            let child = try XCTUnwrap(vm.result?.sections.first?.nodes.first?.reference)
            vm.explore(reference: child)
            await vm.waitForLoad()
            XCTAssertTrue(vm.canGoBack)
            let before = await probe.requests().count
            vm.configure(reference: changed)
            XCTAssertEqual(vm.reference, changed)
            XCTAssertNil(vm.result)
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.canGoBack)
            XCTAssertFalse(vm.includesReverse)
            XCTAssertFalse(vm.isLoading)
            let after = await probe.requests().count
            XCTAssertEqual(before, after)
        }
    }

    func testPartialSectionsAndManualScanPlaceholdersArePreservedWithoutClaimingComplete() async {
        let reference = relationStateReference()
        let expected = ResourceRelationResult(reference: reference, sections: [
            .init(id: "partial", title: "Reverse registrations", error: "One group could not be read.", isIncomplete: true, checkedCount: 2, totalCount: 3),
            .init(id: "manual", title: "Optional scan", requiresScan: true)
        ])
        let vm = ResourceRelationshipsViewModel { _, _ in expected }
        vm.configure(reference: reference)
        vm.load()
        await vm.waitForLoad()
        XCTAssertEqual(vm.result, expected)
        XCTAssertNil(vm.error)
        XCTAssertTrue(vm.result?.sections.first?.isIncomplete == true)
        XCTAssertTrue(vm.result?.sections.last?.requiresScan == true)
    }

    func testMismatchedOrDuplicateResultsAreRejected() async {
        let reference = relationStateReference()
        let node = ResourceRelationNode(id: "node", name: "group", relation: "Bound security group")
        let foreign = relationStateReference(service: .securityGroups, resourceID: "sg-12345678", account: "444455556666")
        let wrongRegion = relationStateReference(service: .securityGroups, resourceID: "sg-12345678", region: "us-west-2")
        for result in [ResourceRelationResult(reference: relationStateReference(resourceID: "i-87654321")),
                       ResourceRelationResult(reference: reference, sections: [.init(id: "same", title: "One"), .init(id: "same", title: "Two")]),
                       ResourceRelationResult(reference: reference, sections: [.init(id: "section", title: "Nodes", nodes: [node, node])]),
                       ResourceRelationResult(reference: reference, sections: [.init(id: "section", title: "Nodes", nodes: [.init(id: "foreign", name: "foreign", relation: "invalid", reference: foreign)])]),
                       ResourceRelationResult(reference: reference, sections: [.init(id: "section", title: "Nodes", nodes: [.init(id: "region", name: "wrong region", relation: "invalid", reference: wrongRegion)])])] {
            let vm = ResourceRelationshipsViewModel { _, _ in result }
            vm.configure(reference: reference)
            vm.load()
            await vm.waitForLoad()
            XCTAssertNil(vm.result)
            XCTAssertEqual(vm.error, ResourceRelationError.invalidResource.localizedDescription)
        }
    }

    func testLambdaCanBeOpenedButNeverExplored() async throws {
        let reference = relationStateReference()
        let lambda = relationStateReference(service: .lambda, resourceID: "arn:aws:lambda:us-east-1:111122223333:function:example:live")
        let probe = RelationshipStateProbe()
        let vm = ResourceRelationshipsViewModel { reference, reverse in
            _ = try await probe.load(reference, reverse)
            return ResourceRelationResult(reference: reference, sections: [.init(id: "targets", title: "Targets", nodes: [
                .init(id: "lambda", name: "example:live", relation: "Lambda target", reference: lambda)
            ])])
        }
        vm.configure(reference: reference)
        vm.load()
        await vm.waitForLoad()
        XCTAssertNotNil(vm.result?.sections.first?.nodes.first?.reference)
        vm.explore(reference: lambda)
        XCTAssertEqual(vm.reference, reference)
        let count = await probe.requests().count
        XCTAssertEqual(count, 1)
    }

    func testCancelImmediatelyPreventsLoaderAndUnknownErrorsAreSanitized() async {
        let probe = RelationshipStateProbe()
        let vm = makeVM(probe)
        vm.configure(reference: relationStateReference())
        vm.load()
        vm.cancel()
        await Task.yield()
        let count = await probe.requests().count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNotNil(vm.error)
        let failure = ResourceRelationshipsViewModel { _, _ in throw RelationStateFailure() }
        failure.configure(reference: relationStateReference())
        failure.load()
        await failure.waitForLoad()
        XCTAssertEqual(failure.error, ResourceRelationError.failed.localizedDescription)
        XCTAssertFalse(failure.error?.contains("private-token") == true)
    }

    func testLateSuccessAndFailureCannotCrossResetScopeCancelOrNewRefresh() async {
        for fails in [false, true] {
            for change in ["reset", "scope", "cancel", "refresh"] {
                let gate = TestGate()
                let probe = RelationshipStateProbe(gate: gate, failFirst: fails)
                let vm = makeVM(probe)
                vm.configure(reference: relationStateReference())
                vm.load()
                await gate.waitForEntry()
                let waiter = Task { await vm.waitForLoad() }
                await Task.yield()
                switch change {
                case "reset": vm.reset()
                case "scope":
                    vm.configure(reference: relationStateReference(region: "us-west-2"))
                    vm.load()
                    await vm.waitForLoad()
                case "refresh":
                    vm.refresh()
                    await vm.waitForLoad()
                default: vm.cancel()
                }
                let expectedResult = vm.result
                let expectedError = vm.error
                await gate.open()
                await waiter.value
                XCTAssertEqual(vm.result, expectedResult)
                XCTAssertEqual(vm.error, expectedError)
                XCTAssertFalse(vm.isLoading)
            }
        }
    }

    func testBackDuringExploreCancelsPendingRequestAndRestoresCachedResult() async throws {
        let gate = TestGate()
        let originalReference = relationStateReference()
        let originalResult = relationStateResult(originalReference)
        let vm = ResourceRelationshipsViewModel { reference, _ in
            if reference.service == .securityGroups { await gate.wait(); throw RelationStateFailure() }
            return relationStateResult(reference)
        }
        vm.configure(reference: originalReference)
        vm.load()
        await vm.waitForLoad()
        let child = try XCTUnwrap(vm.result?.sections.first?.nodes.first?.reference)
        vm.explore(reference: child)
        await gate.waitForEntry()
        let waiter = Task { await vm.waitForLoad() }
        await Task.yield()
        vm.back()
        XCTAssertEqual(vm.result, originalResult)
        XCTAssertFalse(vm.canGoBack)
        await gate.open()
        await waiter.value
        XCTAssertEqual(vm.reference, originalReference)
        XCTAssertEqual(vm.result, originalResult)
        XCTAssertNil(vm.error)
    }

    private func makeVM(_ probe: RelationshipStateProbe) -> ResourceRelationshipsViewModel {
        ResourceRelationshipsViewModel { reference, reverse in try await probe.load(reference, reverse) }
    }
}

private func relationStateReference(service: AWSService = .ec2, resourceID: String = "i-12345678", profile: String = "example",
                                    region: String = "us-east-1", account: String = "111122223333", configPath: String = "/tmp/relations-config") -> ResourceRelationReference {
    ResourceRelationReference(scope: MonitoringScope(profile: AWSProfile(name: profile, region: "us-east-1", ssoStartURL: nil,
                                                                        ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
                                                    identity: AWSIdentity(account: account, arn: "arn:aws:sts::\(account):assumed-role/ReadOnly/example", userID: "example"),
                                                    region: region, paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": configPath, "AWS_SHARED_CREDENTIALS_FILE": "/tmp/relations-credentials"])),
                              service: service, resourceID: resourceID, name: "example")
}

private func relationStateResult(_ reference: ResourceRelationReference) -> ResourceRelationResult {
    let child = ResourceRelationReference(scope: reference.scope, service: .securityGroups, resourceID: "sg-12345678", name: "example-sg")
    return ResourceRelationResult(reference: reference, sections: [.init(id: "groups", title: "Security groups", nodes: [
        .init(id: "group", name: child.name, relation: "Bound security group", reference: child)
    ])])
}

private struct RelationStateFailure: LocalizedError {
    var errorDescription: String? { "private-token-should-not-be-displayed" }
}

private actor RelationshipStateProbe {
    private let gate: TestGate?
    private let failFirst: Bool
    private var recorded: [(ResourceRelationReference, Bool)] = []

    init(gate: TestGate? = nil, failFirst: Bool = false) {
        self.gate = gate
        self.failFirst = failFirst
    }

    func requests() -> [(ResourceRelationReference, Bool)] { recorded }

    func load(_ reference: ResourceRelationReference, _ reverse: Bool) async throws -> ResourceRelationResult {
        recorded.append((reference, reverse))
        let isFirst = recorded.count == 1
        if isFirst, let gate { await gate.wait() }
        if isFirst && failFirst { throw RelationStateFailure() }
        return relationStateResult(reference)
    }
}
