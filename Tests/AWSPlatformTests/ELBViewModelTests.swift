import XCTest
@testable import AWSPlatform

@MainActor
final class ELBViewModelTests: XCTestCase {
    func testNilInvalidAndConfigureAloneNeverQuery() async {
        let probe = ELBStateProbe()
        let vm = makeVM(probe)
        for scope in [nil, elbStateScope(account: ""), elbStateScope(region: "invalid")] {
            vm.configure(scope: scope)
            await vm.loadLoadBalancers()
            await vm.loadTargetGroups()
            vm.refreshListeners()
            vm.refreshRules()
            vm.refreshTargets()
        }
        vm.configure(scope: elbStateScope())
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0, 0, 0])
        XCTAssertNil(vm.selectedLoadBalancer)
        XCTAssertNil(vm.selectedTargetGroup)
    }

    func testListsLoadIndependentlyDeduplicateAndNeverAutoSelectOrScanHealth() async {
        let gate = TestGate()
        let probe = ELBStateProbe(gates: [.loadBalancers: gate])
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope())
        vm.loadLoadBalancersIfNeeded()
        await gate.waitForEntry()
        vm.loadLoadBalancersIfNeeded()
        let joined = Task { await vm.loadLoadBalancers() }
        await Task.yield()
        await gate.open()
        await joined.value
        var counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0, 0])
        XCTAssertNil(vm.selectedLoadBalancer)
        vm.loadTargetGroupsIfNeeded()
        await vm.waitForTargetGroups()
        vm.loadLoadBalancersIfNeeded()
        vm.loadTargetGroupsIfNeeded()
        counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 0, 0, 0])
        XCTAssertNil(vm.selectedTargetGroup)
        XCTAssertTrue(vm.targets.isEmpty)
    }

    func testSelectionLoadsOnlyItsDemandedDetailsAndALBRulesNeedExplicitListener() async {
        let probe = ELBStateProbe()
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope())
        await vm.loadLoadBalancers()
        vm.selectedLoadBalancer = vm.loadBalancers[0]
        await vm.waitForDetails()
        var counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 1, 0, 0])
        XCTAssertNil(vm.selectedListener)
        vm.selectedListener = vm.listeners[0]
        await vm.waitForDetails()
        XCTAssertEqual(vm.rules.count, 1)
        await vm.loadTargetGroups()
        vm.selectedTargetGroup = vm.targetGroups[0]
        await vm.waitForDetails()
        counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1, 1, 1])
        XCTAssertEqual(vm.targets.count, 1)
        vm.selectedLoadBalancer = vm.loadBalancers[0]
        vm.selectedTargetGroup = vm.targetGroups[0]
        vm.selectedListener = vm.listeners[0]
        await vm.waitForDetails()
        let unchanged = await probe.counts()
        XCTAssertEqual(unchanged, counts)
    }

    func testNLBAndGWLBListenersNeverRequestRules() async {
        for kind in ["net", "gwy"] {
            let probe = ELBStateProbe(loadBalancerRows: [elbStateLB("one", kind: kind)])
            let vm = makeVM(probe)
            vm.configure(scope: elbStateScope())
            await vm.loadLoadBalancers()
            vm.selectedLoadBalancer = vm.loadBalancers[0]
            await vm.waitForDetails()
            vm.selectedListener = vm.listeners[0]
            vm.refreshRules()
            await vm.waitForDetails()
            let counts = await probe.counts()
            XCTAssertEqual(counts, [1, 0, 1, 0, 0])
            XCTAssertTrue(vm.rules.isEmpty)
            XCTAssertFalse(vm.isRulesLoading)
        }
    }

    func testUnlistedOrModifiedSelectionsCannotQuery() async {
        let probe = ELBStateProbe()
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope())
        await vm.loadLoadBalancers()
        await vm.loadTargetGroups()
        vm.selectedLoadBalancer = elbStateLB("unknown")
        vm.selectedTargetGroup = elbStateGroup("unknown")
        vm.selectedListener = elbStateListener(parent: elbStateLB("unknown"))
        await vm.waitForDetails()
        XCTAssertNil(vm.selectedLoadBalancer)
        XCTAssertNil(vm.selectedTargetGroup)
        XCTAssertNil(vm.selectedListener)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 0, 0, 0])
    }

    func testSameScopePreservesInflightListsAndSelection() async {
        let lbGate = TestGate()
        let groupGate = TestGate()
        let probe = ELBStateProbe(gates: [.loadBalancers: lbGate, .targetGroups: groupGate])
        let vm = makeVM(probe)
        let scope = elbStateScope()
        vm.configure(scope: scope)
        vm.loadLoadBalancersIfNeeded()
        vm.loadTargetGroupsIfNeeded()
        await lbGate.waitForEntry()
        await groupGate.waitForEntry()
        vm.searchText = "one"
        vm.configure(scope: scope)
        vm.loadLoadBalancersIfNeeded()
        vm.loadTargetGroupsIfNeeded()
        XCTAssertTrue(vm.isLoadBalancersLoading)
        XCTAssertTrue(vm.isTargetGroupsLoading)
        XCTAssertEqual(vm.searchText, "one")
        await lbGate.open()
        await groupGate.open()
        await vm.waitForLoadBalancers()
        await vm.waitForTargetGroups()
        vm.selectedLoadBalancer = vm.loadBalancers[0]
        vm.selectedTargetGroup = vm.targetGroups[0]
        await vm.waitForDetails()
        vm.configure(scope: scope)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1, 0, 1])
        XCTAssertNotNil(vm.selectedLoadBalancer)
        XCTAssertNotNil(vm.selectedTargetGroup)
    }

    func testProfileRegionIdentityAndPathsChangesClearAllState() async {
        let probe = ELBStateProbe()
        let vm = makeVM(probe)
        let scopes = [elbStateScope(), elbStateScope(profile: "other"), elbStateScope(region: "eu-west-1"),
                      elbStateScope(account: "444455556666"), elbStateScope(role: "Other"),
                      elbStateScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/elb-other"]))]
        for scope in scopes {
            vm.configure(scope: scope)
            XCTAssertTrue(vm.loadBalancers.isEmpty)
            XCTAssertTrue(vm.targetGroups.isEmpty)
            XCTAssertTrue(vm.listeners.isEmpty)
            XCTAssertTrue(vm.rules.isEmpty)
            XCTAssertTrue(vm.targets.isEmpty)
            XCTAssertNil(vm.selectedLoadBalancer)
            XCTAssertNil(vm.selectedTargetGroup)
            XCTAssertNil(vm.selectedListener)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertEqual(vm.kindFilter, "All")
            XCTAssertEqual(vm.groupSearchText, "")
            XCTAssertEqual(vm.targetTypeFilter, "All")
            await vm.loadLoadBalancers()
            await vm.loadTargetGroups()
            vm.selectedLoadBalancer = vm.loadBalancers[0]
            vm.selectedTargetGroup = vm.targetGroups[0]
            await vm.waitForDetails()
            vm.selectedListener = vm.listeners[0]
            await vm.waitForDetails()
            vm.searchText = "one"
            vm.kindFilter = "application"
            vm.groupSearchText = "one"
            vm.targetTypeFilter = "instance"
        }
        vm.configure(scope: nil)
        XCTAssertTrue(vm.loadBalancers.isEmpty)
        XCTAssertTrue(vm.targetGroups.isEmpty)
        XCTAssertTrue(vm.rules.isEmpty)
        XCTAssertTrue(vm.targets.isEmpty)
    }

    func testLocalFiltersSearchReturnedConfigurationWithoutCallingAWS() async {
        let lb = ELBLoadBalancer(arn: elbStateLB("one").arn, name: "frontend", kind: "application", dnsName: "front.example.test",
                                 scheme: "internal", state: "active", fields: [ELBField(name: "VPC", value: "vpc-example")])
        let group = ELBTargetGroup(arn: elbStateGroup("one").arn, name: "backend", targetType: "instance", protocolName: "HTTP", port: 8080,
                                  loadBalancerARNs: [lb.arn], fields: [ELBField(name: "Health check path", value: "/healthz")])
        let probe = ELBStateProbe(loadBalancerRows: [lb, elbStateLB("two", kind: "net")],
                                  groupRows: [group, elbStateGroup("two", type: "ip")])
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope())
        await vm.loadLoadBalancers()
        await vm.loadTargetGroups()
        for query in [" FRONTEND ", "front.example", "internal", "active", "vpc-example"] {
            vm.searchText = query
            XCTAssertEqual(vm.filteredLoadBalancers, [lb], query)
        }
        vm.searchText = ""
        vm.kindFilter = "APPLICATION"
        XCTAssertEqual(vm.filteredLoadBalancers, [lb])
        for query in [" BACKEND ", "http", "8080", "health check", "healthz", "loadbalancer/app/one"] {
            vm.groupSearchText = query
            XCTAssertEqual(vm.filteredTargetGroups, [group], query)
        }
        vm.groupSearchText = ""
        vm.targetTypeFilter = "INSTANCE"
        XCTAssertEqual(vm.filteredTargetGroups, [group])
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 0, 0, 0])
    }

    func testListFailuresAreIndependentAndFailedRefreshRetainsStaleSnapshot() async {
        let probe = ELBStateProbe(failures: [.loadBalancers: [2], .targetGroups: [1]])
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope())
        await vm.loadLoadBalancers()
        await vm.loadTargetGroups()
        XCTAssertNil(vm.loadBalancersError)
        XCTAssertNotNil(vm.targetGroupsError)
        XCTAssertFalse(vm.isTargetGroupsStale)
        let previous = vm.loadBalancers
        vm.loadTargetGroupsIfNeeded()
        var counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 0, 0, 0])
        await vm.loadLoadBalancers()
        XCTAssertEqual(vm.loadBalancers, previous)
        XCTAssertTrue(vm.isLoadBalancersStale)
        XCTAssertTrue(vm.loadBalancersError?.contains("previous list") == true)
        await vm.loadTargetGroups()
        XCTAssertFalse(vm.targetGroups.isEmpty)
        XCTAssertNil(vm.targetGroupsError)
        await vm.loadLoadBalancers()
        XCTAssertFalse(vm.isLoadBalancersStale)
        XCTAssertNil(vm.loadBalancersError)
        counts = await probe.counts()
        XCTAssertEqual(counts, [3, 2, 0, 0, 0])
    }

    func testFailedGroupRefreshMarksStaleAndKeepsExistingSelection() async {
        let probe = ELBStateProbe(failures: [.targetGroups: [2]])
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope())
        await vm.loadTargetGroups()
        vm.selectedTargetGroup = vm.targetGroups[0]
        await vm.waitForDetails()
        let selected = vm.selectedTargetGroup
        await vm.loadTargetGroups()
        XCTAssertEqual(vm.selectedTargetGroup, selected)
        XCTAssertTrue(vm.isTargetGroupsStale)
        XCTAssertTrue(vm.targetGroupsError?.contains("previous list") == true)
    }

    func testLateListSuccessAndFailureCannotCrossScopeOrReset() async {
        for failure in [false, true] {
            for reset in [false, true] {
                let lbGate = TestGate()
                let groupGate = TestGate()
                let probe = ELBStateProbe(gates: [.loadBalancers: lbGate, .targetGroups: groupGate],
                                          failures: failure ? [.loadBalancers: [1], .targetGroups: [1]] : [:])
                let vm = makeVM(probe)
                vm.configure(scope: elbStateScope())
                vm.loadLoadBalancersIfNeeded()
                vm.loadTargetGroupsIfNeeded()
                await lbGate.waitForEntry()
                await groupGate.waitForEntry()
                let oldLB = Task { await vm.waitForLoadBalancers() }
                let oldTG = Task { await vm.waitForTargetGroups() }
                await Task.yield()
                if reset { vm.reset() }
                else {
                    vm.configure(scope: elbStateScope(region: "eu-west-1"))
                    await vm.loadLoadBalancers()
                    await vm.loadTargetGroups()
                }
                await lbGate.open()
                await groupGate.open()
                await oldLB.value
                await oldTG.value
                XCTAssertEqual(vm.loadBalancers.isEmpty, reset)
                XCTAssertEqual(vm.targetGroups.isEmpty, reset)
                if !reset {
                    XCTAssertTrue(vm.loadBalancers.allSatisfy { $0.arn.contains(":eu-west-1:") })
                    XCTAssertTrue(vm.targetGroups.allSatisfy { $0.arn.contains(":eu-west-1:") })
                }
                XCTAssertNil(vm.loadBalancersError)
                XCTAssertNil(vm.targetGroupsError)
                XCTAssertFalse(vm.isLoadBalancersLoading)
                XCTAssertFalse(vm.isTargetGroupsLoading)
            }
        }
    }

    func testImmediateCancellationStartsNoAPIAndSectionsCanRetry() async {
        let probe = ELBStateProbe()
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope())
        vm.loadLoadBalancersIfNeeded()
        vm.loadTargetGroupsIfNeeded()
        vm.cancelLoadBalancers()
        vm.cancelTargetGroups()
        await Task.yield()
        var counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0, 0, 0])
        await vm.loadLoadBalancers()
        await vm.loadTargetGroups()
        vm.selectedLoadBalancer = vm.loadBalancers[0]
        vm.selectedTargetGroup = vm.targetGroups[0]
        vm.cancelDetails()
        await Task.yield()
        counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 0, 0, 0])
        XCTAssertTrue(vm.listenersError?.contains("cancelled") == true)
        XCTAssertTrue(vm.targetsError?.contains("cancelled") == true)
        vm.refreshListeners()
        vm.refreshTargets()
        await vm.waitForDetails()
        vm.selectedListener = vm.listeners[0]
        vm.cancelDetails()
        await Task.yield()
        counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1, 0, 1])
        XCTAssertTrue(vm.rulesError?.contains("cancelled") == true)
    }

    func testListenersAndTargetsFailIndependentlyRulesRetrySeparately() async {
        let probe = ELBStateProbe(failures: [.listeners: [1], .targets: [2], .rules: [1]])
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope())
        await vm.loadLoadBalancers()
        await vm.loadTargetGroups()
        vm.selectedLoadBalancer = vm.loadBalancers[0]
        vm.selectedTargetGroup = vm.targetGroups[0]
        await vm.waitForDetails()
        XCTAssertNotNil(vm.listenersError)
        XCTAssertNil(vm.targetsError)
        XCTAssertEqual(vm.targets.count, 1)
        vm.refreshListeners()
        vm.refreshTargets()
        await vm.waitForDetails()
        XCTAssertNil(vm.listenersError)
        XCTAssertNotNil(vm.targetsError)
        vm.selectedListener = vm.listeners[0]
        await vm.waitForDetails()
        XCTAssertNotNil(vm.rulesError)
        XCTAssertFalse(vm.listeners.isEmpty)
        vm.refreshRules()
        await vm.waitForDetails()
        XCTAssertNil(vm.rulesError)
        XCTAssertEqual(vm.rules.count, 1)
    }

    func testLateListenerAndTargetResponsesCannotCrossSelectionsOrReset() async {
        for failure in [false, true] {
            for reset in [false, true] {
                let listenersGate = TestGate()
                let targetsGate = TestGate()
                let probe = ELBStateProbe(gates: [.listeners: listenersGate, .targets: targetsGate],
                                          failures: failure ? [.listeners: [1], .targets: [1]] : [:])
                let vm = makeVM(probe)
                vm.configure(scope: elbStateScope())
                await vm.loadLoadBalancers()
                await vm.loadTargetGroups()
                vm.selectedLoadBalancer = vm.loadBalancers[0]
                vm.selectedTargetGroup = vm.targetGroups[0]
                await listenersGate.waitForEntry()
                await targetsGate.waitForEntry()
                let waiting = Task { await vm.waitForDetails() }
                await Task.yield()
                if reset { vm.reset() }
                else {
                    vm.selectedLoadBalancer = vm.loadBalancers[1]
                    vm.selectedTargetGroup = vm.targetGroups[1]
                    await vm.waitForDetails()
                }
                await listenersGate.open()
                await targetsGate.open()
                await waiting.value
                XCTAssertEqual(vm.listeners.isEmpty, reset)
                XCTAssertEqual(vm.targets.isEmpty, reset)
                if !reset {
                    XCTAssertEqual(vm.listeners.first?.loadBalancerARN, vm.selectedLoadBalancer?.arn)
                    XCTAssertEqual(vm.targets.first?.description, "two")
                }
                XCTAssertNil(vm.listenersError)
                XCTAssertNil(vm.targetsError)
            }
        }
    }

    func testLateRulesCannotCrossListenerScopeOrCancel() async {
        for failure in [false, true] {
            for change in ["listener", "scope", "cancel"] {
                let gate = TestGate()
                let probe = ELBStateProbe(gates: [.rules: gate], failures: failure ? [.rules: [1]] : [:])
                let vm = makeVM(probe)
                vm.configure(scope: elbStateScope())
                await vm.loadLoadBalancers()
                vm.selectedLoadBalancer = vm.loadBalancers[0]
                await vm.waitForDetails()
                vm.selectedListener = vm.listeners[0]
                await gate.waitForEntry()
                let waiting = Task { await vm.waitForDetails() }
                await Task.yield()
                if change == "listener" {
                    vm.selectedListener = vm.listeners[1]
                    await vm.waitForDetails()
                } else if change == "scope" { vm.configure(scope: elbStateScope(region: "eu-west-1")) }
                else { vm.cancelDetails() }
                await gate.open()
                await waiting.value
                if change == "listener" {
                    XCTAssertEqual(vm.rules.first?.arn, elbStateRule(listener: vm.selectedListener!).arn)
                    XCTAssertNil(vm.rulesError)
                } else {
                    XCTAssertTrue(vm.rules.isEmpty)
                    XCTAssertEqual(vm.rulesError != nil, change == "cancel")
                }
                XCTAssertFalse(vm.isRulesLoading)
            }
        }
    }

    func testMismatchedScopeListsListenersAndRuleParentsAreRejected() async {
        let scope = elbStateScope()
        let other = elbStateScope(region: "eu-west-1")
        let badLists = ELBStateProbe(loadBalancerRows: [elbStateLB("one", scope: other)], groupRows: [elbStateGroup("one", scope: other)])
        let badVM = makeVM(badLists)
        badVM.configure(scope: scope)
        await badVM.loadLoadBalancers()
        await badVM.loadTargetGroups()
        XCTAssertTrue(badVM.loadBalancers.isEmpty)
        XCTAssertTrue(badVM.targetGroups.isEmpty)
        XCTAssertEqual(badVM.loadBalancersError, ELBError.invalidResponse.localizedDescription)
        XCTAssertEqual(badVM.targetGroupsError, ELBError.invalidResponse.localizedDescription)

        let mismatched = ELBStateProbe(listenerRows: [elbStateListener(parent: elbStateLB("other"))])
        let vm = makeVM(mismatched)
        vm.configure(scope: scope)
        await vm.loadLoadBalancers()
        vm.selectedLoadBalancer = vm.loadBalancers[0]
        await vm.waitForDetails()
        XCTAssertTrue(vm.listeners.isEmpty)
        XCTAssertEqual(vm.listenersError, ELBError.invalidResponse.localizedDescription)

        for rule in [elbStateRule(listener: elbStateListener(parent: elbStateLB("other"))),
                     elbStateRule(listener: elbStateListener(parent: elbStateLB("one", scope: other)))] {
            let probe = ELBStateProbe(ruleRows: [rule])
            let vm = makeVM(probe)
            vm.configure(scope: scope)
            await vm.loadLoadBalancers()
            vm.selectedLoadBalancer = vm.loadBalancers[0]
            await vm.waitForDetails()
            vm.selectedListener = vm.listeners[0]
            await vm.waitForDetails()
            XCTAssertTrue(vm.rules.isEmpty)
            XCTAssertEqual(vm.rulesError, ELBError.invalidResponse.localizedDescription)
        }
    }

    func testUnknownFailuresAreSanitizedInEverySection() async {
        let probe = ELBStateProbe(failures: [.loadBalancers: [2], .targetGroups: [2], .listeners: [2], .rules: [1], .targets: [1]], unknownError: true)
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope())
        await vm.loadLoadBalancers()
        await vm.loadTargetGroups()
        vm.selectedLoadBalancer = vm.loadBalancers[0]
        vm.selectedTargetGroup = vm.targetGroups[0]
        await vm.waitForDetails()
        vm.selectedListener = vm.listeners[0]
        await vm.waitForDetails()
        XCTAssertEqual(vm.rulesError, "Unable to load load balancing data. Refresh to try again.")
        XCTAssertEqual(vm.targetsError, vm.rulesError)
        vm.refreshListeners()
        await vm.waitForDetails()
        XCTAssertEqual(vm.listenersError, vm.targetsError)
        await vm.loadLoadBalancers()
        await vm.loadTargetGroups()
        XCTAssertTrue(vm.loadBalancersError?.hasPrefix("Unable to load load balancing data.") == true)
        XCTAssertTrue(vm.targetGroupsError?.hasPrefix("Unable to load load balancing data.") == true)
        XCTAssertFalse(vm.loadBalancersError?.contains("sensitive-test") == true)
    }

    func testCancellingOwnedAsyncListInvalidatesItsLateResult() async {
        for targetGroups in [false, true] {
            let gate = TestGate()
            let probe = ELBStateProbe(gates: [targetGroups ? .targetGroups : .loadBalancers: gate])
            let vm = makeVM(probe)
            vm.configure(scope: elbStateScope())
            let owned = Task {
                if targetGroups { await vm.loadTargetGroups() }
                else { await vm.loadLoadBalancers() }
            }
            await gate.waitForEntry()
            owned.cancel()
            await Task.yield()
            await gate.open()
            await owned.value
            XCTAssertTrue(targetGroups ? vm.targetGroups.isEmpty : vm.loadBalancers.isEmpty)
            XCTAssertFalse(targetGroups ? vm.isTargetGroupsLoading : vm.isLoadBalancersLoading)
            XCTAssertTrue((targetGroups ? vm.targetGroupsError : vm.loadBalancersError)?.contains("cancelled") == true)
        }
    }

    func testCancelledSupersededAsyncCallerCannotCancelNewerRefresh() async {
        for targetGroups in [false, true] {
            let first = TestGate()
            let second = TestGate()
            let part: ELBStatePart = targetGroups ? .targetGroups : .loadBalancers
            let probe = ELBStateProbe(gates: [part: first], secondGates: [part: second])
            let vm = makeVM(probe)
            vm.configure(scope: elbStateScope())
            let owned = Task {
                if targetGroups { await vm.loadTargetGroups() }
                else { await vm.loadLoadBalancers() }
            }
            await first.waitForEntry()
            if targetGroups { vm.refreshTargetGroups() }
            else { vm.refreshLoadBalancers() }
            await second.waitForEntry()
            owned.cancel()
            await first.open()
            await owned.value
            XCTAssertTrue(targetGroups ? vm.isTargetGroupsLoading : vm.isLoadBalancersLoading)
            await second.open()
            if targetGroups { await vm.waitForTargetGroups() }
            else { await vm.waitForLoadBalancers() }
            XCTAssertFalse(targetGroups ? vm.targetGroups.isEmpty : vm.loadBalancers.isEmpty)
            XCTAssertNil(targetGroups ? vm.targetGroupsError : vm.loadBalancersError)
        }
    }

    func testCancelledSharedAsyncWaiterDoesNotCancelExistingList() async {
        for targetGroups in [false, true] {
            let gate = TestGate()
            let probe = ELBStateProbe(gates: [targetGroups ? .targetGroups : .loadBalancers: gate])
            let vm = makeVM(probe)
            vm.configure(scope: elbStateScope())
            if targetGroups { vm.refreshTargetGroups() }
            else { vm.refreshLoadBalancers() }
            await gate.waitForEntry()
            let waiter = Task {
                if targetGroups { await vm.loadTargetGroups() }
                else { await vm.loadLoadBalancers() }
            }
            await Task.yield()
            waiter.cancel()
            await Task.yield()
            XCTAssertTrue(targetGroups ? vm.isTargetGroupsLoading : vm.isLoadBalancersLoading)
            await gate.open()
            await waiter.value
            if targetGroups { await vm.waitForTargetGroups() }
            else { await vm.waitForLoadBalancers() }
            XCTAssertFalse(targetGroups ? vm.targetGroups.isEmpty : vm.loadBalancers.isEmpty)
            XCTAssertNil(targetGroups ? vm.targetGroupsError : vm.loadBalancersError)
        }
    }

    private func makeVM(_ probe: ELBStateProbe) -> ELBViewModel {
        ELBViewModel(loadBalancerLoader: { try await probe.loadBalancers($0) }, targetGroupLoader: { try await probe.targetGroups($0) },
                     listenerLoader: { try await probe.listeners($0, $1) }, ruleLoader: { try await probe.rules($0, $1) },
                     healthLoader: { try await probe.targets($0, $1) })
    }
}

func elbStateScope(profile: String = "work", account: String = "111122223333", region: String = "us-east-1", role: String = "ReadOnly",
                   paths: AWSConfigurationPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/elb-config"])) -> MonitoringScope {
    MonitoringScope(profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
                    identity: AWSIdentity(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/test", userID: "test"),
                    region: region, paths: paths)
}

func elbStateLB(_ name: String, kind: String = "app", scope: MonitoringScope = elbStateScope()) -> ELBLoadBalancer {
    ELBLoadBalancer(arn: "arn:aws:elasticloadbalancing:\(scope.region):\(scope.accountID):loadbalancer/\(kind)/\(name)/1234567890abcdef",
                    name: name, kind: kind == "app" ? "application" : kind == "net" ? "network" : "gateway")
}

func elbStateGroup(_ name: String, type: String = "instance", scope: MonitoringScope = elbStateScope()) -> ELBTargetGroup {
    ELBTargetGroup(arn: "arn:aws:elasticloadbalancing:\(scope.region):\(scope.accountID):targetgroup/\(name)/1234567890abcdef", name: name, targetType: type)
}

private func elbStateListener(parent: ELBLoadBalancer, suffix: String = "listener1") -> ELBListener {
    ELBListener(arn: parent.arn.replacingOccurrences(of: ":loadbalancer/", with: ":listener/") + "/\(suffix)",
                loadBalancerARN: parent.arn, protocolName: "HTTPS", port: 443)
}

private func elbStateRule(listener: ELBListener) -> ELBRule {
    ELBRule(arn: listener.arn.replacingOccurrences(of: ":listener/", with: ":listener-rule/") + "/rule1", priority: "default", isDefault: true)
}

private enum ELBStatePart: Int, Sendable { case loadBalancers, targetGroups, listeners, rules, targets }
private enum ELBStateUnknownError: LocalizedError {
    case failed
    var errorDescription: String? { "sensitive-test-marker must not be exposed" }
}

private actor ELBStateProbe {
    private var calls = [0, 0, 0, 0, 0]
    private let gates: [ELBStatePart: TestGate]
    private let secondGates: [ELBStatePart: TestGate]
    private let failures: [ELBStatePart: Set<Int>]
    private let unknownError: Bool
    private let loadBalancerRows: [ELBLoadBalancer]?
    private let groupRows: [ELBTargetGroup]?
    private let listenerRows: [ELBListener]?
    private let ruleRows: [ELBRule]?

    init(loadBalancerRows: [ELBLoadBalancer]? = nil, groupRows: [ELBTargetGroup]? = nil, listenerRows: [ELBListener]? = nil,
         ruleRows: [ELBRule]? = nil, gates: [ELBStatePart: TestGate] = [:], secondGates: [ELBStatePart: TestGate] = [:],
         failures: [ELBStatePart: Set<Int>] = [:], unknownError: Bool = false) {
        self.loadBalancerRows = loadBalancerRows
        self.groupRows = groupRows
        self.listenerRows = listenerRows
        self.ruleRows = ruleRows
        self.gates = gates
        self.secondGates = secondGates
        self.failures = failures
        self.unknownError = unknownError
    }
    func counts() -> [Int] { calls }
    private func enter(_ part: ELBStatePart) async throws {
        calls[part.rawValue] += 1
        let count = calls[part.rawValue]
        if count == 1 { await gates[part]?.wait() }
        if count == 2 { await secondGates[part]?.wait() }
        if failures[part]?.contains(count) == true {
            if unknownError { throw ELBStateUnknownError.failed }
            throw ELBError.invalidResponse
        }
    }
    func loadBalancers(_ scope: MonitoringScope) async throws -> [ELBLoadBalancer] {
        try await enter(.loadBalancers)
        return loadBalancerRows ?? [elbStateLB("one", scope: scope), elbStateLB("two", scope: scope)]
    }
    func targetGroups(_ scope: MonitoringScope) async throws -> [ELBTargetGroup] {
        try await enter(.targetGroups)
        return groupRows ?? [elbStateGroup("one", scope: scope), elbStateGroup("two", scope: scope)]
    }
    func listeners(_ scope: MonitoringScope, _ parent: ELBLoadBalancer) async throws -> [ELBListener] {
        try await enter(.listeners)
        return listenerRows ?? [elbStateListener(parent: parent), elbStateListener(parent: parent, suffix: "listener2")]
    }
    func rules(_ scope: MonitoringScope, _ listener: ELBListener) async throws -> [ELBRule] {
        try await enter(.rules)
        return ruleRows ?? [elbStateRule(listener: listener)]
    }
    func targets(_ scope: MonitoringScope, _ group: ELBTargetGroup) async throws -> [ELBTargetHealth] {
        try await enter(.targets)
        return [ELBTargetHealth(targetID: "i-12345678", port: 8080, state: "healthy", description: group.name)]
    }
}
