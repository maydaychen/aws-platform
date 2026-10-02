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

    func testHealthLookupFailureKeepsInstancesVisible() async {
        let instance = makeInstance(imageID: nil)
        let vm = await MainActor.run {
            EC2ViewModel(
                instanceLoader: { [instance] in [instance] },
                healthLoader: { _ in throw TestError.failed }
            )
        }

        await vm.loadInstances()

        await MainActor.run {
            XCTAssertEqual(vm.instances, [instance])
            XCTAssertTrue(vm.instanceHealth.isEmpty)
            XCTAssertNil(vm.error)
        }
    }

    func testStateAndHealthFiltersAreCombined() async {
        let healthy = makeInstance(
            id: "i-healthy",
            name: "healthy",
            state: "running",
            imageID: nil
        )
        let impaired = makeInstance(
            id: "i-impaired",
            name: "impaired",
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
                instanceLoader: { [healthy, impaired, stopped] in
                    [healthy, impaired, stopped]
                },
                healthLoader: { _ in
                    [
                        healthy.instanceId: EC2InstanceHealth(
                            systemStatus: "ok",
                            instanceStatus: "ok",
                            attachedEBSStatus: "ok",
                            events: []
                        ),
                        impaired.instanceId: EC2InstanceHealth(
                            systemStatus: "impaired",
                            instanceStatus: "ok",
                            attachedEBSStatus: "ok",
                            events: []
                        )
                    ]
                }
            )
        }

        await vm.loadInstances()

        await MainActor.run {
            vm.stateFilter = "running"
            vm.healthFilter = .attention
            XCTAssertEqual(vm.filteredInstances.map(\.instanceId), ["i-impaired"])
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
                    return Self.makeDetail(instanceId: instanceId)
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

    private static func makeDetail(instanceId: String) -> EC2InstanceDetailModel {
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
            health: nil,
            warnings: []
        )
    }
}

private enum TestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Test operation failed."
    }
}
