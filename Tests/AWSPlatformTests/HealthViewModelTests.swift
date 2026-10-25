import XCTest
@testable import AWSPlatform

@MainActor
final class HealthViewModelTests: XCTestCase {
    func testUnconfiguredAndConfigureAloneNeverQuery() async {
        let probe = HealthStateProbe()
        let vm = makeViewModel(probe)
        vm.loadIfNeeded()
        vm.refresh()
        vm.refreshDetails()
        await vm.loadEvents()
        vm.configure(scope: healthStateScope())
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0])
        XCTAssertNil(vm.selectedEvent)
        XCTAssertFalse(vm.isLoading)
    }

    func testInvalidScopeNeverReachesAnyLoader() async {
        let probe = HealthStateProbe()
        let vm = makeViewModel(probe)
        for scope in [healthStateScope(account: ""), healthStateScope(principalARN: ""),
                      healthStateScope(principalARN: "arn:aws:sts::999988887777:assumed-role/ReadOnly/session")] {
            vm.configure(scope: scope)
            vm.loadIfNeeded()
            await vm.loadEvents()
            vm.refreshDetails()
            XCTAssertEqual(vm.error, HealthError.invalidScope.localizedDescription)
            XCTAssertFalse(vm.isLoading)
            XCTAssertTrue(vm.events.isEmpty)
        }
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0])
    }

    func testFirstVisitDeduplicatesAndNeverAutoSelects() async {
        let gate = TestGate()
        let probe = HealthStateProbe(firstListGate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.loadIfNeeded()
        let joined = Task { await vm.loadEvents() }
        await Task.yield()
        await gate.open()
        await joined.value
        await vm.waitForCurrentLoad()
        vm.loadIfNeeded()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0])
        XCTAssertEqual(vm.events.count, 2)
        XCTAssertNil(vm.selectedEvent)
    }

    func testEmptyCompleteListDoesNotReloadOnReentry() async {
        let probe = HealthStateProbe(listResults: [[]])
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        vm.loadIfNeeded()
        await vm.waitForCurrentLoad()
        vm.loadIfNeeded()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0])
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertNil(vm.error)
    }

    func testSelectionLoadsDetailsAndEntitiesOnlyOnce() async {
        let probe = HealthStateProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        await vm.loadEvents()
        vm.selectedEvent = vm.events[0]
        await vm.waitForDetails()
        vm.selectedEvent = vm.events[0]
        await vm.waitForDetails()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1])
        XCTAssertEqual(vm.details?.event, vm.selectedEvent)
        XCTAssertEqual(vm.entities.first?.value, "maintenance")
        XCTAssertFalse(vm.isDetailLoading)
        XCTAssertFalse(vm.isEntitiesLoading)
    }

    func testUnlistedOrModifiedEventCannotTriggerDetails() async {
        let probe = HealthStateProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        await vm.loadEvents()
        vm.selectedEvent = healthStateEvent("unlisted")
        await vm.waitForDetails()
        XCTAssertNil(vm.selectedEvent)
        let modified = healthStateEvent("maintenance", service: "UnexpectedService")
        vm.selectedEvent = modified
        await vm.waitForDetails()
        XCTAssertNil(vm.selectedEvent)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0])
    }

    func testFailuresRequireExplicitRetryAndUnknownErrorIsSanitized() async {
        let probe = HealthStateProbe(listFailures: [1], useUnknownError: true)
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        vm.loadIfNeeded()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.error, "Unable to load AWS Health data. Refresh to try again.")
        vm.loadIfNeeded()
        let beforeRetry = await probe.counts()
        XCTAssertEqual(beforeRetry, [1, 0, 0])
        await vm.loadEvents()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.events.count, 2)
        let afterRetry = await probe.counts()
        XCTAssertEqual(afterRetry, [2, 0, 0])
    }

    func testSanitizedServiceErrorsKeepActionableSupportAndPermissionMessages() async {
        for error in [AWSHealthService.RequestError.subscriptionRequired, .listPermission, .credentials] {
            let vm = HealthViewModel(listLoader: { _ in throw error },
                                     detailLoader: { _, _ in throw HealthError.invalidResponse },
                                     entityLoader: { _, _ in [] })
            vm.configure(scope: healthStateScope())
            await vm.loadEvents()
            XCTAssertEqual(vm.error, error.localizedDescription)
            XCTAssertTrue(vm.events.isEmpty)
        }
    }

    func testSameScopeConfigurePreservesInflightListAndFilters() async {
        let gate = TestGate()
        let probe = HealthStateProbe(firstListGate: gate)
        let vm = makeViewModel(probe)
        let scope = healthStateScope()
        vm.configure(scope: scope)
        vm.searchText = "maintenance"
        vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.configure(scope: scope)
        vm.loadIfNeeded()
        XCTAssertTrue(vm.isLoading)
        XCTAssertEqual(vm.searchText, "maintenance")
        await gate.open()
        await vm.waitForCurrentLoad()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0])
        XCTAssertEqual(vm.events.count, 2)
    }

    func testSameScopePreservesSelectionAndInflightDetails() async {
        let detailsGate = TestGate()
        let entitiesGate = TestGate()
        let probe = HealthStateProbe(firstDetailGate: detailsGate, firstEntityGate: entitiesGate)
        let vm = makeViewModel(probe)
        let scope = healthStateScope()
        vm.configure(scope: scope)
        await vm.loadEvents()
        vm.selectedEvent = vm.events[0]
        await detailsGate.waitForEntry()
        await entitiesGate.waitForEntry()
        vm.configure(scope: scope)
        XCTAssertEqual(vm.selectedEvent?.typeCode, "maintenance")
        XCTAssertTrue(vm.isDetailLoading)
        XCTAssertTrue(vm.isEntitiesLoading)
        await detailsGate.open()
        await entitiesGate.open()
        await vm.waitForDetails()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1])
        XCTAssertNotNil(vm.details)
        XCTAssertEqual(vm.entities.count, 1)
    }

    func testProfileIdentityAndConfigurationChangesClearAllState() async {
        let probe = HealthStateProbe()
        let vm = makeViewModel(probe)
        let scopes = [
            healthStateScope(), healthStateScope(profile: "personal"),
            healthStateScope(account: "444455556666"), healthStateScope(role: "OtherRole"),
            healthStateScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/health-other-config"])),
            healthStateScope(paths: AWSConfigurationPaths(environment: ["AWS_SHARED_CREDENTIALS_FILE": "/tmp/health-other-credentials"]))
        ]
        for scope in scopes {
            vm.configure(scope: scope)
            XCTAssertTrue(vm.events.isEmpty)
            XCTAssertNil(vm.selectedEvent)
            XCTAssertNil(vm.details)
            XCTAssertTrue(vm.entities.isEmpty)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertEqual(vm.statusFilter, "All")
            XCTAssertEqual(vm.categoryFilter, "All")
            XCTAssertEqual(vm.serviceFilter, "All")
            XCTAssertEqual(vm.regionFilter, "All")
            XCTAssertNil(vm.error)
            XCTAssertNil(vm.detailError)
            XCTAssertNil(vm.entitiesError)
            vm.loadIfNeeded()
            await vm.waitForCurrentLoad()
            vm.selectedEvent = vm.events[0]
            await vm.waitForDetails()
            vm.searchText = "maintenance"
            vm.statusFilter = "open"
            vm.categoryFilter = "scheduledChange"
            vm.serviceFilter = "EC2"
            vm.regionFilter = "us-east-1"
        }
        let counts = await probe.counts()
        XCTAssertEqual(counts, [scopes.count, scopes.count, scopes.count])
        vm.configure(scope: nil)
        vm.loadIfNeeded()
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertNil(vm.selectedEvent)
        XCTAssertNil(vm.details)
        XCTAssertTrue(vm.entities.isEmpty)
        let afterClear = await probe.counts()
        XCTAssertEqual(afterClear, counts)
    }

    func testLocalSearchAndFourFiltersNeverQuery() async {
        let maintenance = healthStateEvent("maintenance", availabilityZone: "us-east-1a")
        let incident = healthStateEvent("incident", service: "RDS", category: "issue", status: "closed", region: "eu-west-1")
        let probe = HealthStateProbe(listResults: [[maintenance, incident]])
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        await vm.loadEvents()
        XCTAssertEqual(vm.availableStatuses, ["All", "closed", "open"])
        XCTAssertEqual(vm.availableCategories, ["All", "issue", "scheduledChange"])
        XCTAssertEqual(vm.availableServices, ["All", "EC2", "RDS"])
        XCTAssertEqual(vm.availableRegions, ["All", "eu-west-1", "us-east-1"])
        for query in [" MAINTENANCE ", "ec2", "scheduledchange", "OPEN", "us-east-1a", "/maintenance/"] {
            vm.searchText = query
            XCTAssertEqual(vm.filteredEvents, [maintenance], query)
        }
        vm.searchText = ""
        vm.statusFilter = "CLOSED"
        XCTAssertEqual(vm.filteredEvents, [incident])
        vm.statusFilter = "All"
        vm.categoryFilter = "ISSUE"
        XCTAssertEqual(vm.filteredEvents, [incident])
        vm.categoryFilter = "All"
        vm.serviceFilter = "rds"
        XCTAssertEqual(vm.filteredEvents, [incident])
        vm.serviceFilter = "All"
        vm.regionFilter = "EU-WEST-1"
        XCTAssertEqual(vm.filteredEvents, [incident])
        vm.statusFilter = "open"
        XCTAssertTrue(vm.filteredEvents.isEmpty)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0])
    }

    func testFutureEventsRemainVisible() async {
        var future = healthStateEvent("upcoming")
        future.startTime = Date().addingTimeInterval(365 * 86_400)
        let probe = HealthStateProbe(listResults: [[future]])
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        await vm.loadEvents()
        XCTAssertEqual(vm.filteredEvents, [future])
    }

    func testOldScopeListSuccessAndFailureCannotReplaceNewScope() async {
        for shouldFail in [false, true] {
            let gate = TestGate()
            let probe = HealthStateProbe(listResults: [[healthStateEvent("old")], [healthStateEvent("new")]],
                                         firstListGate: gate, listFailures: shouldFail ? [1] : [])
            let vm = makeViewModel(probe)
            vm.configure(scope: healthStateScope())
            vm.loadIfNeeded()
            await gate.waitForEntry()
            let waiting = Task { await vm.waitForCurrentLoad() }
            await Task.yield()
            vm.configure(scope: healthStateScope(profile: "other"))
            vm.loadIfNeeded()
            await vm.waitForCurrentLoad()
            await gate.open()
            await waiting.value
            XCTAssertEqual(vm.events.map(\.typeCode), ["new"])
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testResetRejectsLateListSuccessAndFailure() async {
        for shouldFail in [false, true] {
            let gate = TestGate()
            let probe = HealthStateProbe(firstListGate: gate, listFailures: shouldFail ? [1] : [])
            let vm = makeViewModel(probe)
            vm.configure(scope: healthStateScope())
            vm.loadIfNeeded()
            await gate.waitForEntry()
            let waiting = Task { await vm.waitForCurrentLoad() }
            await Task.yield()
            vm.reset()
            await gate.open()
            await waiting.value
            XCTAssertNil(vm.scope)
            XCTAssertTrue(vm.events.isEmpty)
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testExplicitRefreshReplacesInflightListInSameScope() async {
        let gate = TestGate()
        let probe = HealthStateProbe(listResults: [[healthStateEvent("old")], [healthStateEvent("new")]], firstListGate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        let waiting = Task { await vm.waitForCurrentLoad() }
        await Task.yield()
        vm.refresh()
        await vm.waitForCurrentLoad()
        await gate.open()
        await waiting.value
        XCTAssertEqual(vm.events.map(\.typeCode), ["new"])
        XCTAssertNil(vm.error)
    }

    func testCancellationBeforeListStartsNeverCallsLoader() async {
        let probe = HealthStateProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        vm.loadIfNeeded()
        vm.cancelLoading()
        await Task.yield()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0])
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertTrue(vm.error?.contains("cancelled") == true)
    }

    func testCancelledListRejectsLateResultAndRequiresExplicitRetry() async {
        let gate = TestGate()
        let probe = HealthStateProbe(firstListGate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        let waiting = Task { await vm.waitForCurrentLoad() }
        await Task.yield()
        vm.cancelLoading()
        await gate.open()
        await waiting.value
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.error?.contains("cancelled") == true)
        vm.loadIfNeeded()
        let beforeRetry = await probe.counts()
        XCTAssertEqual(beforeRetry, [1, 0, 0])
        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.events.count, 2)
        XCTAssertNil(vm.error)
    }

    func testDetailsAndEntitiesFailuresAreIndependentAndRetryable() async {
        let probe = HealthStateProbe(detailFailures: [1], entityFailures: [2])
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        await vm.loadEvents()
        vm.selectedEvent = vm.events[0]
        await vm.waitForDetails()
        XCTAssertNil(vm.details)
        XCTAssertEqual(vm.detailError, HealthError.invalidResponse.localizedDescription)
        XCTAssertEqual(vm.entities.count, 1)
        XCTAssertNil(vm.entitiesError)
        XCTAssertNil(vm.error)
        XCTAssertNotNil(vm.selectedEvent)
        vm.refreshDetails()
        await vm.waitForDetails()
        XCTAssertNotNil(vm.details)
        XCTAssertNil(vm.detailError)
        XCTAssertTrue(vm.entities.isEmpty)
        XCTAssertEqual(vm.entitiesError, HealthError.invalidResponse.localizedDescription)
        XCTAssertNil(vm.error)
        XCTAssertNotNil(vm.selectedEvent)
    }

    func testUnknownDetailErrorsDoNotExposeRawDescription() async {
        let probe = HealthStateProbe(detailFailures: [1], entityFailures: [1], useUnknownError: true)
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        await vm.loadEvents()
        vm.selectedEvent = vm.events[0]
        await vm.waitForDetails()
        XCTAssertEqual(vm.detailError, "Unable to load AWS Health data. Refresh to try again.")
        XCTAssertEqual(vm.entitiesError, vm.detailError)
        XCTAssertNil(vm.error)
    }

    func testOldSelectionDetailsAndEntitiesSuccessAndFailureCannotPublish() async {
        for shouldFail in [false, true] {
            let detailsGate = TestGate()
            let entitiesGate = TestGate()
            let probe = HealthStateProbe(firstDetailGate: detailsGate, firstEntityGate: entitiesGate,
                                         detailFailures: shouldFail ? [1] : [], entityFailures: shouldFail ? [1] : [])
            let vm = makeViewModel(probe)
            vm.configure(scope: healthStateScope())
            await vm.loadEvents()
            vm.selectedEvent = vm.events[0]
            await detailsGate.waitForEntry()
            await entitiesGate.waitForEntry()
            let waiting = Task { await vm.waitForDetails() }
            await Task.yield()
            vm.selectedEvent = vm.events[1]
            await vm.waitForDetails()
            await detailsGate.open()
            await entitiesGate.open()
            await waiting.value
            XCTAssertEqual(vm.details?.event.typeCode, "incident")
            XCTAssertEqual(vm.entities.first?.value, "incident")
            XCTAssertNil(vm.detailError)
            XCTAssertNil(vm.entitiesError)
            XCTAssertFalse(vm.isDetailLoading)
            XCTAssertFalse(vm.isEntitiesLoading)
        }
    }

    func testResetRejectsLateDetailsAndEntitiesSuccessAndFailure() async {
        for shouldFail in [false, true] {
            let detailsGate = TestGate()
            let entitiesGate = TestGate()
            let probe = HealthStateProbe(firstDetailGate: detailsGate, firstEntityGate: entitiesGate,
                                         detailFailures: shouldFail ? [1] : [], entityFailures: shouldFail ? [1] : [])
            let vm = makeViewModel(probe)
            vm.configure(scope: healthStateScope())
            await vm.loadEvents()
            vm.selectedEvent = vm.events[0]
            await detailsGate.waitForEntry()
            await entitiesGate.waitForEntry()
            let waiting = Task { await vm.waitForDetails() }
            await Task.yield()
            vm.reset()
            await detailsGate.open()
            await entitiesGate.open()
            await waiting.value
            XCTAssertNil(vm.scope)
            XCTAssertNil(vm.selectedEvent)
            XCTAssertNil(vm.details)
            XCTAssertTrue(vm.entities.isEmpty)
            XCTAssertNil(vm.detailError)
            XCTAssertNil(vm.entitiesError)
            XCTAssertFalse(vm.isDetailLoading)
            XCTAssertFalse(vm.isEntitiesLoading)
        }
    }

    func testProfileChangeRejectsOldDetailsEvenWhenNewEventARNMatches() async {
        for shouldFail in [false, true] {
            let detailsGate = TestGate()
            let entitiesGate = TestGate()
            let probe = HealthStateProbe(firstDetailGate: detailsGate, firstEntityGate: entitiesGate,
                                         detailFailures: shouldFail ? [1] : [], entityFailures: shouldFail ? [1] : [])
            let vm = makeViewModel(probe)
            vm.configure(scope: healthStateScope())
            await vm.loadEvents()
            vm.selectedEvent = vm.events[0]
            await detailsGate.waitForEntry()
            await entitiesGate.waitForEntry()
            let waiting = Task { await vm.waitForDetails() }
            await Task.yield()
            vm.configure(scope: healthStateScope(profile: "other"))
            await vm.loadEvents()
            vm.selectedEvent = vm.events[0]
            await vm.waitForDetails()
            await detailsGate.open()
            await entitiesGate.open()
            await waiting.value
            XCTAssertEqual(vm.details?.description, "other maintenance")
            XCTAssertEqual(vm.entities.first?.id, "other maintenance")
            XCTAssertNil(vm.detailError)
            XCTAssertNil(vm.entitiesError)
        }
    }

    func testCancellationBeforeDetailsStartNeverCallsLoaders() async {
        let probe = HealthStateProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        await vm.loadEvents()
        vm.selectedEvent = vm.events[0]
        vm.cancelDetails()
        await Task.yield()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0])
        XCTAssertNil(vm.details)
        XCTAssertTrue(vm.entities.isEmpty)
        XCTAssertTrue(vm.detailError?.contains("cancelled") == true)
        XCTAssertTrue(vm.entitiesError?.contains("cancelled") == true)
        XCTAssertFalse(vm.isDetailLoading)
        XCTAssertFalse(vm.isEntitiesLoading)
    }

    func testCancelDetailsPreservesCompletedSectionAndRejectsPendingResult() async {
        let entitiesGate = TestGate()
        let probe = HealthStateProbe(firstEntityGate: entitiesGate)
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        await vm.loadEvents()
        vm.selectedEvent = vm.events[0]
        await entitiesGate.waitForEntry()
        while vm.isDetailLoading { await Task.yield() }
        let waiting = Task { await vm.waitForDetails() }
        await Task.yield()
        vm.cancelDetails()
        await entitiesGate.open()
        await waiting.value
        XCTAssertNotNil(vm.details)
        XCTAssertNil(vm.detailError)
        XCTAssertTrue(vm.entities.isEmpty)
        XCTAssertTrue(vm.entitiesError?.contains("cancelled") == true)
        vm.refreshDetails()
        await vm.waitForDetails()
        XCTAssertNil(vm.entitiesError)
        XCTAssertEqual(vm.entities.count, 1)
    }

    func testListRefreshUpdatesSelectedHeaderAndClearsRemovedSelection() async {
        let original = healthStateEvent("maintenance")
        let updated = healthStateEvent("maintenance", status: "closed")
        let probe = HealthStateProbe(listResults: [[original], [updated], []])
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        await vm.loadEvents()
        vm.selectedEvent = vm.events[0]
        await vm.waitForDetails()
        vm.statusFilter = "open"
        vm.refresh()
        await vm.waitForCurrentLoad()
        await vm.waitForDetails()
        XCTAssertEqual(vm.selectedEvent, updated)
        XCTAssertEqual(vm.details?.event, updated)
        XCTAssertEqual(vm.statusFilter, "All")
        let selectedCounts = await probe.counts()
        XCTAssertEqual(selectedCounts, [2, 2, 2])
        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertNil(vm.selectedEvent)
        XCTAssertNil(vm.details)
        XCTAssertTrue(vm.entities.isEmpty)
        let removedCounts = await probe.counts()
        XCTAssertEqual(removedCounts, [3, 2, 2])
    }

    func testFailedRefreshPreservesPriorCompleteListAndLabelsStaleData() async {
        let probe = HealthStateProbe(listFailures: [2])
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        await vm.loadEvents()
        let previous = vm.events
        vm.selectedEvent = vm.events[0]
        await vm.waitForDetails()
        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.events, previous)
        XCTAssertEqual(vm.error, "\(HealthError.invalidResponse.localizedDescription) Showing the previous event list; it may be out of date.")
        XCTAssertNotNil(vm.selectedEvent)
        XCTAssertNotNil(vm.details)
        XCTAssertEqual(vm.entities.count, 1)
    }

    func testClearingSelectionImmediatelyClearsDetails() async {
        let probe = HealthStateProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: healthStateScope())
        await vm.loadEvents()
        vm.selectedEvent = vm.events[0]
        await vm.waitForDetails()
        vm.selectedEvent = nil
        XCTAssertNil(vm.details)
        XCTAssertTrue(vm.entities.isEmpty)
        XCTAssertNil(vm.detailError)
        XCTAssertNil(vm.entitiesError)
        vm.refreshDetails()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1])
    }

    private func makeViewModel(_ probe: HealthStateProbe) -> HealthViewModel {
        HealthViewModel(listLoader: { try await probe.list($0) },
                        detailLoader: { try await probe.details($0, $1) },
                        entityLoader: { try await probe.entities($0, $1) })
    }
}

private func healthStateScope(
    profile: String = "work", account: String = "111122223333", role: String = "ReadOnly", principalARN: String? = nil,
    paths: AWSConfigurationPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/health-config"])
) -> HealthScope {
    HealthScope(
        profile: AWSProfile(name: profile, region: "us-east-1", ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
        identity: AWSIdentity(account: account, arn: principalARN ?? "arn:aws:sts::\(account):assumed-role/\(role)/test", userID: "test"),
        paths: paths
    )
}

private func healthStateEvent(
    _ name: String, service: String = "EC2", category: String = "scheduledChange", status: String = "open",
    region: String = "us-east-1", availabilityZone: String? = nil
) -> HealthEvent {
    HealthEvent(arn: "arn:aws:health:us-east-1::event/\(service)/\(name)/example", service: service, typeCode: name,
                category: category, status: status, region: region, availabilityZone: availabilityZone)
}

private enum HealthStateTestError: LocalizedError {
    case unknown
    var errorDescription: String? { "sensitive-test-marker: do not display request details" }
}

private actor HealthStateProbe {
    private var listCalls = 0
    private var detailCalls = 0
    private var entityCalls = 0
    private let listResults: [[HealthEvent]]
    private let firstListGate: TestGate?
    private let firstDetailGate: TestGate?
    private let firstEntityGate: TestGate?
    private let listFailures: Set<Int>
    private let detailFailures: Set<Int>
    private let entityFailures: Set<Int>
    private let useUnknownError: Bool

    init(
        listResults: [[HealthEvent]] = [[healthStateEvent("maintenance"), healthStateEvent("incident", status: "closed")]],
        firstListGate: TestGate? = nil, firstDetailGate: TestGate? = nil, firstEntityGate: TestGate? = nil,
        listFailures: Set<Int> = [], detailFailures: Set<Int> = [], entityFailures: Set<Int> = [], useUnknownError: Bool = false
    ) {
        self.listResults = listResults
        self.firstListGate = firstListGate
        self.firstDetailGate = firstDetailGate
        self.firstEntityGate = firstEntityGate
        self.listFailures = listFailures
        self.detailFailures = detailFailures
        self.entityFailures = entityFailures
        self.useUnknownError = useUnknownError
    }

    func counts() -> [Int] { [listCalls, detailCalls, entityCalls] }

    func list(_ scope: HealthScope) async throws -> [HealthEvent] {
        listCalls += 1
        let call = listCalls
        if call == 1 { await firstListGate?.wait() }
        if listFailures.contains(call) { throw requestError }
        return listResults[min(call - 1, listResults.count - 1)]
    }

    func details(_ scope: HealthScope, _ event: HealthEvent) async throws -> HealthEventDetails {
        detailCalls += 1
        let call = detailCalls
        if call == 1 { await firstDetailGate?.wait() }
        if detailFailures.contains(call) { throw requestError }
        return HealthEventDetails(event: event, description: "\(scope.profileName) \(event.typeCode)")
    }

    func entities(_ scope: HealthScope, _ event: HealthEvent) async throws -> [HealthAffectedEntity] {
        entityCalls += 1
        let call = entityCalls
        if call == 1 { await firstEntityGate?.wait() }
        if entityFailures.contains(call) { throw requestError }
        return [HealthAffectedEntity(id: "\(scope.profileName) \(event.typeCode)", value: event.typeCode, status: "IMPAIRED")]
    }

    private var requestError: Error {
        useUnknownError ? HealthStateTestError.unknown : HealthError.invalidResponse
    }
}
