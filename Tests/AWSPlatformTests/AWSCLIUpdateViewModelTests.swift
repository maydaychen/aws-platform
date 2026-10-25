import XCTest
@testable import AWSPlatform

final class AWSCLIUpdateViewModelTests: XCTestCase {
    @MainActor
    func testNumericVersionComparisonOffersMinorVersionUpdate() async {
        let probe = CLIUpdateProbe(snapshots: [installation("2.9.9")], available: "2.10.0")
        let vm = makeViewModel(probe)
        vm.check()
        await vm.waitForCurrentTask()
        XCTAssertEqual(vm.latestVersion?.description, "2.10.0")
        XCTAssertEqual(vm.status, "An AWS CLI update is available.")
        XCTAssertTrue(vm.canUpdate)
        XCTAssertFalse(vm.isChecking)
    }

    @MainActor
    func testSameOrNewerInstalledVersionDoesNotOfferDowngrade() async {
        for installed in ["2.38.5", "2.39.0"] {
            let probe = CLIUpdateProbe(snapshots: [installation(installed)])
            let vm = makeViewModel(probe)
            vm.check()
            await vm.waitForCurrentTask()
            vm.update()
            XCTAssertEqual(vm.status, "AWS CLI is up to date.")
            XCTAssertFalse(vm.canUpdate)
            let calls = await probe.calls
            XCTAssertEqual(calls.install, 0)
        }
    }

    @MainActor
    func testMissingV1AndUnmanagedInstallationsDoNotQueryCatalogOrInstall() async {
        let unsupported: [AWSCLIInstallation?] = [
            nil, installation("1.42.0"), installation("2.37.9", source: .unmanaged)
        ]
        for local in unsupported {
            let probe = CLIUpdateProbe(snapshots: [local])
            let vm = makeViewModel(probe)
            vm.check()
            await vm.waitForCurrentTask()
            vm.update()
            XCTAssertEqual(vm.installation, local)
            XCTAssertNil(vm.latestVersion)
            XCTAssertFalse(vm.canUpdate)
            XCTAssertTrue(vm.canCheck)
            let calls = await probe.calls
            XCTAssertEqual(calls.catalog, 0)
            XCTAssertEqual(calls.install, 0)
        }
    }

    @MainActor
    func testCatalogFailureKeepsLocalDetailsAndSanitizesError() async {
        let local = installation("2.37.9")
        let probe = CLIUpdateProbe(snapshots: [local], catalogFailure: .privateDetails)
        let vm = makeViewModel(probe)
        vm.check()
        await vm.waitForCurrentTask()
        XCTAssertEqual(vm.installation, local)
        XCTAssertNil(vm.latestVersion)
        XCTAssertEqual(vm.error, AWSCLIUpdateError.checkFailed.localizedDescription)
        XCTAssertFalse(vm.error?.contains("secret-value") ?? true)
        XCTAssertTrue(vm.canCheck)
        XCTAssertFalse(vm.canUpdate)
    }

    @MainActor
    func testCatalogVersionOutsideV2CannotEnableUpdate() async {
        let probe = CLIUpdateProbe(snapshots: [installation("2.37.9")], available: "3.0.0")
        let vm = makeViewModel(probe)
        vm.check()
        await vm.waitForCurrentTask()
        XCTAssertNil(vm.latestVersion)
        XCTAssertEqual(vm.error, AWSCLIUpdateError.invalidVersion.localizedDescription)
        XCTAssertFalse(vm.canUpdate)
    }

    @MainActor
    func testCheckIfNeededAndRepeatedClicksShareOneCheck() async {
        let pause = CLIUpdatePause()
        let entered = expectation(description: "local inspection entered")
        let probe = CLIUpdateProbe(snapshots: [installation("2.37.9")])
        let vm = AWSCLIUpdateViewModel(detect: {
            let local = await probe.detect()
            entered.fulfill()
            await pause.wait()
            return local
        }, latest: { try await probe.latest($0) }, install: { _, _, _ in
            XCTFail("A check must not install")
        }, activity: TransferActivity(), gate: AWSCLIOperationGate())
        vm.checkIfNeeded()
        vm.checkIfNeeded()
        vm.check()
        XCTAssertTrue(vm.isChecking)
        XCTAssertFalse(vm.canCheck)
        await fulfillment(of: [entered], timeout: 1)
        await pause.open()
        await vm.waitForCurrentTask()
        vm.checkIfNeeded()
        let calls = await probe.calls
        XCTAssertEqual(calls.detect, 1)
        XCTAssertEqual(calls.catalog, 1)
    }

    @MainActor
    func testInstallBindsCheckedSnapshotAndDeduplicatesClicks() async {
        let before = installation("2.37.9")
        let after = installation("2.38.5")
        let probe = CLIUpdateProbe(snapshots: [before, before, after])
        let pause = CLIUpdatePause()
        let entered = expectation(description: "installer entered")
        let activity = TransferActivity()
        let gate = AWSCLIOperationGate()
        let vm = makeViewModel(probe, activity: activity, gate: gate, installPause: pause, entered: entered)
        vm.check()
        await vm.waitForCurrentTask()
        vm.update()
        vm.update()
        vm.check()
        XCTAssertTrue(vm.isUpdating)
        XCTAssertTrue(activity.cliMaintenanceActive)
        XCTAssertTrue(gate.isUpdating)
        XCTAssertFalse(vm.canCheck)
        XCTAssertNil(activity.begin())
        XCTAssertThrowsError(try gate.beginOperation())
        await fulfillment(of: [entered], timeout: 1)
        await pause.open()
        await vm.waitForCurrentTask()
        XCTAssertEqual(vm.installation, after)
        XCTAssertEqual(vm.status, "AWS CLI was updated successfully.")
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isUpdating)
        XCTAssertNil(vm.phase)
        XCTAssertFalse(activity.cliMaintenanceActive)
        XCTAssertFalse(gate.isUpdating)
        let calls = await probe.calls
        XCTAssertEqual(calls, .init(detect: 3, catalog: 1, install: 1))
        let request = await probe.installRequest
        XCTAssertEqual(request?.0, before)
        XCTAssertEqual(request?.1, AWSCLIVersion("2.38.5"))
    }

    @MainActor
    func testChangedInstallationBeforeUpdatePreventsInstallerAndReleasesLeases() async throws {
        let checked = installation("2.37.9")
        let changes = [
            installation("2.38.0"),
            installation("2.37.9", executable: "/opt/homebrew/bin/aws"),
            installation("2.37.9", resolved: "/other/aws"),
            installation("2.37.9", source: .unmanaged)
        ]
        for changed in changes {
            let probe = CLIUpdateProbe(snapshots: [checked, changed])
            let activity = TransferActivity()
            let gate = AWSCLIOperationGate()
            let vm = makeViewModel(probe, activity: activity, gate: gate)
            vm.check()
            await vm.waitForCurrentTask()
            vm.update()
            await vm.waitForCurrentTask()
            XCTAssertEqual(vm.error, AWSCLIUpdateError.installationChanged.localizedDescription)
            let calls = await probe.calls
            XCTAssertEqual(calls.install, 0)
            try assertReleased(activity, gate)
        }
    }

    @MainActor
    func testPostInstallMustObserveSameEntryAndSourceAtTargetVersion() async throws {
        let before = installation("2.37.9")
        let invalid: [AWSCLIInstallation?] = [
            nil,
            installation("2.37.9"),
            installation("1.42.0"),
            installation("2.38.5", executable: "/other/aws"),
            installation("2.38.5", source: .unmanaged)
        ]
        for actual in invalid {
            let probe = CLIUpdateProbe(snapshots: [before, before, actual])
            let activity = TransferActivity()
            let gate = AWSCLIOperationGate()
            let vm = makeViewModel(probe, activity: activity, gate: gate)
            vm.check()
            await vm.waitForCurrentTask()
            vm.update()
            await vm.waitForCurrentTask()
            XCTAssertEqual(vm.installation, actual)
            XCTAssertEqual(vm.error, AWSCLIUpdateError.updateFailed.localizedDescription)
            XCTAssertEqual(vm.status, "AWS CLI update failed.")
            try assertReleased(activity, gate)
        }
    }

    @MainActor
    func testHomebrewMayChangeCellarVersionWhileKeepingSameEntryAndManager() async {
        let brew = AWSCLIInstallSource.homebrew(prefix: URL(fileURLWithPath: "/opt/homebrew"),
                                               executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
        let before = installation("2.37.9", executable: "/opt/homebrew/bin/aws",
                                  resolved: "/opt/homebrew/Cellar/awscli/2.37.9/bin/aws", source: brew)
        let after = installation("2.39.0", executable: "/opt/homebrew/bin/aws",
                                 resolved: "/opt/homebrew/Cellar/awscli/2.39.0/bin/aws", source: brew)
        let probe = CLIUpdateProbe(snapshots: [before, before, after])
        let vm = makeViewModel(probe)
        vm.check()
        await vm.waitForCurrentTask()
        vm.update()
        await vm.waitForCurrentTask()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.installation, after)
        XCTAssertEqual(vm.status, "AWS CLI was updated successfully.")
    }

    @MainActor
    func testAuthorizationCancellationAndInstallFailureAlwaysReleaseLeases() async throws {
        for failure in [CLIUpdateTestFailure.cancelled, .privateDetails] {
            let before = installation("2.37.9")
            let probe = CLIUpdateProbe(snapshots: [before], installFailure: failure)
            let activity = TransferActivity()
            let gate = AWSCLIOperationGate()
            let vm = makeViewModel(probe, activity: activity, gate: gate)
            vm.check()
            await vm.waitForCurrentTask()
            vm.update()
            await vm.waitForCurrentTask()
            let expected: AWSCLIUpdateError = failure == .cancelled ? .authorizationCancelled : .updateFailed
            XCTAssertEqual(vm.error, expected.localizedDescription)
            XCTAssertEqual(vm.status, failure == .cancelled
                           ? "AWS CLI update authorization was cancelled." : "AWS CLI update failed.")
            XCTAssertFalse(vm.isUpdating)
            XCTAssertTrue(vm.canUpdate, "A cancelled or failed attempt can be retried")
            try assertReleased(activity, gate)
        }
    }

    @MainActor
    func testActiveCLIOperationBlocksUpdateWithoutInstalling() async throws {
        let probe = CLIUpdateProbe(snapshots: [installation("2.37.9")])
        let activity = TransferActivity()
        let gate = AWSCLIOperationGate()
        let operation = try gate.beginOperation()
        let vm = makeViewModel(probe, activity: activity, gate: gate)
        vm.check()
        await vm.waitForCurrentTask()
        vm.update()
        await vm.waitForCurrentTask()
        XCTAssertEqual(vm.error, AWSCLIUpdateError.busy.localizedDescription)
        XCTAssertFalse(activity.cliMaintenanceActive)
        let calls = await probe.calls
        XCTAssertEqual(calls.install, 0)
        XCTAssertEqual(calls.detect, 1)
        gate.endOperation(operation)
        try assertReleased(activity, gate)
    }

    @MainActor
    func testActiveS3TransferOrRestartBlocksUpdateWithoutInstalling() async throws {
        let probe = CLIUpdateProbe(snapshots: [installation("2.37.9")])
        let activity = TransferActivity()
        let vm = makeViewModel(probe, activity: activity)
        vm.check()
        await vm.waitForCurrentTask()
        let transfer = try XCTUnwrap(activity.begin())
        XCTAssertFalse(vm.canUpdate)
        vm.update()
        activity.finish(transfer)
        XCTAssertTrue(vm.canUpdate)
        XCTAssertFalse(activity.postponeUpdate {})
        XCTAssertFalse(vm.canUpdate)
        XCTAssertFalse(vm.canCheck)
        vm.update()
        let calls = await probe.calls
        XCTAssertEqual(calls.install, 0)
        XCTAssertFalse(activity.cliMaintenanceActive)
    }

    @MainActor
    func testQuitWaitsForInstallAndResumesOnlyAfterGateIsReleased() async {
        let before = installation("2.37.9")
        let probe = CLIUpdateProbe(snapshots: [before, before, installation("2.38.5")])
        let activity = TransferActivity()
        let gate = AWSCLIOperationGate()
        let pause = CLIUpdatePause()
        let entered = expectation(description: "installer entered before quit")
        let vm = makeViewModel(probe, activity: activity, gate: gate, installPause: pause, entered: entered)
        vm.check()
        await vm.waitForCurrentTask()
        vm.update()
        await fulfillment(of: [entered], timeout: 1)
        var replies = 0
        XCTAssertTrue(activity.postponeTermination {
            replies += 1
            XCTAssertFalse(gate.isUpdating, "Quit must resume only after CLI exclusivity ends")
        })
        XCTAssertTrue(activity.postponeTermination { XCTFail("Duplicate quit continuation") })
        XCTAssertEqual(replies, 0)
        XCTAssertTrue(vm.isUpdating)
        await pause.open()
        await vm.waitForCurrentTask()
        XCTAssertEqual(replies, 1)
        XCTAssertFalse(activity.cliMaintenanceActive)
        XCTAssertFalse(vm.isUpdating)
    }

    @MainActor
    func testInFlightUpdateSurvivesLosingTheSettingsReference() async {
        let before = installation("2.37.9")
        let probe = CLIUpdateProbe(snapshots: [before, before, installation("2.38.5")])
        let activity = TransferActivity()
        let gate = AWSCLIOperationGate()
        let pause = CLIUpdatePause()
        let entered = expectation(description: "installation survives view closure")
        var viewModel: AWSCLIUpdateViewModel? = makeViewModel(probe, activity: activity, gate: gate,
                                                            installPause: pause, entered: entered)
        weak var inFlight = viewModel
        viewModel?.check()
        await viewModel?.waitForCurrentTask()
        viewModel?.update()
        viewModel = nil
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertNotNil(inFlight, "The running update owns its lifetime independently of Settings")
        XCTAssertTrue(activity.cliMaintenanceActive)
        await pause.open()
        await inFlight?.waitForCurrentTask()
        inFlight = nil
        let calls = await probe.calls
        XCTAssertEqual(calls.detect, 3, "Post-install verification must still finish")
        XCTAssertFalse(activity.cliMaintenanceActive)
        XCTAssertFalse(gate.isUpdating)
    }

    @MainActor
    private func makeViewModel(_ probe: CLIUpdateProbe, activity: TransferActivity? = nil,
                               gate: AWSCLIOperationGate = AWSCLIOperationGate(),
                               installPause: CLIUpdatePause? = nil,
                               entered: XCTestExpectation? = nil) -> AWSCLIUpdateViewModel {
        AWSCLIUpdateViewModel(detect: { await probe.detect() }, latest: { try await probe.latest($0) },
                              install: { local, target, progress in
            try await probe.install(local, target)
            progress(.installing)
            entered?.fulfill()
            await installPause?.wait()
        }, activity: activity ?? TransferActivity(), gate: gate)
    }

    @MainActor
    private func assertReleased(_ activity: TransferActivity, _ gate: AWSCLIOperationGate,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(activity.cliMaintenanceActive, file: file, line: line)
        XCTAssertFalse(gate.isUpdating, file: file, line: line)
        let operation = try gate.beginOperation()
        gate.endOperation(operation)
        let transfer = try XCTUnwrap(activity.begin(), file: file, line: line)
        activity.finish(transfer)
    }

    private func installation(_ version: String, executable: String = "/usr/local/bin/aws",
                              resolved: String = "/usr/local/aws-cli/aws",
                              source: AWSCLIInstallSource = .officialPackage) -> AWSCLIInstallation {
        AWSCLIInstallation(executableURL: URL(fileURLWithPath: executable), resolvedURL: URL(fileURLWithPath: resolved),
                           version: AWSCLIVersion(version)!, source: source)
    }
}

private enum CLIUpdateTestFailure: Error, LocalizedError {
    case privateDetails, cancelled
    var errorDescription: String? { "secret-value from an untrusted subprocess" }
}

private actor CLIUpdateProbe {
    struct Calls: Equatable, Sendable {
        var detect = 0
        var catalog = 0
        var install = 0
    }
    private let snapshots: [AWSCLIInstallation?]
    private let available: AWSCLIVersion
    private let catalogFailure: CLIUpdateTestFailure?
    private let installFailure: CLIUpdateTestFailure?
    private(set) var calls = Calls()
    private(set) var installRequest: (AWSCLIInstallation, AWSCLIVersion)?

    init(snapshots: [AWSCLIInstallation?], available: String = "2.38.5",
         catalogFailure: CLIUpdateTestFailure? = nil, installFailure: CLIUpdateTestFailure? = nil) {
        self.snapshots = snapshots
        self.available = AWSCLIVersion(available)!
        self.catalogFailure = catalogFailure
        self.installFailure = installFailure
    }

    func detect() -> AWSCLIInstallation? {
        defer { calls.detect += 1 }
        return snapshots[min(calls.detect, snapshots.count - 1)]
    }

    func latest(_ source: AWSCLIInstallSource) throws -> AWSCLIVersion {
        calls.catalog += 1
        if let catalogFailure { throw catalogFailure }
        return available
    }

    func install(_ local: AWSCLIInstallation, _ target: AWSCLIVersion) throws {
        calls.install += 1
        installRequest = (local, target)
        if installFailure == .cancelled { throw AWSCLIUpdateError.authorizationCancelled }
        if let installFailure { throw installFailure }
    }
}

private actor CLIUpdatePause {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}
