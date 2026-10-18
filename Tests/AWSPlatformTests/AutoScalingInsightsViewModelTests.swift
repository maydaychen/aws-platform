import XCTest
@testable import AWSPlatform

@MainActor
final class AutoScalingInsightsViewModelTests: XCTestCase {
    func testConfigureAndMissingScopeDoNotQuery() async {
        let probe = InsightsProbe()
        let vm = makeVM(probe)
        vm.loadTemplateVersions()
        vm.loadInstanceRefreshes()
        vm.configure(scope: asgServiceScope(), group: asgInsightsGroup())
        await vm.waitForLoading()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0])
        XCTAssertFalse(vm.didLoadTemplates)
        XCTAssertFalse(vm.didLoadRefreshes)
    }

    func testInvalidGroupAndScopeCannotLoad() async {
        let probe = InsightsProbe()
        let vm = makeVM(probe)
        for scope in [nil, asgServiceScope(profile: ""), asgServiceScope(region: "us-east-1")] {
            vm.configure(scope: scope, group: asgInsightsGroup())
            vm.loadTemplateVersions()
            vm.loadInstanceRefreshes()
            await vm.waitForLoading()
            XCTAssertNil(vm.scope)
            XCTAssertNil(vm.group)
        }
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0])
    }

    func testIndependentManualLoadsAndSameScopeConfigurePreserveResults() async {
        let probe = InsightsProbe()
        let vm = makeVM(probe)
        configure(vm)
        vm.loadTemplateVersions()
        await vm.waitForLoading()
        XCTAssertEqual(vm.templateVersions.count, 1)
        XCTAssertTrue(vm.instanceRefreshes.isEmpty)
        vm.loadInstanceRefreshes()
        await vm.waitForLoading()
        vm.configure(scope: asgServiceScope(), group: asgInsightsGroup())
        XCTAssertEqual(vm.templateVersions.count, 1)
        XCTAssertEqual(vm.instanceRefreshes.count, 1)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1])
    }

    func testMixedAndOverrideTemplateReferencesAreDeduplicated() async {
        let second = ASGLaunchTemplate(templateID: "lt-11111111111111111", version: "2")
        let group = ASGGroup(arn: asgServiceARN(), name: "example", launchTemplate: asgInsightsTemplate,
            mixedInstances: .init(launchTemplate: asgInsightsTemplate,
                overrides: [.init(launchTemplate: second), .init(launchTemplate: second)]))
        let probe = InsightsProbe()
        let vm = makeVM(probe)
        vm.configure(scope: asgServiceScope(), group: group)
        XCTAssertEqual(vm.templates, [asgInsightsTemplate, second])
        vm.loadTemplateVersions()
        await vm.waitForLoading()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [2, 0])
        XCTAssertEqual(vm.templateVersions.count, 2)
    }

    func testNoTemplateReferenceCompletesWithoutBroaderRequest() async {
        let probe = InsightsProbe()
        let vm = makeVM(probe)
        vm.configure(scope: asgServiceScope(), group: asgInsightsGroup(template: nil))
        vm.loadTemplateVersions()
        await vm.waitForLoading()
        XCTAssertTrue(vm.didLoadTemplates)
        XCTAssertFalse(vm.isTemplatesLoading)
        XCTAssertNil(vm.templatesError)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0])
    }

    func testOneDetailFailureDoesNotDiscardOtherSuccessAndSanitizesErrors() async {
        let probe = InsightsProbe(failures: ["templates-1"])
        let vm = makeVM(probe)
        configure(vm)
        vm.loadTemplateVersions()
        vm.loadInstanceRefreshes()
        await vm.waitForLoading()
        XCTAssertTrue(vm.templateVersions.isEmpty)
        XCTAssertEqual(vm.templatesError, AutoScalingInsightsError.failed.localizedDescription)
        XCTAssertFalse(vm.templatesError?.contains("private") ?? true)
        XCTAssertEqual(vm.instanceRefreshes.count, 1)
        XCTAssertNil(vm.refreshesError)
    }

    func testLaterTemplateReferenceFailureDiscardsWholeTemplateBatch() async {
        let group = ASGGroup(arn: asgServiceARN(), name: "example", launchTemplate: asgInsightsTemplate,
            mixedInstances: .init(launchTemplate: .init(templateID: "lt-11111111111111111", version: "1")))
        let probe = InsightsProbe(failures: ["templates-2"])
        let vm = makeVM(probe)
        vm.configure(scope: asgServiceScope(), group: group)
        vm.loadTemplateVersions()
        await vm.waitForLoading()
        XCTAssertTrue(vm.templateVersions.isEmpty)
        XCTAssertNotNil(vm.templatesError)
    }

    func testProfileRegionRoleAndConfigurationChangesClearResults() async {
        let scopes = [asgServiceScope(profile: "other"), asgServiceScope(region: "us-east-1"),
                      asgStateScope(region: "eu-west-1", role: "OtherRole"),
                      asgStateScope(region: "eu-west-1", paths: .init(environment: ["AWS_CONFIG_FILE": "/other/config"]))]
        for scope in scopes {
            let vm = makeVM(InsightsProbe())
            configure(vm)
            vm.loadTemplateVersions()
            vm.loadInstanceRefreshes()
            await vm.waitForLoading()
            vm.configure(scope: scope, group: asgInsightsGroup())
            XCTAssertTrue(vm.templateVersions.isEmpty)
            XCTAssertTrue(vm.instanceRefreshes.isEmpty)
            XCTAssertFalse(vm.didLoadTemplates)
            XCTAssertFalse(vm.didLoadRefreshes)
        }
    }

    func testChangedGroupTemplateInvalidatesSameARNResults() async {
        let vm = makeVM(InsightsProbe())
        configure(vm)
        vm.loadTemplateVersions()
        await vm.waitForLoading()
        vm.configure(scope: asgServiceScope(), group: asgInsightsGroup(template: .init(templateID: asgInsightsTemplate.templateID, version: "$Default")))
        XCTAssertTrue(vm.templateVersions.isEmpty)
        XCTAssertFalse(vm.didLoadTemplates)
    }

    func testLateSuccessAfterGroupChangeCannotReappear() async {
        let gate = TestGate()
        let probe = InsightsProbe(gates: ["templates-1": gate])
        let vm = makeVM(probe)
        configure(vm)
        vm.loadTemplateVersions()
        await gate.waitForEntry()
        vm.configure(scope: asgServiceScope(), group: asgInsightsGroup(name: "other"))
        await gate.open()
        await waitForCompletion(probe, "templates-1")
        await Task.yield()
        XCTAssertTrue(vm.templateVersions.isEmpty)
        XCTAssertNil(vm.templatesError)
        XCTAssertEqual(vm.group?.name, "other")
    }

    func testLateFailureAfterResetCannotReappear() async {
        let gate = TestGate()
        let probe = InsightsProbe(gates: ["refreshes-1": gate], failures: ["refreshes-1"])
        let vm = makeVM(probe)
        configure(vm)
        vm.loadInstanceRefreshes()
        await gate.waitForEntry()
        vm.reset()
        await gate.open()
        await waitForCompletion(probe, "refreshes-1")
        await Task.yield()
        XCTAssertNil(vm.refreshesError)
        XCTAssertTrue(vm.instanceRefreshes.isEmpty)
        XCTAssertNil(vm.scope)
    }

    func testReplacementRequestSupersedesLateFailure() async {
        let gate = TestGate()
        let probe = InsightsProbe(gates: ["refreshes-1": gate], failures: ["refreshes-1"])
        let vm = makeVM(probe)
        configure(vm)
        vm.loadInstanceRefreshes()
        await gate.waitForEntry()
        vm.loadInstanceRefreshes()
        await vm.waitForLoading()
        await gate.open()
        await waitForCompletion(probe, "refreshes-1")
        await Task.yield()
        XCTAssertEqual(vm.instanceRefreshes.count, 1)
        XCTAssertNil(vm.refreshesError)
    }

    func testCancelInvalidatesPendingButPreservesCompletedDetail() async {
        let gate = TestGate()
        let probe = InsightsProbe(gates: ["refreshes-1": gate])
        let vm = makeVM(probe)
        configure(vm)
        vm.loadTemplateVersions()
        await vm.waitForLoading()
        vm.loadInstanceRefreshes()
        await gate.waitForEntry()
        vm.cancelLoading()
        await gate.open()
        await waitForCompletion(probe, "refreshes-1")
        await Task.yield()
        XCTAssertEqual(vm.templateVersions.count, 1)
        XCTAssertTrue(vm.instanceRefreshes.isEmpty)
        XCTAssertFalse(vm.isRefreshesLoading)
        XCTAssertEqual(vm.refreshesError, "Loading cancelled. Use Load to try again.")
    }

    func testInvalidInjectedRelationshipCannotDisplayData() async {
        let vm = AutoScalingInsightsViewModel(templateLoader: { _, _, _ in [asgInsightsModel(reference: .init(name: "other", version: "2"))] },
            refreshLoader: { _, _ in [asgInsightsRefresh(group: "other")] })
        configure(vm)
        vm.loadTemplateVersions()
        vm.loadInstanceRefreshes()
        await vm.waitForLoading()
        XCTAssertEqual(vm.templatesError, AutoScalingInsightsError.invalidResponse.localizedDescription)
        XCTAssertEqual(vm.refreshesError, AutoScalingInsightsError.invalidResponse.localizedDescription)
        XCTAssertTrue(vm.templateVersions.isEmpty)
        XCTAssertTrue(vm.instanceRefreshes.isEmpty)
    }

    func testMemberNavigationRequiresCurrentGroupMembershipAndValidScope() {
        let member = ASGMember(instanceID: "i-0123456789abcdef0")
        let group = ASGGroup(arn: asgServiceARN(), name: "example", members: [member])
        let reference = ASGInsightsContext.memberReference(member, group: group, scope: asgServiceScope())
        XCTAssertEqual(reference?.service, .ec2)
        XCTAssertEqual(reference?.resourceID, member.instanceID)
        XCTAssertEqual(reference?.scope, asgServiceScope())
        XCTAssertNil(ASGInsightsContext.memberReference(member, group: asgInsightsGroup(), scope: asgServiceScope()))
        XCTAssertNil(ASGInsightsContext.memberReference(member, group: group, scope: nil))
        XCTAssertNil(ASGInsightsContext.memberReference(member, group: group, scope: asgServiceScope(region: "us-east-1")))
        let invalid = ASGMember(instanceID: "i-injection")
        let invalidGroup = ASGGroup(arn: asgServiceARN(), name: "example", members: [invalid])
        XCTAssertNil(ASGInsightsContext.memberReference(invalid, group: invalidGroup, scope: asgServiceScope()))
    }

    func testLegalGroupWhitespaceAndControlsConfigureLoadAndNavigateMembers() async {
        let scope = asgServiceScope()
        let member = ASGMember(instanceID: "i-0123456789abcdef0")
        for name in [" ", "bad\nname", "\t", "\r\n"] {
            let probe = InsightsProbe()
            let vm = makeVM(probe)
            let group = ASGGroup(arn: asgServiceARN(name), name: name, launchTemplate: asgInsightsTemplate, members: [member])
            vm.configure(scope: scope, group: group)
            XCTAssertEqual(vm.scope, scope)
            XCTAssertEqual(vm.group, group)
            vm.loadTemplateVersions()
            vm.loadInstanceRefreshes()
            await vm.waitForLoading()
            XCTAssertEqual(vm.templateVersions.count, 1)
            XCTAssertEqual(vm.instanceRefreshes.first?.groupName, name)
            XCTAssertNil(vm.templatesError)
            XCTAssertNil(vm.refreshesError)
            let counts = await probe.counts()
            XCTAssertEqual(counts, [1, 1])
            let reference = ASGInsightsContext.memberReference(member, group: group, scope: scope)
            XCTAssertEqual(reference?.service, .ec2)
            XCTAssertEqual(reference?.resourceID, member.instanceID)
            XCTAssertEqual(reference?.scope, scope)
        }
    }

    private func configure(_ vm: AutoScalingInsightsViewModel) { vm.configure(scope: asgServiceScope(), group: asgInsightsGroup()) }
    private func makeVM(_ probe: InsightsProbe) -> AutoScalingInsightsViewModel {
        .init(templateLoader: { try await probe.templates($0, group: $1, reference: $2) },
              refreshLoader: { try await probe.refreshes($0, group: $1) })
    }
    private func waitForCompletion(_ probe: InsightsProbe, _ key: String) async {
        for _ in 0..<1000 {
            if await probe.finished(key) { return }
            await Task.yield()
        }
        XCTFail("Fixture did not complete")
    }
}

private actor InsightsProbe {
    private var templateCalls = 0, refreshCalls = 0
    private var completed: Set<String> = []
    private let gates: [String: TestGate]
    private let failures: Set<String>
    init(gates: [String: TestGate] = [:], failures: Set<String> = []) { self.gates = gates; self.failures = failures }
    func counts() -> [Int] { [templateCalls, refreshCalls] }
    func finished(_ key: String) -> Bool { completed.contains(key) }
    func templates(_ scope: MonitoringScope, group: ASGGroup, reference: ASGLaunchTemplate) async throws -> [ASGTemplateVersion] {
        templateCalls += 1
        try await begin("templates-\(templateCalls)")
        return [asgInsightsModel(reference: reference)]
    }
    func refreshes(_ scope: MonitoringScope, group: ASGGroup) async throws -> [ASGInstanceRefresh] {
        refreshCalls += 1
        try await begin("refreshes-\(refreshCalls)")
        return [asgInsightsRefresh(group: group.name)]
    }
    private func begin(_ key: String) async throws {
        await gates[key]?.wait()
        completed.insert(key)
        if failures.contains(key) { throw NSError(domain: "private-response-token", code: 1) }
    }
}
