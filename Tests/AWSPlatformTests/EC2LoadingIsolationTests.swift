import Foundation
import XCTest
@testable import AWSPlatform

@MainActor
final class EC2LoadingIsolationTests: XCTestCase {
    func testListAndBaseDetailUseOnlyTheirRegisteredLoadersWithoutStatusChecks() async {
        let rows = [Self.instance("i-first"), Self.instance("i-second")]
        var calls: [String] = []
        let vm = EC2ViewModel(instanceLoader: {
            calls.append("instances")
            return rows
        }, imageNameLoader: { _ in
            calls.append("images")
            return [:]
        }, detailLoader: { id in
            calls.append("detail:\(id)")
            return Self.detail(id)
        }, sectionLoader: { _, section in
            calls.append(section.rawValue)
            return section == .storage ? .storage([]) : .security([])
        })
        await vm.loadInstances(selectFirstIfNeeded: false)
        XCTAssertEqual(calls, ["instances", "images"])
        XCTAssertEqual(vm.instances, rows)
        XCTAssertNil(vm.selectedInstance)
        XCTAssertNil(vm.instanceDetail)

        vm.selectedInstance = rows[0]
        await vm.waitForCurrentDetail()
        vm.showDetailSection(nil)
        XCTAssertEqual(calls, ["instances", "images", "detail:i-first"])
        XCTAssertEqual(EC2DetailSection.allCases.map(\.rawValue), ["storage", "security"])
        XCTAssertTrue(vm.sectionStates.isEmpty)
    }

    func testCancelledBaseListCannotPublishLateRowsOrLoadingState() async {
        let gate = TestGate()
        let vm = EC2ViewModel(instanceLoader: {
            await gate.wait()
            return [Self.instance("i-late")]
        })
        let request = Task { await vm.loadInstances(selectFirstIfNeeded: false) }
        await gate.waitForEntry()
        vm.cancelLoading()
        await gate.open()
        await request.value
        XCTAssertTrue(vm.instances.isEmpty)
        XCTAssertNil(vm.selectedInstance)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.isImageNameLoading)
    }

    func testOldAMISuccessOrFailureCannotOverwriteNewScopeWithSameInstanceID() async {
        for oldFails in [false, true] {
            let gate = TestGate()
            let row = Self.instance("i-same")
            var imageCalls = 0
            let vm = EC2ViewModel(instanceLoader: { [row] }, imageNameLoader: { _ in
                imageCalls += 1
                if imageCalls == 1 {
                    await gate.wait()
                    if oldFails { throw URLError(.notConnectedToInternet) }
                    return ["ami-test": "Old account image"]
                }
                return ["ami-test": "New account image"]
            })
            let old = Task { await vm.loadInstances(selectFirstIfNeeded: false) }
            await gate.waitForEntry()
            vm.reset()
            await vm.loadInstances(selectFirstIfNeeded: false)
            await gate.open()
            await old.value
            XCTAssertEqual(vm.instances.first?.imageName, "New account image")
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
            XCTAssertFalse(vm.isImageNameLoading)
        }
    }

    func testDetailStartedBeforeRefreshCannotOverwriteNewGenerationForSameID() async {
        let gate = TestGate()
        let row = Self.instance("i-first")
        var detailCalls = 0
        let vm = EC2ViewModel(instanceLoader: { [row] }, detailLoader: { id in
            detailCalls += 1
            if detailCalls == 2 {
                await gate.wait()
                return Self.detail(id, dnsName: "old.internal")
            }
            return Self.detail(id, dnsName: "current.internal")
        })
        await vm.loadInstances()
        await vm.waitForCurrentDetail()
        let old = Task { await vm.loadDetail(instanceId: row.instanceId) }
        await gate.waitForEntry()
        await vm.loadInstances()
        await vm.waitForCurrentDetail()
        await gate.open()
        await old.value
        XCTAssertEqual(vm.instanceDetail?.privateDNSName, "current.internal")
        XCTAssertNil(vm.detailError)
        XCTAssertFalse(vm.isDetailLoading)
    }

    func testCountsAndOtherStatesStayLocalAndResetClearsThem() async {
        let rows = [Self.instance("i-first"), Self.instance("i-second", state: "stopped"),
                    Self.instance("i-third", state: "pending"), Self.instance("i-fourth", state: "shutting-down")]
        var listCalls = 0
        let vm = EC2ViewModel(instanceLoader: { listCalls += 1; return rows })
        await vm.loadInstances(selectFirstIfNeeded: false)
        XCTAssertEqual(vm.otherStates, ["pending", "shutting-down"])
        for state in vm.availableStates {
            vm.stateFilter = state
            XCTAssertEqual(vm.filteredInstances.count, vm.loadedCount(for: state))
        }
        vm.searchText = "t3.micro"
        vm.stateFilter = "All"
        XCTAssertEqual(vm.filteredInstances.count, 4, "Removing the visible machine type must preserve type search")
        XCTAssertEqual(listCalls, 1, "Reading counts and changing filters must not query AWS")
        vm.reset()
        XCTAssertEqual(vm.stateFilter, "All")
        XCTAssertEqual(vm.loadedCount(for: "All"), 0)
        XCTAssertTrue(vm.otherStates.isEmpty)
        XCTAssertTrue(vm.filteredInstances.isEmpty)
    }

    private static func instance(_ id: String, state: String = "running") -> EC2InstanceModel {
        EC2InstanceModel(instanceId: id, name: id, instanceType: "t3.micro", state: state, privateIP: nil,
                         publicIP: nil, platformDetails: nil, architecture: nil, vpcId: nil, subnetId: nil,
                         availabilityZone: nil, securityGroups: [], imageId: "ami-test", imageName: nil, keyName: nil,
                         launchTime: nil, tags: [:])
    }

    private static func detail(_ id: String, dnsName: String? = nil) -> EC2InstanceDetailModel {
        EC2InstanceDetailModel(instanceId: id, privateDNSName: dnsName, publicDNSName: nil, ipv6Address: nil,
                               monitoringState: nil, stateTransitionReason: nil, iamProfileARN: nil,
                               rootDeviceName: nil, rootDeviceType: nil, virtualizationType: nil, hypervisor: nil,
                               lifecycle: nil, spotRequestId: nil, capacityReservationId: nil, cpuCoreCount: nil,
                               threadsPerCore: nil, ebsOptimized: nil, enaSupport: nil, sourceDestCheck: nil,
                               metadataHttpEndpoint: nil, metadataHttpTokens: nil, metadataHopLimit: nil,
                               metadataTags: nil, networkInterfaces: [], volumes: [], securityGroups: [],
                               warnings: [])
    }
}
