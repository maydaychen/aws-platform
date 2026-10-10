import XCTest
@testable import AWSPlatform

@MainActor
final class HealthOrganizationViewModelTests: XCTestCase {
    func testUnselectedProfileNeverQueriesEitherMode() async {
        let probe = OrganizationStateProbe()
        let vm = makeOrganizationVM(probe)
        vm.setQueryMode(.organization)
        vm.applyAccountFilter("444455556666")
        vm.refreshAffectedAccounts()
        await vm.loadEvents()
        XCTAssertEqual(vm.queryMode, .account)
        XCTAssertNil(vm.scope)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0, 0])
    }

    func testModeSwitchAndServerAccountFilterClearSelectionAndRetainProfile() async {
        let probe = OrganizationStateProbe()
        let vm = makeOrganizationVM(probe)
        vm.configure(scope: organizationHealthScope())
        await vm.loadEvents()
        vm.selectedEvent = vm.events[0]
        await vm.waitForDetails()
        vm.setQueryMode(.organization)
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertNil(vm.selectedEvent)
        XCTAssertNil(vm.details)
        await vm.waitForCurrentLoad()
        vm.applyAccountFilter(" 444455556666 ")
        XCTAssertTrue(vm.events.isEmpty)
        await vm.waitForCurrentLoad()
        let scopes = await probe.listScopes
        XCTAssertEqual(scopes.map(\.queryMode), [.account, .organization, .organization])
        XCTAssertEqual(scopes.last?.organizationAccountFilter, "444455556666")
        XCTAssertEqual(scopes.map(\.profileName), ["management", "management", "management"])
        vm.setQueryMode(.account)
        XCTAssertEqual(vm.accountFilter, "")
        await vm.waitForCurrentLoad()
    }

    func testInvalidAccountFilterRetainsCurrentListAndMakesNoRequest() async {
        let probe = OrganizationStateProbe()
        let vm = makeOrganizationVM(probe)
        vm.configure(scope: organizationHealthScope())
        vm.setQueryMode(.organization)
        await vm.waitForCurrentLoad()
        let original = vm.events
        vm.applyAccountFilter("１２３４５６７８９０１２")
        XCTAssertEqual(vm.events, original)
        XCTAssertEqual(vm.accountFilter, "")
        XCTAssertTrue(vm.error?.contains("12-digit") == true)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
    }

    func testOrganizationEventWaitsForExplicitAffectedAccountBeforeDetails() async {
        let probe = OrganizationStateProbe()
        let vm = makeOrganizationVM(probe)
        vm.configure(scope: organizationHealthScope())
        vm.setQueryMode(.organization)
        await vm.waitForCurrentLoad()
        vm.selectedEvent = vm.events[0]
        await vm.waitForDetails()
        XCTAssertEqual(vm.affectedAccounts, ["444455556666", "777788889999"])
        XCTAssertNil(vm.selectedAccount)
        var counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 0, 0])
        vm.selectAccount("999999999999")
        XCTAssertNil(vm.selectedAccount)
        vm.selectAccount("444455556666")
        await vm.waitForDetails()
        XCTAssertEqual(vm.details?.event.affectedAccountID, "444455556666")
        XCTAssertEqual(vm.entities.first?.accountID, "444455556666")
        counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1, 1])
        vm.selectAccount(nil)
        XCTAssertNil(vm.details)
        XCTAssertTrue(vm.entities.isEmpty)
    }

    func testSwitchingAccountsDiscardsLateDescriptionAndResources() async {
        let gate = TestGate()
        let entityGate = TestGate()
        let probe = OrganizationStateProbe(detailGate: gate, entityGate: entityGate)
        let vm = makeOrganizationVM(probe)
        vm.configure(scope: organizationHealthScope())
        vm.setQueryMode(.organization)
        await vm.waitForCurrentLoad()
        vm.selectedEvent = vm.events[0]
        await vm.waitForDetails()
        vm.selectAccount("444455556666")
        await gate.waitForEntry()
        await entityGate.waitForEntry()
        vm.selectAccount("777788889999")
        await vm.waitForDetails()
        await gate.open()
        await entityGate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.details?.event.affectedAccountID, "777788889999")
        XCTAssertEqual(vm.entities.first?.accountID, "777788889999")
        XCTAssertNil(vm.detailError)
    }

    func testClearingProfileOrChangingModeDiscardsLateAffectedAccounts() async {
        for clearProfile in [true, false] {
            let gate = TestGate()
            let probe = OrganizationStateProbe(accountsGate: gate)
            let vm = makeOrganizationVM(probe)
            vm.configure(scope: organizationHealthScope())
            vm.setQueryMode(.organization)
            await vm.waitForCurrentLoad()
            vm.selectedEvent = vm.events[0]
            await gate.waitForEntry()
            if clearProfile { vm.configure(scope: nil) } else { vm.setQueryMode(.account) }
            await gate.open()
            for _ in 0..<20 { await Task.yield() }
            XCTAssertTrue(vm.affectedAccounts.isEmpty)
            XCTAssertNil(vm.selectedAccount)
            XCTAssertFalse(vm.isAccountsLoading)
            XCTAssertNil(vm.accountsError)
            await vm.waitForCurrentLoad()
        }
    }

    func testChangingModeDiscardsLateList() async {
        let gate = TestGate()
        let probe = OrganizationStateProbe(listGate: gate)
        let vm = makeOrganizationVM(probe)
        vm.configure(scope: organizationHealthScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.setQueryMode(.organization)
        await vm.waitForCurrentLoad()
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.queryMode, .organization)
        XCTAssertEqual(vm.events.first?.status, "upcoming")
        XCTAssertNil(vm.error)
    }

    func testChangingFilterDiscardsLateOrganizationList() async {
        let gate = TestGate()
        let probe = OrganizationStateProbe(listGate: gate)
        let vm = makeOrganizationVM(probe)
        vm.configure(scope: organizationHealthScope())
        vm.setQueryMode(.organization)
        await gate.waitForEntry()
        vm.applyAccountFilter("444455556666")
        await vm.waitForCurrentLoad()
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.accountFilter, "444455556666")
        XCTAssertEqual(vm.events.count, 1)
        XCTAssertNil(vm.error)
        vm.applyAccountFilter("")
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.accountFilter, "")
    }

    func testCancellingAffectedAccountsIgnoresLateSuccessAndAllowsRetry() async {
        let gate = TestGate()
        let probe = OrganizationStateProbe(accountsGate: gate)
        let vm = makeOrganizationVM(probe)
        vm.configure(scope: organizationHealthScope())
        vm.setQueryMode(.organization)
        await vm.waitForCurrentLoad()
        vm.selectedEvent = vm.events[0]
        await gate.waitForEntry()
        vm.cancelDetails()
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(vm.affectedAccounts.isEmpty)
        XCTAssertNotNil(vm.accountsError)
        XCTAssertFalse(vm.isAccountsLoading)
        vm.refreshDetails()
        await vm.waitForDetails()
        XCTAssertEqual(vm.affectedAccounts.count, 2)
        XCTAssertNil(vm.accountsError)
    }

    func testAccountsErrorHasExplicitRetryAndNeverLoadsUnverifiedAccount() async {
        let probe = OrganizationStateProbe()
        let vm = HealthViewModel(listLoader: { _ in [organizationHealthEvent()] },
                                 detailLoader: { try await probe.details($0, $1) },
                                 entityLoader: { try await probe.entities($0, $1) },
                                 accountsLoader: { _, _ in throw AWSHealthService.RequestError.organizationAccountsPermission })
        vm.configure(scope: organizationHealthScope())
        vm.setQueryMode(.organization)
        await vm.waitForCurrentLoad()
        vm.selectedEvent = vm.events[0]
        await vm.waitForDetails()
        XCTAssertEqual(vm.accountsError, AWSHealthService.RequestError.organizationAccountsPermission.localizedDescription)
        vm.selectAccount("444455556666")
        XCTAssertNil(vm.selectedAccount)
        XCTAssertTrue(vm.affectedAccounts.isEmpty)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0, 0])
    }
}

@MainActor
private func makeOrganizationVM(_ probe: OrganizationStateProbe) -> HealthViewModel {
    HealthViewModel(listLoader: { try await probe.list($0) }, detailLoader: { try await probe.details($0, $1) },
                    entityLoader: { try await probe.entities($0, $1) }, accountsLoader: { try await probe.accounts($0, $1) })
}

private actor OrganizationStateProbe {
    var listScopes: [HealthScope] = []
    var accountCalls = 0
    var detailCalls = 0
    var entityCalls = 0
    let listGate: TestGate?
    let accountsGate: TestGate?
    let detailGate: TestGate?
    let entityGate: TestGate?

    init(listGate: TestGate? = nil, accountsGate: TestGate? = nil, detailGate: TestGate? = nil, entityGate: TestGate? = nil) {
        self.listGate = listGate
        self.accountsGate = accountsGate
        self.detailGate = detailGate
        self.entityGate = entityGate
    }

    func counts() -> [Int] { [listScopes.count, accountCalls, detailCalls, entityCalls] }

    func list(_ scope: HealthScope) async throws -> [HealthEvent] {
        listScopes.append(scope)
        if listScopes.count == 1 { await listGate?.wait() }
        return [organizationHealthEvent(status: scope.queryMode == .account ? "closed" : "upcoming")]
    }

    func accounts(_ scope: HealthScope, _ event: HealthEvent) async throws -> [String] {
        accountCalls += 1
        if accountCalls == 1 { await accountsGate?.wait() }
        return ["444455556666", "777788889999"]
    }

    func details(_ scope: HealthScope, _ event: HealthEvent) async throws -> HealthEventDetails {
        detailCalls += 1
        if event.affectedAccountID == "444455556666" { await detailGate?.wait() }
        return HealthEventDetails(event: event, description: event.affectedAccountID ?? "Current account")
    }

    func entities(_ scope: HealthScope, _ event: HealthEvent) async throws -> [HealthAffectedEntity] {
        entityCalls += 1
        if event.affectedAccountID == "444455556666" { await entityGate?.wait() }
        return [HealthAffectedEntity(id: "entity", value: "resource", status: "PENDING", accountID: event.affectedAccountID)]
    }
}
