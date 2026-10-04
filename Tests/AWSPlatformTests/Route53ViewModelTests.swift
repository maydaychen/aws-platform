import XCTest
@testable import AWSPlatform

@MainActor
final class Route53ViewModelTests: XCTestCase {
    func testUnconfiguredAndConfigureAloneNeverQuery() async {
        let probe = Route53StateProbe()
        let vm = makeViewModel(probe)
        vm.loadIfNeeded()
        vm.refresh()
        vm.refreshDetails()
        await vm.loadZones()
        vm.configure(scope: route53StateScope())
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0, 0])
        XCTAssertNil(vm.selectedZone)
        XCTAssertFalse(vm.isLoading)
    }

    func testInvalidScopeNeverReachesLoaders() async {
        let probe = Route53StateProbe()
        let vm = makeViewModel(probe)
        let scopes = [route53StateScope(account: ""), route53StateScope(profile: " "), route53StateScope(principalARN: ""),
                      route53StateScope(principalARN: "arn:aws:sts::999988887777:assumed-role/ReadOnly/session")]
        for scope in scopes {
            vm.configure(scope: scope)
            vm.loadIfNeeded()
            await vm.loadZones()
            vm.refreshDetails()
            XCTAssertEqual(vm.error, Route53Error.invalidScope.localizedDescription)
            XCTAssertFalse(vm.isLoading)
            XCTAssertTrue(vm.zones.isEmpty)
        }
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0, 0])
    }

    func testFirstVisitDeduplicatesAndNeverAutoSelects() async {
        let gate = TestGate()
        let probe = Route53StateProbe(firstListGate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: route53StateScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.loadIfNeeded()
        let joined = Task { await vm.loadZones() }
        await Task.yield()
        await gate.open()
        await joined.value
        await vm.waitForCurrentLoad()
        vm.loadIfNeeded()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
        XCTAssertEqual(vm.zones.count, 2)
        XCTAssertNil(vm.selectedZone)
    }

    func testEmptyListAndFailedLoadDoNotAutoRetryOnReentry() async {
        for failure in [false, true] {
            let probe = Route53StateProbe(listResults: [[]], listFailures: failure ? [1] : [])
            let vm = makeViewModel(probe)
            vm.configure(scope: route53StateScope())
            vm.loadIfNeeded()
            await vm.waitForCurrentLoad()
            vm.loadIfNeeded()
            let counts = await probe.counts()
            XCTAssertEqual(counts, [1, 0, 0, 0])
            XCTAssertTrue(vm.zones.isEmpty)
            XCTAssertFalse(vm.isListStale)
            XCTAssertEqual(vm.error != nil, failure)
            await vm.loadZones()
            let retried = await probe.counts()
            XCTAssertEqual(retried, [2, 0, 0, 0])
            XCTAssertNil(vm.error)
        }
    }

    func testSameScopePreservesInflightListAndFilters() async {
        let gate = TestGate()
        let probe = Route53StateProbe(firstListGate: gate)
        let vm = makeViewModel(probe)
        let scope = route53StateScope()
        vm.configure(scope: scope)
        vm.searchText = "example"
        vm.privateFilter = true
        vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.configure(scope: scope)
        vm.loadIfNeeded()
        XCTAssertTrue(vm.isLoading)
        XCTAssertEqual(vm.searchText, "example")
        XCTAssertEqual(vm.privateFilter, true)
        await gate.open()
        await vm.waitForCurrentLoad()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
    }

    func testSelectionLoadsThreeSectionsOnceAndSameScopePreservesThem() async {
        let probe = Route53StateProbe()
        let vm = makeViewModel(probe)
        let scope = route53StateScope()
        vm.configure(scope: scope)
        await vm.loadZones()
        vm.selectedZone = vm.zones[0]
        await vm.waitForDetails()
        vm.recordSearchText = "example"
        vm.recordTypeFilter = "A"
        vm.selectedZone = vm.zones[0]
        vm.configure(scope: scope)
        vm.loadIfNeeded()
        await vm.waitForDetails()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1, 1])
        XCTAssertEqual(vm.details?.zone, vm.selectedZone)
        XCTAssertEqual(vm.records.count, 1)
        XCTAssertEqual(vm.tags["Zone"], "example.test.")
        XCTAssertEqual(vm.recordSearchText, "example")
        XCTAssertEqual(vm.recordTypeFilter, "A")
        XCTAssertFalse(vm.isDetailsLoading)
        XCTAssertFalse(vm.isRecordsLoading)
        XCTAssertFalse(vm.isTagsLoading)
    }

    func testUnlistedAndModifiedZonesCannotStartDetails() async {
        let probe = Route53StateProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: route53StateScope())
        await vm.loadZones()
        vm.selectedZone = route53StateZone("UNLISTED")
        await vm.waitForDetails()
        XCTAssertNil(vm.selectedZone)
        vm.selectedZone = route53StateZone("ZONE1", name: "forged.test.")
        await vm.waitForDetails()
        XCTAssertNil(vm.selectedZone)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
    }

    func testProfileIdentityAndConfigurationChangesClearAllState() async {
        let probe = Route53StateProbe()
        let vm = makeViewModel(probe)
        let scopes = [route53StateScope(), route53StateScope(profile: "personal"),
                      route53StateScope(account: "444455556666"), route53StateScope(role: "OtherRole"),
                      route53StateScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/route53-other-config"])),
                      route53StateScope(paths: AWSConfigurationPaths(environment: ["AWS_SHARED_CREDENTIALS_FILE": "/tmp/route53-other-credentials"]))]
        for scope in scopes {
            vm.configure(scope: scope)
            XCTAssertTrue(vm.zones.isEmpty)
            XCTAssertNil(vm.selectedZone)
            XCTAssertNil(vm.details)
            XCTAssertTrue(vm.records.isEmpty)
            XCTAssertTrue(vm.tags.isEmpty)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertNil(vm.privateFilter)
            XCTAssertEqual(vm.recordSearchText, "")
            XCTAssertEqual(vm.recordTypeFilter, "All")
            XCTAssertFalse(vm.isListStale)
            vm.loadIfNeeded()
            await vm.waitForCurrentLoad()
            vm.selectedZone = vm.zones[0]
            await vm.waitForDetails()
            vm.searchText = "example"
            vm.privateFilter = true
            vm.recordSearchText = "example"
            vm.recordTypeFilter = "A"
        }
        let counts = await probe.counts()
        XCTAssertEqual(counts, [scopes.count, scopes.count, scopes.count, scopes.count])
        vm.configure(scope: nil)
        vm.loadIfNeeded()
        XCTAssertNil(vm.scope)
        XCTAssertTrue(vm.zones.isEmpty)
        XCTAssertNil(vm.details)
        XCTAssertTrue(vm.records.isEmpty)
        XCTAssertTrue(vm.tags.isEmpty)
        let clearedCounts = await probe.counts()
        XCTAssertEqual(clearedCounts, counts)
    }

    func testZoneSearchAndPrivateFilterAreLocal() async {
        let publicZone = route53StateZone("ZONE1", comment: "Production DNS")
        let privateZone = route53StateZone("ZONE2", name: "internal.test.", isPrivate: true)
        let probe = Route53StateProbe(listResults: [[publicZone, privateZone]])
        let vm = makeViewModel(probe)
        vm.configure(scope: route53StateScope())
        await vm.loadZones()
        for query in [" EXAMPLE.TEST ", "zone1", "production dns"] {
            vm.searchText = query
            XCTAssertEqual(vm.filteredZones, [publicZone], query)
        }
        vm.searchText = ""
        vm.privateFilter = true
        XCTAssertEqual(vm.filteredZones, [privateZone])
        vm.privateFilter = false
        XCTAssertEqual(vm.filteredZones, [publicZone])
        vm.privateFilter = nil
        XCTAssertEqual(vm.filteredZones, [publicZone, privateZone])
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
    }

    func testRecordSearchIncludesValuesAliasIdentifierAndRoutingFields() async {
        let alias = Route53Record(name: "www.example.test.", type: "A", setIdentifier: "eu-primary",
                                  alias: Route53Alias(dnsName: "target.example.test.", hostedZoneID: "ALIASHOST", evaluateTargetHealth: true),
                                  routingPolicy: "Latency", routingFields: [Route53Field(name: "Region", value: "eu-west-1")])
        let txt = Route53Record(name: "example.test.", type: "TXT", ttl: 300, values: ["\"verification-value\""])
        let probe = Route53StateProbe(recordResults: [[alias, txt]])
        let vm = makeViewModel(probe)
        vm.configure(scope: route53StateScope())
        await vm.loadZones()
        vm.selectedZone = vm.zones[0]
        await vm.waitForDetails()
        XCTAssertEqual(vm.availableRecordTypes, ["All", "A", "TXT"])
        for query in [" WWW.EXAMPLE ", "target.example", "aliashost", "EU-PRIMARY", "Latency", "region", "eu-west-1"] {
            vm.recordSearchText = query
            XCTAssertEqual(vm.filteredRecords, [alias], query)
        }
        for query in ["verification-value", "txt", "300"] {
            vm.recordSearchText = query
            XCTAssertEqual(vm.filteredRecords, [txt], query)
        }
        vm.recordSearchText = ""
        vm.recordTypeFilter = "txt"
        XCTAssertEqual(vm.filteredRecords, [txt])
        vm.recordSearchText = "eu-primary"
        XCTAssertTrue(vm.filteredRecords.isEmpty)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1, 1])
    }

    func testListRefreshPreservesMatchingSelectionUpdatesHeaderAndClearsRemovedZone() async {
        let original = route53StateZone("ZONE1")
        let updated = route53StateZone("ZONE1", comment: "Updated description")
        let probe = Route53StateProbe(listResults: [[original], [updated], []])
        let vm = makeViewModel(probe)
        vm.configure(scope: route53StateScope())
        await vm.loadZones()
        vm.selectedZone = vm.zones[0]
        await vm.waitForDetails()
        vm.recordSearchText = "example"
        vm.refresh()
        await vm.waitForCurrentLoad()
        await vm.waitForDetails()
        XCTAssertEqual(vm.selectedZone, updated)
        XCTAssertEqual(vm.details?.zone, updated)
        XCTAssertEqual(vm.recordSearchText, "example")
        let selectedCounts = await probe.counts()
        XCTAssertEqual(selectedCounts, [2, 2, 2, 2])
        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertNil(vm.selectedZone)
        XCTAssertNil(vm.details)
        XCTAssertTrue(vm.records.isEmpty)
        XCTAssertTrue(vm.tags.isEmpty)
        XCTAssertEqual(vm.recordSearchText, "")
        let removedCounts = await probe.counts()
        XCTAssertEqual(removedCounts, [3, 2, 2, 2])
    }

    func testFailedRefreshPreservesCompleteListMarksStaleAndSuccessClearsStale() async {
        for previousZones in [[], [route53StateZone("ZONE1")]] {
            let probe = Route53StateProbe(listResults: [previousZones], listFailures: [2])
            let vm = makeViewModel(probe)
            vm.configure(scope: route53StateScope())
            await vm.loadZones()
            XCTAssertFalse(vm.isListStale)
            vm.refresh()
            await vm.waitForCurrentLoad()
            XCTAssertEqual(vm.zones, previousZones)
            XCTAssertTrue(vm.isListStale)
            XCTAssertTrue(vm.error?.contains("previous hosted zone list") == true)
            vm.refresh()
            await vm.waitForCurrentLoad()
            XCTAssertFalse(vm.isListStale)
            XCTAssertNil(vm.error)
        }
    }

    func testOldListSuccessAndFailureCannotPublishAfterScopeChangeOrReset() async {
        for shouldFail in [false, true] {
            for reset in [false, true] {
                let gate = TestGate()
                let probe = Route53StateProbe(listResults: [[route53StateZone("OLD")], [route53StateZone("NEW")]],
                                              firstListGate: gate, listFailures: shouldFail ? [1] : [])
                let vm = makeViewModel(probe)
                vm.configure(scope: route53StateScope())
                vm.loadIfNeeded()
                await gate.waitForEntry()
                let waiting = Task { await vm.waitForCurrentLoad() }
                await Task.yield()
                if reset { vm.reset() }
                else {
                    vm.configure(scope: route53StateScope(profile: "other"))
                    await vm.loadZones()
                }
                await gate.open()
                await waiting.value
                XCTAssertEqual(vm.zones.map(\.id), reset ? [] : ["NEW"])
                XCTAssertNil(vm.error)
                XCTAssertFalse(vm.isLoading)
                XCTAssertFalse(vm.isListStale)
            }
        }
    }

    func testNewRefreshWinsOverPendingOldListInSameScope() async {
        let gate = TestGate()
        let probe = Route53StateProbe(listResults: [[route53StateZone("OLD")], [route53StateZone("NEW")]], firstListGate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: route53StateScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        let waiting = Task { await vm.waitForCurrentLoad() }
        await Task.yield()
        vm.refresh()
        await vm.waitForCurrentLoad()
        await gate.open()
        await waiting.value
        XCTAssertEqual(vm.zones.map(\.id), ["NEW"])
        XCTAssertNil(vm.error)
    }

    func testImmediateCancellationCallsNoLoaders() async {
        let probe = Route53StateProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: route53StateScope())
        vm.loadIfNeeded()
        vm.cancelLoading()
        await Task.yield()
        let firstCounts = await probe.counts()
        XCTAssertEqual(firstCounts, [0, 0, 0, 0])
        XCTAssertTrue(vm.error?.contains("cancelled") == true)
        XCTAssertFalse(vm.isLoading)
        vm.refresh()
        await vm.waitForCurrentLoad()
        vm.selectedZone = vm.zones[0]
        vm.cancelDetails()
        await Task.yield()
        let nextCounts = await probe.counts()
        XCTAssertEqual(nextCounts, [1, 0, 0, 0])
        XCTAssertTrue(vm.detailsError?.contains("cancelled") == true)
        XCTAssertTrue(vm.recordsError?.contains("cancelled") == true)
        XCTAssertTrue(vm.tagsError?.contains("cancelled") == true)
        XCTAssertFalse(vm.isDetailsLoading)
        XCTAssertFalse(vm.isRecordsLoading)
        XCTAssertFalse(vm.isTagsLoading)
    }

    func testCancelledPendingListCannotPublishAndReentryDoesNotRetry() async {
        let gate = TestGate()
        let probe = Route53StateProbe(firstListGate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: route53StateScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        let waiting = Task { await vm.waitForCurrentLoad() }
        await Task.yield()
        vm.cancelLoading()
        await gate.open()
        await waiting.value
        vm.loadIfNeeded()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
        XCTAssertTrue(vm.zones.isEmpty)
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.isListStale)
        XCTAssertTrue(vm.error?.contains("cancelled") == true)
        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.zones.count, 2)
        XCTAssertNil(vm.error)
    }

    func testDetailRecordAndTagFailuresAreIndependentAndRetryable() async {
        let probe = Route53StateProbe(detailFailures: [1], recordFailures: [2], tagFailures: [3])
        let vm = makeViewModel(probe)
        vm.configure(scope: route53StateScope())
        await vm.loadZones()
        vm.selectedZone = vm.zones[0]
        for failingSection in 0..<3 {
            if failingSection > 0 { vm.refreshDetails() }
            await vm.waitForDetails()
            XCTAssertEqual(vm.detailsError != nil, failingSection == 0)
            XCTAssertEqual(vm.recordsError != nil, failingSection == 1)
            XCTAssertEqual(vm.tagsError != nil, failingSection == 2)
            XCTAssertEqual(vm.details != nil, failingSection != 0)
            XCTAssertEqual(!vm.records.isEmpty, failingSection != 1)
            XCTAssertEqual(!vm.tags.isEmpty, failingSection != 2)
            XCTAssertNil(vm.error)
            XCTAssertNotNil(vm.selectedZone)
        }
    }

    func testRawErrorsAreSanitizedAndKnownPermissionErrorsRemainActionable() async {
        let probe = Route53StateProbe(listFailures: [1], detailFailures: [1], recordFailures: [1], tagFailures: [1], useUnknownError: true)
        let vm = makeViewModel(probe)
        vm.configure(scope: route53StateScope())
        await vm.loadZones()
        XCTAssertEqual(vm.error, "Unable to load Route 53 data. Refresh to try again.")
        await vm.loadZones()
        vm.selectedZone = vm.zones[0]
        await vm.waitForDetails()
        for message in [vm.detailsError, vm.recordsError, vm.tagsError] {
            XCTAssertEqual(message, "Unable to load Route 53 data. Refresh to try again.")
        }
        let known = Route53ViewModel(listLoader: { _ in throw AWSRoute53Service.RequestError.listPermission },
                                     detailLoader: { _, _ in throw Route53Error.invalidResponse },
                                     recordLoader: { _, _ in [] }, tagLoader: { _, _ in [:] })
        known.configure(scope: route53StateScope())
        await known.loadZones()
        XCTAssertEqual(known.error, AWSRoute53Service.RequestError.listPermission.localizedDescription)
    }

    func testLateDetailSectionSuccessAndFailureCannotPublishAfterScopeSelectionResetOrCancel() async {
        for shouldFail in [false, true] {
            for change in ["scope", "selection", "reset", "cancel"] {
                let detailGate = TestGate()
                let recordGate = TestGate()
                let tagGate = TestGate()
                let probe = Route53StateProbe(firstDetailGate: detailGate, firstRecordGate: recordGate, firstTagGate: tagGate,
                                              detailFailures: shouldFail ? [1] : [], recordFailures: shouldFail ? [1] : [],
                                              tagFailures: shouldFail ? [1] : [])
                let vm = makeViewModel(probe)
                vm.configure(scope: route53StateScope())
                await vm.loadZones()
                vm.selectedZone = vm.zones[0]
                await detailGate.waitForEntry()
                await recordGate.waitForEntry()
                await tagGate.waitForEntry()
                let waiting = Task { await vm.waitForDetails() }
                await Task.yield()
                switch change {
                case "scope":
                    vm.configure(scope: route53StateScope(profile: "other"))
                    await vm.loadZones()
                    vm.selectedZone = vm.zones[0]
                    await vm.waitForDetails()
                case "selection":
                    vm.selectedZone = vm.zones[1]
                    await vm.waitForDetails()
                case "reset": vm.reset()
                default: vm.cancelDetails()
                }
                await detailGate.open()
                await recordGate.open()
                await tagGate.open()
                await waiting.value
                if change == "scope" {
                    XCTAssertEqual(vm.details?.callerReference, "other ZONE1")
                    XCTAssertEqual(vm.records.first?.setIdentifier, "other ZONE1")
                    XCTAssertEqual(vm.tags["Profile"], "other")
                } else if change == "selection" {
                    XCTAssertEqual(vm.details?.zone.id, "ZONE2")
                    XCTAssertEqual(vm.records.first?.setIdentifier, "work ZONE2")
                    XCTAssertEqual(vm.tags["Zone"], "internal.test.")
                } else {
                    XCTAssertNil(vm.details)
                    XCTAssertTrue(vm.records.isEmpty)
                    XCTAssertTrue(vm.tags.isEmpty)
                }
                for message in [vm.detailsError, vm.recordsError, vm.tagsError] {
                    if change == "cancel" { XCTAssertTrue(message?.contains("cancelled") == true) }
                    else { XCTAssertNil(message) }
                }
                XCTAssertFalse(vm.isDetailsLoading)
                XCTAssertFalse(vm.isRecordsLoading)
                XCTAssertFalse(vm.isTagsLoading)
            }
        }
    }

    func testSameScopeConfigureKeepsAllInflightDetails() async {
        let detailGate = TestGate()
        let recordGate = TestGate()
        let tagGate = TestGate()
        let probe = Route53StateProbe(firstDetailGate: detailGate, firstRecordGate: recordGate, firstTagGate: tagGate)
        let vm = makeViewModel(probe)
        let scope = route53StateScope()
        vm.configure(scope: scope)
        await vm.loadZones()
        vm.selectedZone = vm.zones[0]
        await detailGate.waitForEntry()
        await recordGate.waitForEntry()
        await tagGate.waitForEntry()
        vm.configure(scope: scope)
        XCTAssertNotNil(vm.selectedZone)
        XCTAssertTrue(vm.isDetailsLoading)
        XCTAssertTrue(vm.isRecordsLoading)
        XCTAssertTrue(vm.isTagsLoading)
        await detailGate.open()
        await recordGate.open()
        await tagGate.open()
        await vm.waitForDetails()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1, 1])
        XCTAssertNotNil(vm.details)
        XCTAssertEqual(vm.records.count, 1)
        XCTAssertFalse(vm.tags.isEmpty)
    }

    func testClearingSelectionClearsDetailsAndRecordFilters() async {
        let probe = Route53StateProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: route53StateScope())
        await vm.loadZones()
        vm.selectedZone = vm.zones[0]
        await vm.waitForDetails()
        vm.recordSearchText = "example"
        vm.recordTypeFilter = "A"
        vm.selectedZone = nil
        XCTAssertNil(vm.details)
        XCTAssertTrue(vm.records.isEmpty)
        XCTAssertTrue(vm.tags.isEmpty)
        XCTAssertEqual(vm.recordSearchText, "")
        XCTAssertEqual(vm.recordTypeFilter, "All")
        vm.refreshDetails()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1, 1])
    }

    func testRecordRefreshResetsUnavailableTypeButPreservesSearch() async {
        let probe = Route53StateProbe(recordResults: [[Route53Record(name: "example.test.", type: "A")],
                                                      [Route53Record(name: "example.test.", type: "TXT")]])
        let vm = makeViewModel(probe)
        vm.configure(scope: route53StateScope())
        await vm.loadZones()
        vm.selectedZone = vm.zones[0]
        await vm.waitForDetails()
        vm.recordTypeFilter = "A"
        vm.recordSearchText = "example"
        vm.refreshDetails()
        await vm.waitForDetails()
        XCTAssertEqual(vm.recordTypeFilter, "All")
        XCTAssertEqual(vm.recordSearchText, "example")
        XCTAssertEqual(vm.filteredRecords.first?.type, "TXT")
    }

    func testMismatchedZoneDetailsAreRejectedWithoutDiscardingOtherSections() async {
        let zone = route53StateZone("ZONE1")
        let vm = Route53ViewModel(listLoader: { _ in [zone] },
                                  detailLoader: { _, _ in Route53ZoneDetails(zone: route53StateZone("OTHER"), callerReference: "test") },
                                  recordLoader: { _, _ in [Route53Record(name: "example.test.", type: "A")] },
                                  tagLoader: { _, _ in ["Name": "example"] })
        vm.configure(scope: route53StateScope())
        await vm.loadZones()
        vm.selectedZone = zone
        await vm.waitForDetails()
        XCTAssertNil(vm.details)
        XCTAssertEqual(vm.detailsError, Route53Error.invalidResponse.localizedDescription)
        XCTAssertEqual(vm.records.count, 1)
        XCTAssertEqual(vm.tags["Name"], "example")
    }

    private func makeViewModel(_ probe: Route53StateProbe) -> Route53ViewModel {
        Route53ViewModel(listLoader: { try await probe.list($0) }, detailLoader: { try await probe.details($0, $1) },
                         recordLoader: { try await probe.records($0, $1) }, tagLoader: { try await probe.tags($0, $1) })
    }
}

private func route53StateScope(
    profile: String = "work", account: String = "111122223333", role: String = "ReadOnly", principalARN: String? = nil,
    paths: AWSConfigurationPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/route53-config"])
) -> Route53Scope {
    Route53Scope(profile: AWSProfile(name: profile, region: "us-east-1", ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
                 identity: AWSIdentity(account: account, arn: principalARN ?? "arn:aws:sts::\(account):assumed-role/\(role)/test", userID: "test"),
                 paths: paths)
}

private func route53StateZone(_ id: String, name: String = "example.test.", isPrivate: Bool = false, comment: String? = nil) -> Route53HostedZone {
    Route53HostedZone(id: id, name: name, isPrivate: isPrivate, comment: comment)
}

private enum Route53StateTestError: LocalizedError {
    case unknown
    var errorDescription: String? { "sensitive-test-marker: request details must not be displayed" }
}

private actor Route53StateProbe {
    private var listCalls = 0
    private var detailCalls = 0
    private var recordCalls = 0
    private var tagCalls = 0
    private let listResults: [[Route53HostedZone]]
    private let recordResults: [[Route53Record]]?
    private let firstListGate: TestGate?
    private let firstDetailGate: TestGate?
    private let firstRecordGate: TestGate?
    private let firstTagGate: TestGate?
    private let listFailures: Set<Int>
    private let detailFailures: Set<Int>
    private let recordFailures: Set<Int>
    private let tagFailures: Set<Int>
    private let useUnknownError: Bool

    init(
        listResults: [[Route53HostedZone]] = [[route53StateZone("ZONE1"), route53StateZone("ZONE2", name: "internal.test.", isPrivate: true)]],
        recordResults: [[Route53Record]]? = nil,
        firstListGate: TestGate? = nil, firstDetailGate: TestGate? = nil, firstRecordGate: TestGate? = nil, firstTagGate: TestGate? = nil,
        listFailures: Set<Int> = [], detailFailures: Set<Int> = [], recordFailures: Set<Int> = [], tagFailures: Set<Int> = [],
        useUnknownError: Bool = false
    ) {
        self.listResults = listResults
        self.recordResults = recordResults
        self.firstListGate = firstListGate
        self.firstDetailGate = firstDetailGate
        self.firstRecordGate = firstRecordGate
        self.firstTagGate = firstTagGate
        self.listFailures = listFailures
        self.detailFailures = detailFailures
        self.recordFailures = recordFailures
        self.tagFailures = tagFailures
        self.useUnknownError = useUnknownError
    }

    func counts() -> [Int] { [listCalls, detailCalls, recordCalls, tagCalls] }

    func list(_ scope: Route53Scope) async throws -> [Route53HostedZone] {
        listCalls += 1
        let call = listCalls
        if call == 1 { await firstListGate?.wait() }
        if listFailures.contains(call) { throw requestError }
        return listResults[min(call - 1, listResults.count - 1)]
    }

    func details(_ scope: Route53Scope, _ zone: Route53HostedZone) async throws -> Route53ZoneDetails {
        detailCalls += 1
        let call = detailCalls
        if call == 1 { await firstDetailGate?.wait() }
        if detailFailures.contains(call) { throw requestError }
        return Route53ZoneDetails(zone: zone, callerReference: "\(scope.profileName) \(zone.id)")
    }

    func records(_ scope: Route53Scope, _ zone: Route53HostedZone) async throws -> [Route53Record] {
        recordCalls += 1
        let call = recordCalls
        if call == 1 { await firstRecordGate?.wait() }
        if recordFailures.contains(call) { throw requestError }
        if let recordResults { return recordResults[min(call - 1, recordResults.count - 1)] }
        return [Route53Record(name: zone.name, type: "A", setIdentifier: "\(scope.profileName) \(zone.id)", values: ["192.0.2.1"])]
    }

    func tags(_ scope: Route53Scope, _ zone: Route53HostedZone) async throws -> [String: String] {
        tagCalls += 1
        let call = tagCalls
        if call == 1 { await firstTagGate?.wait() }
        if tagFailures.contains(call) { throw requestError }
        return ["Profile": scope.profileName, "Zone": zone.name]
    }

    private var requestError: Error {
        useUnknownError ? Route53StateTestError.unknown : Route53Error.invalidResponse
    }
}
