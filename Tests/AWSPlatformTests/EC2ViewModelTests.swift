import XCTest
@testable import AWSPlatform

final class EC2ViewModelTests: XCTestCase {
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

    private func makeInstance(imageID: String?) -> EC2InstanceModel {
        EC2InstanceModel(
            instanceId: "i-123",
            name: "example",
            instanceType: "t3.micro",
            state: "running",
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
}

private enum TestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Test operation failed."
    }
}
