import Foundation
import SotoCore
import SotoEC2
import XCTest
@testable import AWSPlatform

final class EC2CPUCreditModeTests: XCTestCase {
    func testOnlyTInstanceTypesApply() {
        for type in ["t2.nano", "t3.micro", "t3a.large", "t4g.xlarge"] {
            XCTAssertTrue(EC2CPUCreditMode.applies(to: type), type)
        }
        for type in ["m7i.large", "c6g.large", "trn1.2xlarge", "", "-", "t", "t3.", "t3", "t3.micro.extra"] {
            XCTAssertFalse(EC2CPUCreditMode.applies(to: type), type)
        }
    }

    @MainActor
    func testStandardAndUnlimitedBindRequestAndResponseToInstanceID() async throws {
        for (raw, expected) in [("standard", EC2CPUCreditMode.standard), ("unlimited", .unlimited)] {
            let mode = try await EC2ViewModel.fetchCPUCreditMode(instanceId: "i-selected", instanceType: "t3.micro") { request in
                XCTAssertEqual(request.instanceIds, ["i-selected"])
                XCTAssertNil(request.maxResults)
                XCTAssertNil(request.filters)
                XCTAssertNil(request.nextToken)
                return .init(instanceCreditSpecifications: [
                    .init(cpuCredits: "standard", instanceId: "i-other"),
                    .init(cpuCredits: raw, instanceId: "i-selected")
                ])
            }
            XCTAssertEqual(mode, expected)
        }
    }

    @MainActor
    func testMissingOrUnrecognizedCreditValueIsUnknown() async throws {
        let responses: [EC2.DescribeInstanceCreditSpecificationsResult] = [
            .init(),
            .init(instanceCreditSpecifications: []),
            .init(instanceCreditSpecifications: [.init(cpuCredits: "standard", instanceId: "i-other")]),
            .init(instanceCreditSpecifications: [.init(cpuCredits: "unlimited")]),
            .init(instanceCreditSpecifications: [.init(instanceId: "i-selected")]),
            .init(instanceCreditSpecifications: [.init(cpuCredits: "", instanceId: "i-selected")]),
            .init(instanceCreditSpecifications: [.init(cpuCredits: "future-mode", instanceId: "i-selected")])
        ]
        for response in responses {
            let mode = try await EC2ViewModel.fetchCPUCreditMode(instanceId: "i-selected", instanceType: "t4g.small") { _ in response }
            XCTAssertEqual(mode, .unknown)
        }
    }

    @MainActor
    func testNonTInstancesNeverRequestCreditSpecifications() async throws {
        for type in ["m7i.large", "trn1.2xlarge", "", "-"] {
            let mode = try await EC2ViewModel.fetchCPUCreditMode(instanceId: "i-selected", instanceType: type) { _ in
                XCTFail("Non-T instance must not query CPU credits")
                throw URLError(.notConnectedToInternet)
            }
            XCTAssertNil(mode)
        }
    }

    @MainActor
    func testPermissionFailureIsDistinctFromUnknownAndReadFailure() async throws {
        for code in ["UnauthorizedOperation", "AccessDenied", "AccessDeniedException", "Forbidden", "ForbiddenException"] {
            let mode = try await EC2ViewModel.fetchCPUCreditMode(instanceId: "i-selected", instanceType: "t2.micro") { _ in
                throw AWSResponseError(errorCode: code)
            }
            XCTAssertEqual(mode, .permissionDenied, code)
        }
    }

    @MainActor
    func testNetworkAndOtherAWSFailuresAreReadFailures() async throws {
        let errors: [Error] = [URLError(.notConnectedToInternet), AWSResponseError(errorCode: "Throttling"), AWSResponseError(errorCode: "ExpiredToken")]
        for error in errors {
            let mode = try await EC2ViewModel.fetchCPUCreditMode(instanceId: "i-selected", instanceType: "t3a.small") { _ in
                throw error
            }
            XCTAssertEqual(mode, .readFailed)
        }
    }

    @MainActor
    func testCancellationIsPropagatedInsteadOfBecomingReadFailure() async {
        do {
            _ = try await EC2ViewModel.fetchCPUCreditMode(instanceId: "i-selected", instanceType: "t3.micro") { _ in
                throw CancellationError()
            }
            XCTFail("Cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testLateSuccessAfterTaskCancellationIsDiscarded() async {
        let gate = TestGate()
        let task = Task {
            try await EC2ViewModel.fetchCPUCreditMode(instanceId: "i-selected", instanceType: "t3.micro") { _ in
                await gate.wait()
                return .init(instanceCreditSpecifications: [.init(cpuCredits: "standard", instanceId: "i-selected")])
            }
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("Cancelled result must be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testDetailRowsDisplayAllStatesAndKeepOtherFields() {
        let vm = EC2ViewModel()
        for mode in [EC2CPUCreditMode.standard, .unlimited, .unknown, .permissionDenied, .readFailed] {
            vm.instanceDetail = makeDetail(mode: mode)
            let view = EC2DetailView(instance: makeInstance(type: "t3.micro"), vm: vm)
            XCTAssertEqual(view.cpuCreditFields.map(\.0), ["CPU Credit mode"])
            XCTAssertEqual(view.cpuCreditFields.map(\.1), [mode.rawValue])
            XCTAssertEqual(vm.instanceDetail?.cpuCoreCount, 1)
            XCTAssertNil(vm.detailError)
        }
    }

    @MainActor
    func testNonTDetailHidesFieldEvenIfModeExists() {
        let vm = EC2ViewModel()
        vm.instanceDetail = makeDetail(mode: .standard)
        XCTAssertTrue(EC2DetailView(instance: makeInstance(type: "m7i.large"), vm: vm).cpuCreditFields.isEmpty)
    }

    @MainActor
    func testLoadingDetailFailureAndUnknownRemainDistinct() {
        let vm = EC2ViewModel()
        let view = EC2DetailView(instance: makeInstance(type: "t3.micro"), vm: vm)
        XCTAssertEqual(view.cpuCreditFields.first?.1, "Loading…")
        vm.instanceDetail = makeDetail(mode: nil)
        XCTAssertEqual(view.cpuCreditFields.first?.1, "Unknown")
        vm.instanceDetail = nil
        vm.detailError = "Unable to load details"
        XCTAssertEqual(view.cpuCreditFields.first?.1, EC2CPUCreditMode.readFailed.rawValue)
        vm.instanceDetail = makeDetail(mode: .unlimited, instanceID: "i-other")
        XCTAssertEqual(view.cpuCreditFields.first?.1, EC2CPUCreditMode.readFailed.rawValue)
    }

    func testCreditLabelsAreLocalizedInBothLanguages() {
        let keys = ["CPU Credit mode"] + [EC2CPUCreditMode.standard, .unlimited, .unknown, .permissionDenied, .readFailed].map(\.rawValue)
        for key in keys {
            XCTAssertEqual(L10n.text(key, locale: Locale(identifier: "en")), key)
            XCTAssertNotEqual(L10n.text(key, locale: Locale(identifier: "zh-Hans")), key)
        }
    }

    private func makeInstance(type: String) -> EC2InstanceModel {
        EC2InstanceModel(instanceId: "i-selected", name: "Offline fixture", instanceType: type,
                         state: "running", privateIP: nil, publicIP: nil, platformDetails: nil,
                         architecture: nil, vpcId: nil, subnetId: nil, availabilityZone: nil,
                         securityGroups: [], imageId: nil, imageName: nil, keyName: nil, launchTime: nil, tags: [:])
    }

    private func makeDetail(mode: EC2CPUCreditMode?, instanceID: String = "i-selected") -> EC2InstanceDetailModel {
        EC2InstanceDetailModel(instanceId: instanceID, privateDNSName: nil, publicDNSName: nil,
                               ipv6Address: nil, monitoringState: nil, stateTransitionReason: nil,
                               iamProfileARN: nil, rootDeviceName: nil, rootDeviceType: nil,
                               virtualizationType: nil, hypervisor: nil, lifecycle: nil,
                               spotRequestId: nil, capacityReservationId: nil, cpuCoreCount: 1,
                               threadsPerCore: 2, ebsOptimized: nil, enaSupport: nil, sourceDestCheck: nil,
                               metadataHttpEndpoint: nil, metadataHttpTokens: nil, metadataHopLimit: nil,
                               metadataTags: nil, networkInterfaces: [], volumes: [], securityGroups: [],
                               health: nil, warnings: [], cpuCreditMode: mode)
    }
}
