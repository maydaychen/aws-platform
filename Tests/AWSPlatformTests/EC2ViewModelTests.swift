import XCTest
@testable import AWSPlatform

final class EC2ViewModelTests: XCTestCase {
    @MainActor
    func testOldListFailureCannotClearNewFavoriteDestination() async {
        let gate = TestGate()
        let instance = makeInstance(imageID: nil)
        var calls = 0
        let vm = EC2ViewModel(instanceLoader: {
            calls += 1
            if calls == 1 {
                await gate.wait()
                throw TestError.failed
            }
            return [instance]
        })
        let old = Task { await vm.loadInstances() }
        await gate.waitForEntry()
        vm.reset()
        await vm.loadInstances()
        await gate.open()
        await old.value
        XCTAssertEqual(vm.instances, [instance])
        XCTAssertNil(vm.error)
    }

    func testImageLookupFailureKeepsInstancesVisible() async {
        let instance = makeInstance(imageID: "ami-123")
        let vm = await MainActor.run {
            EC2ViewModel(
                instanceLoader: { [instance] in [instance] },
                imageNameLoader: { _ in throw TestError.failed }
            )
        }

        await vm.loadInstances()

        await MainActor.run {
            XCTAssertEqual(vm.instances, [instance])
            XCTAssertEqual(vm.selectedInstance, instance)
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testInstanceLoadFailureClearsStateAndShowsError() async {
        let vm = await MainActor.run {
            EC2ViewModel(instanceLoader: { throw TestError.failed })
        }

        await vm.loadInstances()

        await MainActor.run {
            XCTAssertTrue(vm.instances.isEmpty)
            XCTAssertNil(vm.selectedInstance)
            XCTAssertEqual(vm.error, "Test operation failed.")
            XCTAssertFalse(vm.isLoading)
        }
    }

    @MainActor
    func testRefreshFailureRetainsLoadedRowsSelectionAndMarksThemStaleUntilSuccess() async {
        let first = makeInstance(id: "i-first", imageID: nil)
        let second = makeInstance(id: "i-second", imageID: nil)
        var calls = 0
        let vm = EC2ViewModel(instanceLoader: {
            calls += 1
            if calls == 2 { throw TestError.failed }
            return [first, second]
        })
        await vm.loadInstances()
        vm.selectedInstance = second
        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.instances, [first, second])
        XCTAssertEqual(vm.selectedInstance, second)
        XCTAssertTrue(vm.isStale)
        XCTAssertEqual(vm.error, "Test operation failed.")
        XCTAssertFalse(vm.isLoading)

        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.selectedInstance, second)
        XCTAssertFalse(vm.isStale)
        XCTAssertNil(vm.error)
    }

    @MainActor
    func testFirstLoadFailureIsNotMarkedAsAStaleSuccessfulList() async {
        let vm = EC2ViewModel(instanceLoader: { throw TestError.failed })
        await vm.loadInstances()
        XCTAssertTrue(vm.instances.isEmpty)
        XCTAssertNil(vm.selectedInstance)
        XCTAssertFalse(vm.isStale)
        XCTAssertNotNil(vm.error)
    }

    @MainActor
    func testNewScopeClearsStaleRowsSelectionAndOldError() async {
        let row = makeInstance(imageID: nil)
        var calls = 0
        let vm = EC2ViewModel(instanceLoader: {
            calls += 1
            if calls > 1 { throw TestError.failed }
            return [row]
        })
        await vm.loadInstances()
        await vm.loadInstances()
        XCTAssertTrue(vm.isStale)
        let provider = AWSServiceProvider()
        let scope = S3TransferFixtures.context().scope
        vm.configure(provider: provider, scope: scope, refreshImmediately: false)
        XCTAssertEqual(vm.scope, scope)
        XCTAssertTrue(vm.instances.isEmpty)
        XCTAssertNil(vm.selectedInstance)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isStale)
    }

    @MainActor
    func testOldRefreshFailureCannotMarkTheNewScopeStaleOrClearItsSelection() async {
        let gate = TestGate()
        let row = makeInstance(imageID: nil)
        var calls = 0
        let vm = EC2ViewModel(instanceLoader: {
            calls += 1
            if calls > 1 { await gate.wait(); throw TestError.failed }
            return [row]
        })
        await vm.loadInstances()
        vm.refresh()
        await gate.waitForEntry()
        let provider = AWSServiceProvider()
        let scope = S3TransferFixtures.context().scope
        vm.configure(provider: provider, scope: scope, refreshImmediately: false)
        await gate.open()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.scope, scope)
        XCTAssertTrue(vm.instances.isEmpty)
        XCTAssertNil(vm.selectedInstance)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isStale)
        XCTAssertFalse(vm.isLoading)
    }

    func testCancellationDoesNotShowAnError() async {
        let vm = await MainActor.run {
            EC2ViewModel(instanceLoader: { throw CancellationError() })
        }

        await vm.loadInstances()

        await MainActor.run {
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testStateAndSearchFiltersAreCombinedAndCountsUseLoadedRows() async {
        let first = makeInstance(
            id: "i-first",
            name: "first",
            state: "running",
            imageID: nil
        )
        let second = makeInstance(
            id: "i-second",
            name: "second",
            state: "running",
            imageID: nil
        )
        let stopped = makeInstance(
            id: "i-stopped",
            name: "stopped",
            state: "stopped",
            imageID: nil
        )
        let vm = await MainActor.run {
            EC2ViewModel(
                instanceLoader: { [first, second, stopped] in [first, second, stopped] }
            )
        }

        await vm.loadInstances()

        await MainActor.run {
            vm.stateFilter = "running"
            vm.searchText = "SECOND"
            XCTAssertEqual(vm.filteredInstances.map(\.instanceId), ["i-second"])
            XCTAssertEqual(vm.loadedCount(for: "All"), 3)
            XCTAssertEqual(vm.loadedCount(for: "running"), 2)
            XCTAssertEqual(vm.loadedCount(for: "stopped"), 1)
            XCTAssertEqual(vm.loadedCount(for: "pending"), 0)
            XCTAssertEqual(vm.otherStates, [])
        }
    }

    func testRapidSelectionChangeKeepsLatestDetail() async throws {
        let first = makeInstance(
            id: "i-first",
            name: "first",
            state: "running",
            imageID: nil
        )
        let second = makeInstance(
            id: "i-second",
            name: "second",
            state: "running",
            imageID: nil
        )
        let vm = await MainActor.run {
            EC2ViewModel(
                instanceLoader: { [first, second] in [first, second] },
                detailLoader: { instanceId in
                    if instanceId == first.instanceId {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                    return Self.makeDetail(instanceId: instanceId, cpuCreditMode: instanceId == first.instanceId ? .standard : .unlimited)
                }
            )
        }

        await vm.loadInstances()
        await MainActor.run {
            vm.selectedInstance = second
        }
        try await Task.sleep(nanoseconds: 250_000_000)

        await MainActor.run {
            XCTAssertEqual(vm.instanceDetail?.instanceId, second.instanceId)
            XCTAssertEqual(vm.instanceDetail?.cpuCreditMode, .unlimited)
            XCTAssertNil(vm.detailError)
            XCTAssertFalse(vm.isDetailLoading)
        }
    }

    func testDetailFailureIsScopedToDetailPane() async {
        let instance = makeInstance(imageID: nil)
        let vm = await MainActor.run {
            EC2ViewModel(
                instanceLoader: { [instance] in [instance] },
                detailLoader: { _ in throw TestError.failed }
            )
        }

        await vm.loadInstances()
        await vm.loadDetail(instanceId: instance.instanceId)

        await MainActor.run {
            XCTAssertEqual(vm.instances, [instance])
            XCTAssertEqual(vm.detailError, "Test operation failed.")
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isDetailLoading)
        }
    }

    private func makeInstance(
        id: String = "i-123",
        name: String = "example",
        state: String = "running",
        imageID: String?
    ) -> EC2InstanceModel {
        EC2InstanceModel(
            instanceId: id,
            name: name,
            instanceType: "t3.micro",
            state: state,
            privateIP: "10.0.0.1",
            publicIP: nil,
            platformDetails: "Linux/UNIX",
            architecture: "arm64",
            vpcId: "vpc-123",
            subnetId: "subnet-123",
            availabilityZone: "us-east-1a",
            securityGroups: ["sg-123"],
            imageId: imageID,
            imageName: nil,
            keyName: nil,
            launchTime: nil,
            tags: ["Name": "example"]
        )
    }

    private static func makeDetail(instanceId: String, cpuCreditMode: EC2CPUCreditMode? = nil) -> EC2InstanceDetailModel {
        EC2InstanceDetailModel(
            instanceId: instanceId,
            privateDNSName: nil,
            publicDNSName: nil,
            ipv6Address: nil,
            monitoringState: "disabled",
            stateTransitionReason: nil,
            iamProfileARN: nil,
            rootDeviceName: "/dev/xvda",
            rootDeviceType: "ebs",
            virtualizationType: "hvm",
            hypervisor: "xen",
            lifecycle: nil,
            spotRequestId: nil,
            capacityReservationId: nil,
            cpuCoreCount: 1,
            threadsPerCore: 2,
            ebsOptimized: true,
            enaSupport: true,
            sourceDestCheck: true,
            metadataHttpEndpoint: "enabled",
            metadataHttpTokens: "required",
            metadataHopLimit: 1,
            metadataTags: "disabled",
            networkInterfaces: [],
            volumes: [],
            securityGroups: [],
            warnings: [],
            cpuCreditMode: cpuCreditMode
        )
    }
}

private enum TestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Test operation failed."
    }
}
