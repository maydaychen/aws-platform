import XCTest
@testable import AWSPlatform

@MainActor
final class AutoScalingViewModelTests: XCTestCase {
    func testMissingInvalidScopeAndConfigureAloneNeverQuery() async {
        let probe = ASGStateProbe()
        let vm = makeVM(probe)
        for scope in [nil, asgStateScope(profile: ""), asgStateScope(account: ""), asgStateScope(region: "invalid")] {
            vm.configure(scope: scope)
            vm.loadIfNeeded()
            vm.refresh()
            vm.refreshDetails()
            vm.selectedGroup = asgStateGroup()
            await vm.waitForLoading()
            await vm.waitForDetails()
            XCTAssertFalse(vm.isLoading)
            XCTAssertTrue(vm.groups.isEmpty)
            XCTAssertNil(vm.selectedGroup)
        }
        vm.configure(scope: asgStateScope())
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0])
    }

    func testListLoadsOnceWithoutAutomaticSelectionOrDetails() async {
        let probe = ASGStateProbe()
        let vm = makeVM(probe)
        await load(vm)
        vm.loadIfNeeded()
        XCTAssertEqual(vm.groups.count, 2)
        XCTAssertNil(vm.selectedGroup)
        XCTAssertTrue(vm.policies.isEmpty)
        XCTAssertTrue(vm.activities.isEmpty)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0])
    }

    func testSuccessfulEmptyResultDoesNotRetryUntilRefresh() async {
        let probe = ASGStateProbe(groups: ["groups-1": []])
        let vm = makeVM(probe)
        await load(vm)
        vm.loadIfNeeded()
        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertNil(vm.error)
        var counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0])
        vm.refresh()
        await vm.waitForLoading()
        XCTAssertEqual(vm.groups.count, 2)
        counts = await probe.counts()
        XCTAssertEqual(counts, [2, 0, 0])
    }

    func testListFailureUsesSafeMessageAndOnlyExplicitRefreshRetries() async {
        let probe = ASGStateProbe(failures: ["groups-1"])
        let vm = makeVM(probe)
        await load(vm)
        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertEqual(vm.error, "Unable to load Auto Scaling groups. Refresh to try again.")
        vm.loadIfNeeded()
        var counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0])
        vm.refresh()
        await vm.waitForLoading()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.groups.count, 2)
        counts = await probe.counts()
        XCTAssertEqual(counts, [2, 0, 0])
    }

    func testLocalSearchUsesNameAndARNWithoutRequests() async {
        let probe = ASGStateProbe()
        let vm = makeVM(probe)
        await load(vm)
        vm.searchText = " SHARED "
        XCTAssertEqual(vm.filteredGroups, [asgStateGroup()])
        vm.searchText = "autoScalingGroupName/OTHER"
        XCTAssertEqual(vm.filteredGroups, [asgStateGroup("other")])
        vm.searchText = "missing"
        XCTAssertTrue(vm.filteredGroups.isEmpty)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0])
    }

    func testManualSelectionLoadsDetailsOnceAndClearRemovesThem() async {
        let probe = ASGStateProbe()
        let vm = makeVM(probe)
        await load(vm)
        vm.selectedGroup = vm.groups[0]
        await vm.waitForDetails()
        XCTAssertEqual(vm.policies, [asgStatePolicy()])
        XCTAssertEqual(vm.activities, [asgStateActivity()])
        vm.selectedGroup = vm.groups[0]
        await vm.waitForDetails()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1])
        vm.selectedGroup = nil
        XCTAssertTrue(vm.policies.isEmpty)
        XCTAssertTrue(vm.activities.isEmpty)
        XCTAssertNil(vm.policiesError)
        XCTAssertNil(vm.activitiesError)
    }

    func testUnlistedAndModifiedSelectionsCannotQueryDetails() async {
        let probe = ASGStateProbe()
        let vm = makeVM(probe)
        await load(vm)
        for invalid in [asgStateGroup("missing"), asgStateGroup(desired: 3)] {
            vm.selectedGroup = invalid
            vm.refreshDetails()
            await vm.waitForDetails()
            XCTAssertNil(vm.selectedGroup)
        }
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0])
        vm.selectedGroup = vm.groups[0]
        await vm.waitForDetails()
        vm.selectedGroup = asgStateGroup("missing")
        XCTAssertNil(vm.selectedGroup)
        XCTAssertTrue(vm.policies.isEmpty)
        XCTAssertTrue(vm.activities.isEmpty)
    }

    func testIndependentDetailSuccessAppearsWhileOtherRequestIsPending() async {
        let gate = TestGate()
        let vm = makeVM(ASGStateProbe(gates: ["activities-1": gate]))
        await load(vm)
        vm.selectedGroup = vm.groups[0]
        await gate.waitForEntry()
        await eventually { !vm.isPoliciesLoading }
        XCTAssertEqual(vm.policies, [asgStatePolicy()])
        XCTAssertTrue(vm.isActivitiesLoading)
        XCTAssertTrue(vm.activities.isEmpty)
        await gate.open()
        await vm.waitForDetails()
        XCTAssertEqual(vm.activities, [asgStateActivity()])
    }

    func testIndependentFailuresPreserveOtherDetailAndRefreshRecovers() async {
        for failed in ["policies", "activities"] {
            let probe = ASGStateProbe(failures: ["\(failed)-1"])
            let vm = makeVM(probe)
            await load(vm)
            vm.selectedGroup = vm.groups[0]
            await vm.waitForDetails()
            XCTAssertEqual(vm.policies.isEmpty, failed == "policies")
            XCTAssertEqual(vm.activities.isEmpty, failed == "activities")
            XCTAssertEqual(vm.policiesError != nil, failed == "policies")
            XCTAssertEqual(vm.activitiesError != nil, failed == "activities")
            XCTAssertFalse(vm.policiesError?.contains("secret") == true)
            XCTAssertFalse(vm.activitiesError?.contains("secret") == true)
            XCTAssertNil(vm.error)
            vm.refreshDetails()
            await vm.waitForDetails()
            XCTAssertEqual(vm.policies, [asgStatePolicy()])
            XCTAssertEqual(vm.activities, [asgStateActivity()])
            XCTAssertNil(vm.policiesError)
            XCTAssertNil(vm.activitiesError)
            let counts = await probe.counts()
            XCTAssertEqual(counts, [1, 2, 2])
        }
    }

    func testEmptyDetailsAreSuccessfulAndDoNotAutoRetry() async {
        let probe = ASGStateProbe(policies: ["policies-1": []], activities: ["activities-1": []])
        let vm = makeVM(probe)
        await load(vm)
        vm.selectedGroup = vm.groups[0]
        await vm.waitForDetails()
        vm.loadIfNeeded()
        vm.selectedGroup = vm.groups[0]
        XCTAssertTrue(vm.policies.isEmpty)
        XCTAssertTrue(vm.activities.isEmpty)
        XCTAssertNil(vm.policiesError)
        XCTAssertNil(vm.activitiesError)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1])
    }

    func testSafeDomainErrorsAndCancellationPreserveFixedMessages() async {
        let vm = makeVM(ASGStateProbe(safeFailures: ["policies-1"], cancellations: ["activities-1"]))
        await load(vm)
        vm.selectedGroup = vm.groups[0]
        await vm.waitForDetails()
        XCTAssertEqual(vm.policiesError, AutoScalingError.invalidResponse.localizedDescription)
        XCTAssertEqual(vm.activitiesError, "Loading cancelled. Use Refresh to try again.")
    }

    func testRefreshRestoresExactARNWithUpdatedMetadataAndReloadsDetails() async {
        let updated = asgStateGroup(desired: 3)
        let probe = ASGStateProbe(groups: ["groups-2": [updated]])
        let vm = makeVM(probe)
        await load(vm)
        vm.selectedGroup = vm.groups[0]
        await vm.waitForDetails()
        vm.refresh()
        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertNil(vm.selectedGroup)
        XCTAssertTrue(vm.policies.isEmpty)
        XCTAssertTrue(vm.activities.isEmpty)
        await vm.waitForLoading()
        await vm.waitForDetails()
        XCTAssertEqual(vm.selectedGroup, updated)
        XCTAssertEqual(vm.policies, [asgStatePolicy(updated)])
        let counts = await probe.counts()
        XCTAssertEqual(counts, [2, 2, 2])
    }

    func testRefreshDoesNotSelectRecreatedSameNameGroupWithDifferentARN() async {
        let recreated = asgStateGroup(token: "22222222-2222-4222-8222-222222222222")
        let probe = ASGStateProbe(groups: ["groups-2": [recreated]])
        let vm = makeVM(probe)
        await load(vm)
        vm.selectedGroup = vm.groups[0]
        await vm.waitForDetails()
        vm.refresh()
        await vm.waitForLoading()
        XCTAssertEqual(vm.groups, [recreated])
        XCTAssertNil(vm.selectedGroup)
        XCTAssertTrue(vm.policies.isEmpty)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [2, 1, 1])
    }

    func testManualClearDuringRefreshPreventsLateRestoration() async {
        let gate = TestGate()
        let vm = makeVM(ASGStateProbe(gates: ["groups-2": gate]))
        await load(vm)
        vm.selectedGroup = vm.groups[0]
        await vm.waitForDetails()
        vm.refresh()
        await gate.waitForEntry()
        vm.selectedGroup = nil
        await gate.open()
        await vm.waitForLoading()
        XCTAssertNil(vm.selectedGroup)
        XCTAssertTrue(vm.policies.isEmpty)
    }

    func testFailedRefreshCanRestoreTargetOnExplicitRetry() async {
        let vm = makeVM(ASGStateProbe(failures: ["groups-2"]))
        await load(vm)
        vm.selectedGroup = vm.groups[0]
        await vm.waitForDetails()
        vm.refresh()
        await vm.waitForLoading()
        XCTAssertNil(vm.selectedGroup)
        XCTAssertNotNil(vm.error)
        vm.refresh()
        await vm.waitForLoading()
        await vm.waitForDetails()
        XCTAssertEqual(vm.selectedGroup, asgStateGroup())
        XCTAssertEqual(vm.activities, [asgStateActivity()])
    }

    func testGroupChangesAndClearRejectLateDetailSuccessAndFailure() async {
        for failure in [false, true] {
            for clear in [false, true] {
                let gate = TestGate()
                let probe = ASGStateProbe(gates: ["activities-1": gate], failures: failure ? ["activities-1"] : [])
                let vm = makeVM(probe)
                await load(vm)
                vm.selectedGroup = vm.groups[0]
                await gate.waitForEntry()
                vm.selectedGroup = clear ? nil : vm.groups[1]
                XCTAssertTrue(vm.activities.isEmpty)
                await vm.waitForDetails()
                let expected = vm.activities
                await gate.open()
                await eventually { await probe.finished("activities-1") }
                await settle()
                XCTAssertEqual(vm.activities, expected)
                XCTAssertNil(vm.activitiesError)
                XCTAssertFalse(vm.isActivitiesLoading)
                XCTAssertEqual(vm.selectedGroup, clear ? nil : asgStateGroup("other"))
            }
        }
    }

    func testRefreshDetailsRejectsSupersededResponse() async {
        let gate = TestGate()
        let probe = ASGStateProbe(gates: ["policies-1": gate], failures: ["policies-1"])
        let vm = makeVM(probe)
        await load(vm)
        vm.selectedGroup = vm.groups[0]
        await gate.waitForEntry()
        vm.refreshDetails()
        await vm.waitForDetails()
        await gate.open()
        await eventually { await probe.finished("policies-1") }
        await settle()
        XCTAssertEqual(vm.policies, [asgStatePolicy()])
        XCTAssertNil(vm.policiesError)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 2, 2])
    }

    func testCancelPreservesCompletedDetailsAndMarksOnlyPendingOperation() async {
        for pending in ["policies", "activities"] {
            let gate = TestGate()
            let key = "\(pending)-1"
            let probe = ASGStateProbe(gates: [key: gate])
            let vm = makeVM(probe)
            await load(vm)
            vm.selectedGroup = vm.groups[0]
            await gate.waitForEntry()
            await eventually { pending == "policies" ? !vm.isActivitiesLoading : !vm.isPoliciesLoading }
            let groups = vm.groups
            let policies = vm.policies
            let activities = vm.activities
            vm.cancelLoading()
            XCTAssertEqual(vm.groups, groups)
            XCTAssertEqual(vm.selectedGroup, asgStateGroup())
            XCTAssertEqual(vm.policies, policies)
            XCTAssertEqual(vm.activities, activities)
            XCTAssertEqual(vm.policiesError != nil, pending == "policies")
            XCTAssertEqual(vm.activitiesError != nil, pending == "activities")
            XCTAssertFalse(vm.isPoliciesLoading)
            XCTAssertFalse(vm.isActivitiesLoading)
            await gate.open()
            await eventually { await probe.finished(key) }
            await settle()
            XCTAssertEqual(vm.policies, policies)
            XCTAssertEqual(vm.activities, activities)
        }
    }

    func testCancelWhenNothingIsPendingPreservesDataAndDoesNotInventErrors() async {
        let vm = makeVM(ASGStateProbe())
        await load(vm)
        vm.selectedGroup = vm.groups[0]
        await vm.waitForDetails()
        vm.cancelLoading()
        XCTAssertEqual(vm.groups.count, 2)
        XCTAssertEqual(vm.selectedGroup, asgStateGroup())
        XCTAssertEqual(vm.policies, [asgStatePolicy()])
        XCTAssertEqual(vm.activities, [asgStateActivity()])
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.policiesError)
        XCTAssertNil(vm.activitiesError)
    }

    func testEveryScopeDimensionImmediatelyClearsStateAndLateDetailsCannotReturn() async {
        for scope in changedScopes() {
            for failure in [false, true] {
                let gate = TestGate()
                let probe = ASGStateProbe(gates: ["policies-1": gate], failures: failure ? ["policies-1"] : [])
                let vm = makeVM(probe)
                await load(vm)
                vm.selectedGroup = vm.groups[0]
                await gate.waitForEntry()
                vm.searchText = "shared"
                vm.configure(scope: scope)
                XCTAssertEqual(vm.scope, scope)
                XCTAssertTrue(vm.groups.isEmpty)
                XCTAssertNil(vm.selectedGroup)
                XCTAssertTrue(vm.policies.isEmpty)
                XCTAssertTrue(vm.activities.isEmpty)
                XCTAssertEqual(vm.searchText, "")
                await gate.open()
                await eventually { await probe.finished("policies-1") }
                await settle()
                XCTAssertTrue(vm.policies.isEmpty)
                XCTAssertNil(vm.policiesError)
                XCTAssertFalse(vm.isPoliciesLoading)
            }
        }
    }

    func testSameScopeConfigureKeepsInFlightQueryAndSelection() async {
        let gate = TestGate()
        let probe = ASGStateProbe(gates: ["groups-1": gate])
        let vm = makeVM(probe)
        vm.configure(scope: asgStateScope())
        vm.refresh()
        await gate.waitForEntry()
        vm.configure(scope: asgStateScope())
        XCTAssertTrue(vm.isLoading)
        await gate.open()
        await vm.waitForLoading()
        vm.selectedGroup = vm.groups[0]
        await vm.waitForDetails()
        vm.searchText = "shared"
        vm.configure(scope: asgStateScope())
        XCTAssertEqual(vm.selectedGroup, asgStateGroup())
        XCTAssertEqual(vm.searchText, "shared")
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1])
    }

    func testLateListSuccessAndFailureCannotOverwriteRefreshResetScopeOrCancellation() async {
        for failure in [false, true] {
            for transition in ["refresh", "reset", "scope", "cancel"] {
                let gate = TestGate()
                let probe = ASGStateProbe(gates: ["groups-1": gate], failures: failure ? ["groups-1"] : [],
                                          groups: ["groups-1": [asgStateGroup("outdated")]])
                let vm = makeVM(probe)
                vm.configure(scope: asgStateScope())
                vm.refresh()
                await gate.waitForEntry()
                if transition == "reset" { vm.reset() }
                else if transition == "cancel" { vm.cancelLoading() }
                else {
                    if transition == "scope" { vm.configure(scope: asgStateScope(profile: "other")) }
                    vm.refresh()
                    await vm.waitForLoading()
                }
                let expected = vm.groups
                let expectedError = vm.error
                await gate.open()
                await eventually { await probe.finished("groups-1") }
                await settle()
                XCTAssertEqual(vm.groups, expected)
                XCTAssertEqual(vm.error, expectedError)
                XCTAssertFalse(vm.isLoading)
            }
        }
    }

    func testMalformedGroupsFailWithoutShowingPartialData() async {
        let group = asgStateGroup()
        for rows in [[group, group], [ASGGroup(arn: "", name: "bad")], [ASGGroup(arn: "arn", name: "")]] {
            let vm = makeVM(ASGStateProbe(groups: ["groups-1": rows]))
            await load(vm)
            XCTAssertTrue(vm.groups.isEmpty)
            XCTAssertEqual(vm.error, AutoScalingError.invalidResponse.localizedDescription)
        }
    }

    func testMalformedDetailsFailIndependentlyWithoutPartialResults() async {
        let group = asgStateGroup()
        let wrong = asgStateGroup("other")
        let policy = asgStatePolicy()
        let activity = asgStateActivity()
        let invalidPolicies = [[policy, policy], [asgStatePolicy(wrong)], [ASGPolicy(arn: "", name: "bad", groupName: group.name)]]
        for rows in invalidPolicies {
            let vm = makeVM(ASGStateProbe(policies: ["policies-1": rows]))
            await load(vm)
            vm.selectedGroup = group
            await vm.waitForDetails()
            XCTAssertTrue(vm.policies.isEmpty)
            XCTAssertEqual(vm.policiesError, AutoScalingError.invalidResponse.localizedDescription)
            XCTAssertEqual(vm.activities, [activity])
        }
        for rows in [[activity, activity], [asgStateActivity(wrong)], [ASGActivity(activityID: "missing-arn", groupName: group.name)]] {
            let vm = makeVM(ASGStateProbe(activities: ["activities-1": rows]))
            await load(vm)
            vm.selectedGroup = group
            await vm.waitForDetails()
            XCTAssertTrue(vm.activities.isEmpty)
            XCTAssertEqual(vm.activitiesError, AutoScalingError.invalidResponse.localizedDescription)
            XCTAssertEqual(vm.policies, [policy])
        }
    }

    func testPermissionFailuresUseSafeServiceMessages() async {
        let vm = AutoScalingViewModel(groupLoader: { _ in [asgStateGroup()] },
                                      policyLoader: { _, _ in throw AWSAutoScalingService.RequestError.policiesPermission },
                                      activityLoader: { _, _ in throw AWSAutoScalingService.RequestError.activitiesPermission })
        await load(vm)
        vm.selectedGroup = vm.groups[0]
        await vm.waitForDetails()
        XCTAssertEqual(vm.policiesError, AWSAutoScalingService.RequestError.policiesPermission.localizedDescription)
        XCTAssertEqual(vm.activitiesError, AWSAutoScalingService.RequestError.activitiesPermission.localizedDescription)
    }

    private func makeVM(_ probe: ASGStateProbe) -> AutoScalingViewModel {
        AutoScalingViewModel(groupLoader: { try await probe.loadGroups($0) },
                             policyLoader: { try await probe.loadPolicies($0, group: $1) },
                             activityLoader: { try await probe.loadActivities($0, group: $1) })
    }

    private func load(_ vm: AutoScalingViewModel) async {
        vm.configure(scope: asgStateScope())
        vm.loadIfNeeded()
        await vm.waitForLoading()
    }

    private func changedScopes() -> [MonitoringScope?] {
        [nil, asgStateScope(profile: "other"), asgStateScope(region: "eu-west-1"),
         asgStateScope(account: "444455556666"), asgStateScope(role: "Other"),
         asgStateScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/asg-other-config"])),
         asgStateScope(paths: AWSConfigurationPaths(environment: ["AWS_SHARED_CREDENTIALS_FILE": "/tmp/asg-other-credentials"]))]
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("State transition did not complete", file: file, line: line)
    }
}
