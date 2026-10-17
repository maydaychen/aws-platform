import Foundation
import SotoCore
import XCTest
@testable import AWSPlatform

final class EC2HealthLoadingTests: XCTestCase {
    @MainActor
    func testEveryInstanceHasHealthWithoutSelectingAnyRow() async {
        let rows = [instance("i-first"), instance("i-second")]
        var requested: [String] = []
        let vm = EC2ViewModel(instanceLoader: { rows }, healthLoader: { ids in
            requested = ids
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.healthy) })
        })
        await vm.loadInstances(selectFirstIfNeeded: false)
        XCTAssertEqual(requested, rows.map(\.instanceId))
        XCTAssertEqual(vm.instanceHealth.count, 2)
        XCTAssertTrue(vm.instanceHealth.values.allSatisfy { $0.summary == "Checks passed" })
        XCTAssertNil(vm.selectedInstance)
        XCTAssertFalse(vm.isHealthLoading)
        XCTAssertTrue(vm.instanceHealthErrors.isEmpty)
    }

    @MainActor
    func testBatchFailureIsVisibleForEveryRowAndDoesNotLoseInstances() async {
        let rows = [instance("i-first"), instance("i-second")]
        let vm = EC2ViewModel(instanceLoader: { rows }, healthLoader: { _ in
            throw EC2HealthTestAWSFailure("AccessDenied")
        })
        await vm.loadInstances(selectFirstIfNeeded: false)
        XCTAssertEqual(vm.instances, rows)
        XCTAssertTrue(vm.instanceHealth.isEmpty)
        XCTAssertEqual(Set(vm.instanceHealthErrors.keys), Set(rows.map(\.instanceId)))
        XCTAssertTrue(vm.instanceHealthErrors.values.allSatisfy { $0.contains("permission denied") })
        XCTAssertFalse(vm.instanceHealthErrors.values.contains { $0.contains("SENSITIVE_DETAIL") })
        XCTAssertNil(vm.error)
    }

    @MainActor
    func testMissingStatusesAreErrorsInsteadOfImplicitHealthyOrNotApplicable() async {
        let rows = [instance("i-first"), instance("i-second")]
        let vm = EC2ViewModel(instanceLoader: { rows }, healthLoader: { _ in
            [rows[0].instanceId: Self.healthy]
        })
        await vm.loadInstances(selectFirstIfNeeded: false)
        XCTAssertEqual(vm.instanceHealth[rows[0].instanceId], Self.healthy)
        XCTAssertNil(vm.instanceHealthErrors[rows[0].instanceId])
        XCTAssertEqual(vm.instanceHealthErrors[rows[1].instanceId], EC2InstanceHealthResult.notReturned)
    }

    @MainActor
    func testPartialResultKeepsSuccessAndPerInstanceFailureWithoutFetchingDetails() async {
        let rows = [instance("i-first"), instance("i-second")]
        let vm = EC2ViewModel(instanceLoader: { rows }, healthResultLoader: { _ in
            EC2InstanceHealthResult(health: [rows[0].instanceId: Self.healthy],
                                    errors: [rows[1].instanceId: "Unable to load EC2 status checks."])
        }, detailLoader: { _ in
            XCTFail("Unselected list rows must not fetch other details")
            throw URLError(.badServerResponse)
        })
        await vm.loadInstances(selectFirstIfNeeded: false)
        XCTAssertEqual(vm.instanceHealth, [rows[0].instanceId: Self.healthy])
        XCTAssertEqual(vm.instanceHealthErrors.keys.sorted(), [rows[1].instanceId])
        XCTAssertNil(vm.instanceDetail)
    }

    @MainActor
    func testSuccessfulDetailClearsOnlyItsOwnHealthError() async {
        let rows = [instance("i-first"), instance("i-second")]
        let vm = EC2ViewModel(instanceLoader: { rows }, healthLoader: { _ in [:] },
                              detailLoader: { Self.detail($0, health: Self.healthy) })
        await vm.loadInstances(selectFirstIfNeeded: false)
        vm.selectedInstance = rows[0]
        await waitUntil { vm.instanceDetail?.instanceId == rows[0].instanceId }
        XCTAssertEqual(vm.instanceHealth[rows[0].instanceId], Self.healthy)
        XCTAssertNil(vm.instanceHealthErrors[rows[0].instanceId])
        XCTAssertEqual(vm.instanceHealthErrors[rows[1].instanceId], EC2InstanceHealthResult.notReturned)
    }

    @MainActor
    func testRefreshPublishesRowsAndLoadingBeforeHealthCompletes() async {
        let gate = TestGate()
        let row = instance("i-first")
        let vm = EC2ViewModel(instanceLoader: { [row] }, healthLoader: { _ in
            await gate.wait()
            return [row.instanceId: Self.healthy]
        })
        let task = Task { await vm.loadInstances(selectFirstIfNeeded: false) }
        await gate.waitForEntry()
        XCTAssertEqual(vm.instances, [row])
        XCTAssertTrue(vm.isHealthLoading)
        XCTAssertTrue(vm.isLoading)
        await gate.open()
        await task.value
        XCTAssertFalse(vm.isHealthLoading)
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testCancelledHealthResponseCannotChangeRowsHealthOrLoadingState() async {
        let gate = TestGate()
        let row = instance("i-first")
        let vm = EC2ViewModel(instanceLoader: { [row] }, healthLoader: { _ in
            await gate.wait()
            return [row.instanceId: Self.healthy]
        })
        let task = Task { await vm.loadInstances(selectFirstIfNeeded: false) }
        await gate.waitForEntry()
        vm.cancelLoading()
        await gate.open()
        await task.value
        XCTAssertTrue(vm.instanceHealth.isEmpty)
        XCTAssertEqual(vm.instanceHealthErrors, [row.instanceId: "Loading cancelled. Use Refresh to try again."])
        XCTAssertFalse(vm.isHealthLoading)
        XCTAssertFalse(vm.isLoading)
        vm.healthFilter = .attention
        XCTAssertEqual(vm.filteredInstances, [row])
        vm.reset()
        XCTAssertTrue(vm.instanceHealthErrors.isEmpty)
    }

    @MainActor
    func testOldHealthFailureAfterResetCannotOverwriteNewScope() async {
        let gate = TestGate()
        let row = instance("i-first")
        var calls = 0
        let vm = EC2ViewModel(instanceLoader: { [row] }, healthLoader: { _ in
            calls += 1
            if calls == 1 { await gate.wait(); throw URLError(.notConnectedToInternet) }
            return [row.instanceId: Self.healthy]
        })
        let old = Task { await vm.loadInstances(selectFirstIfNeeded: false) }
        await gate.waitForEntry()
        vm.reset()
        await vm.loadInstances(selectFirstIfNeeded: false)
        await gate.open()
        await old.value
        XCTAssertEqual(vm.instanceHealth, [row.instanceId: Self.healthy])
        XCTAssertTrue(vm.instanceHealthErrors.isEmpty)
        XCTAssertFalse(vm.isHealthLoading)
    }

    @MainActor
    func testDetailStartedBeforeRefreshCannotOverwriteNewGenerationForSameID() async {
        let gate = TestGate()
        let row = instance("i-first")
        var detailCalls = 0
        let vm = EC2ViewModel(instanceLoader: { [row] }, healthLoader: { _ in [row.instanceId: Self.healthy] },
                              detailLoader: { id in
            detailCalls += 1
            if detailCalls == 2 {
                await gate.wait()
                return Self.detail(id, health: Self.impaired)
            }
            return Self.detail(id, health: Self.healthy)
        })
        await vm.loadInstances()
        await waitUntil { vm.instanceDetail != nil }
        let old = Task { await vm.loadDetail(instanceId: row.instanceId) }
        await gate.waitForEntry()
        await vm.loadInstances()
        await waitUntil { vm.instanceDetail?.health == Self.healthy }
        await gate.open()
        await old.value
        XCTAssertEqual(vm.instanceHealth[row.instanceId], Self.healthy)
        XCTAssertEqual(vm.instanceDetail?.health, Self.healthy)
    }

    @MainActor
    func testResetClearsHealthErrorsAndLoadingState() {
        let vm = EC2ViewModel()
        vm.instanceHealthErrors = ["i-first": "Unable to load EC2 status checks."]
        vm.isHealthLoading = true
        vm.reset()
        XCTAssertTrue(vm.instanceHealthErrors.isEmpty)
        XCTAssertFalse(vm.isHealthLoading)
    }

    @MainActor
    func testHealthErrorRowsAreIncludedInNeedsAttentionFilter() async {
        let rows = [instance("i-first"), instance("i-second")]
        let vm = EC2ViewModel(instanceLoader: { rows }, healthLoader: { _ in [rows[0].instanceId: Self.healthy] })
        await vm.loadInstances(selectFirstIfNeeded: false)
        vm.healthFilter = .attention
        XCTAssertEqual(vm.filteredInstances.map(\.instanceId), [rows[1].instanceId])
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for deterministic mock response")
    }

    private static let healthy = EC2InstanceHealth(systemStatus: "ok", instanceStatus: "ok", attachedEBSStatus: "ok", events: [])
    private static let impaired = EC2InstanceHealth(systemStatus: "impaired", instanceStatus: "ok", attachedEBSStatus: "ok", events: [])

    private func instance(_ id: String) -> EC2InstanceModel {
        EC2InstanceModel(instanceId: id, name: id, instanceType: "t3.micro", state: "running", privateIP: nil,
                         publicIP: nil, platformDetails: nil, architecture: nil, vpcId: nil, subnetId: nil,
                         availabilityZone: nil, securityGroups: [], imageId: nil, imageName: nil, keyName: nil,
                         launchTime: nil, tags: [:])
    }

    private static func detail(_ id: String, health: EC2InstanceHealth?) -> EC2InstanceDetailModel {
        EC2InstanceDetailModel(instanceId: id, privateDNSName: nil, publicDNSName: nil, ipv6Address: nil,
                               monitoringState: nil, stateTransitionReason: nil, iamProfileARN: nil,
                               rootDeviceName: nil, rootDeviceType: nil, virtualizationType: nil, hypervisor: nil,
                               lifecycle: nil, spotRequestId: nil, capacityReservationId: nil, cpuCoreCount: nil,
                               threadsPerCore: nil, ebsOptimized: nil, enaSupport: nil, sourceDestCheck: nil,
                               metadataHttpEndpoint: nil, metadataHttpTokens: nil, metadataHopLimit: nil,
                               metadataTags: nil, networkInterfaces: [], volumes: [], securityGroups: [],
                               health: health, warnings: [])
    }
}
