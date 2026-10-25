import SotoCore
import XCTest
@testable import AWSPlatform

final class AWSCLICoordinationTests: XCTestCase {
    func testConcurrentOperationsExcludeUpdatesUntilEveryLeaseEnds() throws {
        let gate = AWSCLIOperationGate()
        let first = try gate.beginOperation()
        let second = try gate.beginOperation()
        Self.assertBusy { _ = try gate.beginUpdate() }
        gate.endOperation(first)
        gate.endOperation(UUID())
        Self.assertBusy { _ = try gate.beginUpdate() }
        gate.endOperation(second)
        gate.endOperation(second)
        let update = try gate.beginUpdate()
        XCTAssertTrue(gate.isUpdating)
        Self.assertBusy { _ = try gate.beginUpdate() }
        Self.assertBusy { _ = try gate.beginOperation() }
        gate.endUpdate(UUID())
        XCTAssertTrue(gate.isUpdating)
        gate.endUpdate(update)
        gate.endUpdate(update)
        XCTAssertFalse(gate.isUpdating)
        gate.endOperation(try gate.beginOperation())
    }

    func testGateSynchronizesOperationsFromMultipleThreads() throws {
        let gate = AWSCLIOperationGate()
        let retained = try gate.beginOperation()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            do {
                let token = try gate.beginOperation()
                Self.assertBusy { _ = try gate.beginUpdate() }
                gate.endOperation(token)
            } catch { XCTFail("Concurrent read operation must be allowed") }
        }
        gate.endOperation(retained)
        let update = try gate.beginUpdate()
        gate.endUpdate(update)
    }

    @MainActor
    func testSSOLeaseCoversRunnerAndReleasesOnSuccessOrSanitizedFailure() async throws {
        let gate = AWSCLIOperationGate()
        var fail = false
        let service = AWSSSOLoginService(gate: gate) { _, _ in
            Self.assertBusy { _ = try gate.beginUpdate() }
            if fail { throw NSError(domain: "private-login-output", code: 1) }
        }
        try await service.login(session: "offline", paths: .init())
        gate.endUpdate(try gate.beginUpdate())
        fail = true
        do {
            try await service.login(session: "offline", paths: .init())
            XCTFail("Expected sanitized login failure")
        } catch {
            XCTAssertEqual(error as? AWSSSOLoginService.LoginError, .failed)
            XCTAssertFalse(error.localizedDescription.contains("private-login-output"))
        }
        gate.endUpdate(try gate.beginUpdate())
    }

    @MainActor
    func testUpdatingPreventsSSOWithoutInvokingRunner() async throws {
        let gate = AWSCLIOperationGate()
        let update = try gate.beginUpdate()
        defer { gate.endUpdate(update) }
        let service = AWSSSOLoginService(gate: gate) { _, _ in XCTFail("Maintenance must block login") }
        do {
            try await service.login(session: "offline", paths: .init())
            XCTFail("Expected maintenance refusal")
        } catch { Self.assertBusyError(error) }
    }

    @MainActor
    func testCancelledSSOReleasesLeaseAfterRunnerExits() async throws {
        let gate = AWSCLIOperationGate()
        let entered = expectation(description: "SSO runner entered")
        let service = AWSSSOLoginService(gate: gate) { _, _ in
            entered.fulfill()
            try await Task.sleep(for: .seconds(30))
        }
        let task = Task { try await service.login(session: "offline", paths: .init()) }
        await fulfillment(of: [entered], timeout: 1)
        Self.assertBusy { _ = try gate.beginUpdate() }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        gate.endUpdate(try gate.beginUpdate())
    }

    func testCredentialLeaseCoversRunnerAndReleasesForInvalidPayload() async throws {
        let gate = AWSCLIOperationGate()
        let provider = AWSCLICredentialProvider(profile: "offline", paths: .init(), gate: gate) { _, _ in
            Self.assertBusy { _ = try gate.beginUpdate() }
            return Data("private-invalid-payload".utf8)
        }
        do {
            _ = try await provider.getCredential(logger: Logger(label: "offline-test"))
            XCTFail("Expected credential decoding failure")
        } catch {
            XCTAssertTrue(error is AWSCLICredentialProvider.ExportError)
            XCTAssertFalse(error.localizedDescription.contains("private-invalid-payload"))
        }
        gate.endUpdate(try gate.beginUpdate())
    }

    func testUpdatingPreventsCredentialExportWithoutHidingBusyError() async throws {
        let gate = AWSCLIOperationGate()
        let update = try gate.beginUpdate()
        defer { gate.endUpdate(update) }
        let provider = AWSCLICredentialProvider(profile: "offline", paths: .init(), gate: gate) { _, _ in
            XCTFail("Maintenance must block export")
            return Data()
        }
        do {
            _ = try await provider.getCredential(logger: Logger(label: "offline-test"))
            XCTFail("Expected maintenance refusal")
        } catch { Self.assertBusyError(error) }
    }

    func testCancelledCredentialRunnerReleasesLease() async throws {
        let gate = AWSCLIOperationGate()
        let entered = expectation(description: "Credential runner entered")
        let provider = AWSCLICredentialProvider(profile: "offline", paths: .init(), gate: gate) { _, _ in
            entered.fulfill()
            try await Task.sleep(for: .seconds(30))
            return Data()
        }
        let task = Task { try await provider.getCredential(logger: Logger(label: "offline-test")) }
        await fulfillment(of: [entered], timeout: 1)
        Self.assertBusy { _ = try gate.beginUpdate() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        gate.endUpdate(try gate.beginUpdate())
    }

    @MainActor
    func testSSMHandoffIsBlockedDuringUpdateAndReleasesAfterHandoffOrFailure() throws {
        let gate = AWSCLIOperationGate()
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var opened = 0
        var acceptsOpen = true
        var service = EC2SSMConnectionService(
            cli: { URL(fileURLWithPath: "/offline/aws") },
            plugin: { URL(fileURLWithPath: "/offline/plugin") },
            open: { _ in
                Self.assertBusy { _ = try gate.beginUpdate() }
                opened += 1
                return acceptsOpen
            }, temporaryDirectory: directory, gate: gate)
        let scope = S3TransferFixtures.context().scope
        let instance = EC2InstanceModel(
            instanceId: "i-0123456789abcdef0", name: "Offline", instanceType: "t3.micro", state: "running",
            privateIP: nil, publicIP: nil, platformDetails: nil, architecture: nil, vpcId: nil,
            subnetId: nil, availabilityZone: nil, securityGroups: [], imageId: nil, imageName: nil,
            keyName: nil, launchTime: nil, tags: [:])
        let request = try EC2SSMConnectionRequest(scope: scope, instance: instance)
        let update = try gate.beginUpdate()
        Self.assertBusy { try service.connect(request, locale: .init(identifier: "en")) }
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        gate.endUpdate(update)
        try service.connect(request, locale: .init(identifier: "en"))
        XCTAssertEqual(opened, 1)
        gate.endUpdate(try gate.beginUpdate())
        acceptsOpen = false
        XCTAssertThrowsError(try service.connect(request, locale: .init(identifier: "en"))) {
            XCTAssertEqual($0 as? EC2SSMConnectionError, .openFailed)
        }
        gate.endUpdate(try gate.beginUpdate())
        service.cli = { nil }
        XCTAssertThrowsError(try service.connect(request, locale: .init(identifier: "en"))) {
            XCTAssertEqual($0 as? EC2SSMConnectionError, .cliMissing)
        }
        gate.endUpdate(try gate.beginUpdate())
    }

    private static func assertBusy(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            Self.assertBusyError($0, file: file, line: line)
        }
    }

    private static func assertBusyError(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case AWSCLIUpdateError.busy = error else {
            XCTFail("Expected a safe maintenance error", file: file, line: line)
            return
        }
    }
}
