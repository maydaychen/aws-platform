import Foundation
import XCTest
@testable import AWSPlatform

final class EC2DemandLoadingTests: XCTestCase {
    @MainActor
    func testAMIGateDoesNotDelayRowsOrCreateOptionalSectionRequests() async {
        let gate = TestGate()
        let rows = [Self.row("i-a"), Self.row("i-b")]
        var sections: [EC2DetailSection] = []
        let vm = EC2ViewModel(instanceLoader: { rows }, imageNameLoader: { _ in
            await gate.wait()
            return ["ami-a": "Linux"]
        }, sectionLoader: { _, section in
            sections.append(section)
            return Self.empty(section)
        })
        let load = Task { await vm.loadInstances(selectFirstIfNeeded: false) }
        await gate.waitForEntry()
        XCTAssertEqual(vm.instances, rows)
        XCTAssertNil(vm.selectedInstance)
        XCTAssertTrue(sections.isEmpty)
        XCTAssertTrue(vm.isImageNameLoading)
        await gate.open()
        await load.value
        XCTAssertFalse(vm.isImageNameLoading)
        XCTAssertFalse(vm.isLoading)
    }

    @MainActor
    func testAMIEnrichmentKeepsManualSelectionWithoutReloadingDetail() async {
        let gate = TestGate()
        let rows = [Self.row("i-a"), Self.row("i-b")]
        var detailIDs: [String] = []
        let vm = EC2ViewModel(instanceLoader: { rows }, imageNameLoader: { _ in
            await gate.wait()
            return ["ami-a": "Linux"]
        }, detailLoader: { id in detailIDs.append(id); return Self.detail(id) })
        let load = Task { await vm.loadInstances() }
        await gate.waitForEntry()
        vm.selectedInstance = rows[1]
        await vm.waitForCurrentDetail()
        let callsBeforeEnrichment = detailIDs.count
        await gate.open()
        await load.value
        XCTAssertEqual(vm.selectedInstance?.instanceId, "i-b")
        XCTAssertEqual(vm.selectedInstance?.imageName, "Linux")
        XCTAssertEqual(vm.instanceDetail?.instanceId, "i-b")
        XCTAssertEqual(detailIDs.count, callsBeforeEnrichment)
    }

    @MainActor
    func testOverviewHasNoSectionRequestsAndKeepsCPUCredit() async {
        var sections: [EC2DetailSection] = []
        let vm = EC2ViewModel(instanceLoader: { [Self.row("i-a")] }, detailLoader: { Self.detail($0) }, sectionLoader: { _, section in
            sections.append(section)
            return Self.empty(section)
        })
        await vm.loadInstances()
        await vm.waitForCurrentDetail()
        XCTAssertEqual(vm.instanceDetail?.cpuCreditMode, .unlimited)
        XCTAssertEqual(sections, [])
        XCTAssertEqual(vm.sectionStates, [:])
    }

    @MainActor
    func testSectionsMergeIndependentlyAndRevisitMakesNoRequest() async {
        let storageGate = TestGate()
        var calls: [EC2DetailSection: Int] = [:]
        let vm = EC2ViewModel(instanceLoader: { [Self.row("i-a")] }, detailLoader: { Self.detail($0) }, sectionLoader: { _, section in
            calls[section, default: 0] += 1
            switch section {
            case .storage:
                await storageGate.wait()
                return .storage([Self.volume("vol-a")])
            case .security: return .security([Self.group("sg-a")])
            }
        })
        await vm.loadInstances()
        await vm.waitForCurrentDetail()
        vm.showDetailSection(.storage)
        await storageGate.waitForEntry()
        vm.showDetailSection(.security)
        await vm.waitForDetailSection(.security)
        XCTAssertEqual(vm.sectionStates[.storage], .loading)
        XCTAssertEqual(vm.instanceDetail?.securityGroups.first?.groupId, "sg-a")
        await storageGate.open()
        await vm.waitForDetailSection(.storage)
        XCTAssertEqual(vm.instanceDetail?.volumes.first?.volumeId, "vol-a")
        XCTAssertEqual(vm.instanceDetail?.securityGroups.first?.groupId, "sg-a")
        vm.showDetailSection(.security)
        vm.showDetailSection(.storage)
        XCTAssertEqual(calls, [.storage: 1, .security: 1])
    }

    @MainActor
    func testSectionFailurePreservesOverviewAndOtherGroupsUntilExplicitRetry() async {
        var storageCalls = 0
        let vm = EC2ViewModel(instanceLoader: { [Self.row("i-a")] }, detailLoader: { Self.detail($0) }, sectionLoader: { _, section in
            if section == .storage {
                storageCalls += 1
                if storageCalls == 1 { throw Failure.failed }
                return .storage([Self.volume("vol-retry")])
            }
            return .security([Self.group("sg-ok")])
        })
        await vm.loadInstances()
        await vm.waitForCurrentDetail()
        vm.showDetailSection(.storage)
        await vm.waitForDetailSection(.storage)
        vm.showDetailSection(.security)
        await vm.waitForDetailSection(.security)
        XCTAssertEqual(vm.sectionStates[.storage], .failed("Mock section unavailable."))
        XCTAssertEqual(vm.instanceDetail?.cpuCreditMode, .unlimited)
        XCTAssertEqual(vm.instanceDetail?.securityGroups.first?.groupId, "sg-ok")
        XCTAssertNil(vm.detailError)
        vm.showDetailSection(.storage)
        XCTAssertEqual(storageCalls, 1)
        vm.retryDetailSection(.storage)
        await vm.waitForDetailSection(.storage)
        XCTAssertEqual(storageCalls, 2)
        XCTAssertEqual(vm.sectionStates[.storage], .loaded)
        XCTAssertEqual(vm.instanceDetail?.volumes.first?.volumeId, "vol-retry")
    }

    @MainActor
    func testBasicDetailAndRuntimeStatusHaveNoOptionalRequestsOrChecks() async {
        var sections: [EC2DetailSection] = []
        let vm = EC2ViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, section in
            sections.append(section)
            return Self.empty(section)
        })
        vm.selectedInstance = Self.row("i-a")
        await vm.waitForCurrentDetail()
        vm.showDetailSection(nil)
        XCTAssertTrue(sections.isEmpty)
        XCTAssertEqual(EC2DetailSection.allCases, [.storage, .security])
        XCTAssertEqual(vm.sectionStates, [:])
        XCTAssertNotNil(vm.instanceDetail)
        XCTAssertNil(vm.detailError)
    }

    @MainActor
    func testSectionSelectedDuringBaseLoadWaitsThenLoadsOnce() async {
        let gate = TestGate()
        var sections: [EC2DetailSection] = []
        let vm = EC2ViewModel(detailLoader: { id in await gate.wait(); return Self.detail(id) }, sectionLoader: { _, section in
            sections.append(section)
            return Self.empty(section)
        })
        vm.selectedInstance = Self.row("i-a")
        await gate.waitForEntry()
        vm.showDetailSection(.storage)
        vm.showDetailSection(.storage)
        XCTAssertEqual(sections, [])
        await gate.open()
        await vm.waitForCurrentDetail()
        await vm.waitForDetailSection(.storage)
        XCTAssertEqual(sections, [.storage])
        XCTAssertEqual(vm.sectionStates[.storage], .loaded)
    }

    @MainActor
    func testTabsChangedWhileBaseLoadsQueryOnlyCurrentSection() async {
        let gate = TestGate()
        var sections: [EC2DetailSection] = []
        let vm = EC2ViewModel(detailLoader: { id in await gate.wait(); return Self.detail(id) }, sectionLoader: { _, section in
            sections.append(section)
            return Self.empty(section)
        })
        vm.selectedInstance = Self.row("i-a")
        await gate.waitForEntry()
        vm.showDetailSection(.storage)
        vm.showDetailSection(.security)
        await gate.open()
        await vm.waitForCurrentDetail()
        await vm.waitForDetailSection(.security)
        XCTAssertEqual(sections, [.security])
        XCTAssertNil(vm.sectionStates[.storage])
    }

    @MainActor
    func testBaseSelectionABARejectsOldSameInstanceResult() async {
        let gate = TestGate()
        var aCalls = 0
        let vm = EC2ViewModel(detailLoader: { id in
            if id == "i-a" {
                aCalls += 1
                if aCalls == 1 { await gate.wait(); return Self.detail(id, credit: .standard) }
            }
            return Self.detail(id)
        })
        vm.selectedInstance = Self.row("i-a")
        let oldRequest = vm.loadDetailForSelection()
        await gate.waitForEntry()
        vm.selectedInstance = Self.row("i-b")
        vm.selectedInstance = Self.row("i-a")
        await vm.waitForCurrentDetail()
        await gate.open()
        await oldRequest?.value
        XCTAssertEqual(vm.instanceDetail?.instanceId, "i-a")
        XCTAssertEqual(vm.instanceDetail?.cpuCreditMode, .unlimited)
        XCTAssertNil(vm.detailError)
    }

    @MainActor
    func testSectionSelectionABARejectsOldSuccessAndOldFailure() async {
        for failOld in [false, true] {
            let gate = TestGate()
            var calls = 0
            let vm = EC2ViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, _ in
                calls += 1
                if calls == 1 {
                    await gate.wait()
                    if failOld { throw Failure.failed }
                    return .storage([Self.volume("vol-old")])
                }
                return .storage([Self.volume("vol-new")])
            })
            vm.selectedInstance = Self.row("i-a")
            await vm.waitForCurrentDetail()
            vm.showDetailSection(.storage)
            await gate.waitForEntry()
            let oldRequest = vm.loadDetailSectionIfNeeded(.storage)
            vm.selectedInstance = Self.row("i-b")
            vm.selectedInstance = Self.row("i-a")
            await vm.waitForCurrentDetail()
            vm.showDetailSection(.storage)
            await vm.waitForDetailSection(.storage)
            await gate.open()
            await oldRequest?.value
            XCTAssertEqual(vm.instanceDetail?.volumes.first?.volumeId, "vol-new")
            XCTAssertEqual(vm.sectionStates[.storage], .loaded)
        }
    }

    @MainActor
    func testResetWithSameInstanceIDRejectsOldScopeSection() async {
        let gate = TestGate()
        var calls = 0
        let vm = EC2ViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, _ in
            calls += 1
            if calls == 1 { await gate.wait(); return .security([Self.group("sg-old-scope")]) }
            return .security([Self.group("sg-new-scope")])
        })
        vm.selectedInstance = Self.row("i-same")
        await vm.waitForCurrentDetail()
        vm.showDetailSection(.security)
        await gate.waitForEntry()
        let oldRequest = vm.loadDetailSectionIfNeeded(.security)
        vm.reset()
        vm.selectedInstance = Self.row("i-same")
        await vm.waitForCurrentDetail()
        vm.showDetailSection(.security)
        await vm.waitForDetailSection(.security)
        await gate.open()
        await oldRequest?.value
        XCTAssertEqual(vm.instanceDetail?.securityGroups.first?.groupId, "sg-new-scope")
        XCTAssertEqual(vm.sectionStates[.security], .loaded)
    }

    @MainActor
    func testCancelledAMIEnrichmentCannotRewritePublishedRows() async {
        let gate = TestGate()
        let row = Self.row("i-a")
        let vm = EC2ViewModel(instanceLoader: { [row] }, imageNameLoader: { _ in
            await gate.wait()
            return ["ami-a": "Cancelled image"]
        })
        let request = Task { await vm.loadInstances(selectFirstIfNeeded: false) }
        await gate.waitForEntry()
        vm.cancelLoading()
        await gate.open()
        await request.value
        XCTAssertEqual(vm.instances, [row])
        XCTAssertNil(vm.instances.first?.imageName)
        XCTAssertFalse(vm.isImageNameLoading)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.error)
    }

    @MainActor
    func testDetailRefreshInvalidatesOldSectionFailureForSameID() async {
        let gate = TestGate()
        var calls = 0
        let vm = EC2ViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, _ in
            calls += 1
            if calls == 1 { await gate.wait(); throw Failure.failed }
            return .storage([Self.volume("vol-fresh")])
        })
        vm.selectedInstance = Self.row("i-a")
        await vm.waitForCurrentDetail()
        vm.showDetailSection(.storage)
        await gate.waitForEntry()
        let oldRequest = vm.loadDetailSectionIfNeeded(.storage)
        vm.loadDetailForSelection()
        await vm.waitForCurrentDetail()
        await vm.waitForDetailSection(.storage)
        await gate.open()
        await oldRequest?.value
        XCTAssertEqual(vm.sectionStates[.storage], .loaded)
        XCTAssertEqual(vm.instanceDetail?.volumes.first?.volumeId, "vol-fresh")
    }

    @MainActor
    func testCancelledSectionRequiresExplicitRetry() async {
        let gate = TestGate()
        let vm = EC2ViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, section in
            await gate.wait()
            return Self.empty(section)
        })
        vm.selectedInstance = Self.row("i-a")
        await vm.waitForCurrentDetail()
        vm.showDetailSection(.storage)
        await gate.waitForEntry()
        let oldRequest = vm.loadDetailSectionIfNeeded(.storage)
        vm.cancelLoading()
        await gate.open()
        await oldRequest?.value
        XCTAssertEqual(vm.sectionStates[.storage], .failed("Loading cancelled. Use Refresh to try again."))
        XCTAssertNotNil(vm.instanceDetail)
    }

    @MainActor
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for mock response")
    }

    private enum Failure: LocalizedError {
        case failed
        var errorDescription: String? { "Mock section unavailable." }
    }

    private static func row(_ id: String) -> EC2InstanceModel {
        EC2InstanceModel(instanceId: id, name: id, instanceType: "t3.micro", state: "running", privateIP: nil,
                         publicIP: nil, platformDetails: nil, architecture: nil, vpcId: nil, subnetId: nil,
                         availabilityZone: nil, securityGroups: ["sg-a"], imageId: "ami-a", imageName: nil,
                         keyName: nil, launchTime: nil, tags: [:])
    }

    private static func detail(_ id: String, credit: EC2CPUCreditMode = .unlimited) -> EC2InstanceDetailModel {
        EC2InstanceDetailModel(instanceId: id, privateDNSName: "private.example", publicDNSName: nil, ipv6Address: nil,
                               monitoringState: nil, stateTransitionReason: nil, iamProfileARN: nil,
                               rootDeviceName: nil, rootDeviceType: nil, virtualizationType: nil, hypervisor: nil,
                               lifecycle: nil, spotRequestId: nil, capacityReservationId: nil, cpuCoreCount: nil,
                               threadsPerCore: nil, ebsOptimized: nil, enaSupport: nil, sourceDestCheck: nil,
                               metadataHttpEndpoint: nil, metadataHttpTokens: nil, metadataHopLimit: nil,
                               metadataTags: nil, networkInterfaces: [], volumes: [], securityGroups: [],
                               warnings: [], cpuCreditMode: credit, volumeIDs: ["vol-a"], securityGroupIDs: ["sg-a"])
    }

    private static func volume(_ id: String) -> EC2VolumeModel {
        EC2VolumeModel(volumeId: id, name: nil, device: nil, state: nil, type: nil, sizeGiB: nil,
                       iops: nil, throughputMiBps: nil, encrypted: nil, deleteOnTermination: nil,
                       availabilityZone: nil, snapshotId: nil)
    }

    private static func group(_ id: String) -> EC2SecurityGroupModel {
        EC2SecurityGroupModel(groupId: id, name: nil, description: nil, vpcId: nil, inboundRules: [], outboundRules: [])
    }

    private static func empty(_ section: EC2DetailSection) -> EC2DetailSectionResult {
        switch section {
        case .storage: return .storage([])
        case .security: return .security([])
        }
    }
}
