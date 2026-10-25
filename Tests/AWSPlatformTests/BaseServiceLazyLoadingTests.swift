import XCTest
@testable import AWSPlatform

@MainActor
final class BaseServiceLazyLoadingTests: XCTestCase {
    func testConfigureWithoutImmediateRefreshDoesNotStartProviderRequests() async {
        // No configured client or credential binding: an accidental load fails before network access.
        let provider = AWSServiceProvider()
        let scope = S3TransferFixtures.context().scope
        let ec2 = EC2ViewModel()
        let lambda = LambdaViewModel()
        let s3 = S3ViewModel()
        ec2.configure(provider: provider, scope: scope, refreshImmediately: false)
        lambda.configure(provider: provider, scope: scope, refreshImmediately: false)
        s3.configure(provider: provider, scope: scope, refreshImmediately: false)
        await ec2.waitForCurrentLoad()
        await lambda.waitForCurrentLoad()
        await s3.waitForCurrentLoad()
        XCTAssertNil(ec2.error)
        XCTAssertNil(lambda.error)
        XCTAssertNil(s3.error)
        XCTAssertFalse(ec2.isLoading)
        XCTAssertFalse(lambda.isLoading)
        XCTAssertFalse(s3.isLoading)

        ec2.loadIfNeeded()
        lambda.loadIfNeeded()
        s3.loadIfNeeded()
        await ec2.waitForCurrentLoad()
        await lambda.waitForCurrentLoad()
        await s3.waitForCurrentLoad()
        XCTAssertNotNil(ec2.error, "Entering the selected service must still perform its first load")
        XCTAssertNotNil(lambda.error)
        XCTAssertNotNil(s3.error)
    }

    func testConstructionAndMissingLoaderDoNotStartLoading() async {
        for service in BaseLazyService.allCases {
            let probe = BaseLazyProbe()
            let configured = makeHarness(service, probe: probe)
            await configured.wait()
            let count = await probe.count()
            XCTAssertEqual(count, 0, service.rawValue)
            XCTAssertFalse(configured.isLoading(), service.rawValue)

            let unconfigured = makeHarness(service)
            unconfigured.loadIfNeeded()
            unconfigured.refresh()
            await unconfigured.loadDirectly()
            await unconfigured.wait()
            unconfigured.loadIfNeeded()
            XCTAssertFalse(unconfigured.isLoading(), service.rawValue)
            XCTAssertTrue(unconfigured.rows().isEmpty, service.rawValue)
            XCTAssertNil(unconfigured.error(), service.rawValue)
        }
    }

    func testFirstVisitDeduplicatesBeforeTaskStartsDuringLoadingAndAfterCompletion() async {
        for service in BaseLazyService.allCases {
            let gate = TestGate()
            let probe = BaseLazyProbe(gates: [1: gate])
            let vm = makeHarness(service, probe: probe)
            vm.loadIfNeeded()
            vm.loadIfNeeded()
            await gate.waitForEntry()
            vm.loadIfNeeded()
            await gate.open()
            await vm.wait()
            vm.loadIfNeeded()
            await vm.wait()

            let count = await probe.count()
            XCTAssertEqual(count, 1, service.rawValue)
            XCTAssertEqual(vm.rows(), ["current"], service.rawValue)
            XCTAssertFalse(vm.isLoading(), service.rawValue)
        }
    }

    func testEmptyFailureAndCancellationDoNotAutoRetryButRefreshCanRetry() async {
        for service in BaseLazyService.allCases {
            for outcome in [BaseLazyOutcome.success([]), .failure, .cancellation] {
                let probe = BaseLazyProbe(outcomes: [outcome, .success(["recovered"])])
                let vm = makeHarness(service, probe: probe)
                vm.loadIfNeeded()
                await vm.wait()
                vm.loadIfNeeded()
                await vm.wait()
                let beforeRetry = await probe.count()
                XCTAssertEqual(beforeRetry, 1, service.rawValue)
                XCTAssertTrue(vm.rows().isEmpty, service.rawValue)
                XCTAssertEqual(vm.error() != nil, outcome == .failure, service.rawValue)
                XCTAssertFalse(vm.isLoading(), service.rawValue)

                vm.refresh()
                vm.loadIfNeeded()
                await vm.wait()
                let afterRetry = await probe.count()
                XCTAssertEqual(afterRetry, 2, service.rawValue)
                XCTAssertEqual(vm.rows(), ["recovered"], service.rawValue)
                XCTAssertNil(vm.error(), service.rawValue)
            }
        }
    }

    func testCancelledScheduledLoadDoesNotAutoRetryUntilExplicitRefresh() async {
        for service in BaseLazyService.allCases {
            let probe = BaseLazyProbe()
            let vm = makeHarness(service, probe: probe)
            vm.loadIfNeeded()
            vm.cancel()
            vm.loadIfNeeded()
            await vm.wait()
            let cancelledCount = await probe.count()
            XCTAssertEqual(cancelledCount, 0, service.rawValue)

            vm.refresh()
            await vm.wait()
            let retriedCount = await probe.count()
            XCTAssertEqual(retriedCount, 1, service.rawValue)
            XCTAssertEqual(vm.rows(), ["current"], service.rawValue)
        }
    }

    func testCancelledInflightLoadRejectsLateResultsAndRequiresRefresh() async {
        for service in BaseLazyService.allCases {
            let gate = TestGate()
            let probe = BaseLazyProbe(gates: [1: gate])
            let vm = makeHarness(service, probe: probe)
            vm.loadIfNeeded()
            await gate.waitForEntry()
            vm.cancel()
            vm.loadIfNeeded()
            await gate.open()
            await vm.wait()
            vm.loadIfNeeded()
            await vm.wait()
            let cancelledCount = await probe.count()
            XCTAssertEqual(cancelledCount, 1, service.rawValue)
            XCTAssertTrue(vm.rows().isEmpty, service.rawValue)
            XCTAssertNil(vm.error(), service.rawValue)

            vm.refresh()
            await vm.wait()
            let retriedCount = await probe.count()
            XCTAssertEqual(retriedCount, 2, service.rawValue)
            XCTAssertEqual(vm.rows(), ["current"], service.rawValue)
        }
    }

    func testResetAllowsNewVisitAndRejectsOldNavigationSuccessOrFailure() async {
        for service in BaseLazyService.allCases {
            for oldOutcome in [BaseLazyOutcome.success(["old"]), .failure] {
                let gate = TestGate()
                let probe = BaseLazyProbe(
                    outcomes: [oldOutcome, .success(["new"])], gates: [1: gate]
                )
                let vm = makeHarness(service, probe: probe)
                let oldNavigation = Task { await vm.loadDirectly() }
                await gate.waitForEntry()
                vm.reset()
                vm.loadIfNeeded()
                await vm.wait()
                await gate.open()
                await oldNavigation.value
                vm.loadIfNeeded()
                await vm.wait()

                let count = await probe.count()
                XCTAssertEqual(count, 2, service.rawValue)
                XCTAssertEqual(vm.rows(), ["new"], service.rawValue)
                XCTAssertNil(vm.error(), service.rawValue)
                XCTAssertFalse(vm.isLoading(), service.rawValue)
            }
        }
    }

    func testNavigationLoadCountsAsFirstVisitWhileLoadingAndAfterCompletion() async {
        for service in BaseLazyService.allCases {
            let gate = TestGate()
            let probe = BaseLazyProbe(gates: [1: gate])
            let vm = makeHarness(service, probe: probe)
            let navigation = Task { await vm.loadDirectly() }
            await gate.waitForEntry()
            vm.loadIfNeeded()
            await gate.open()
            await navigation.value
            vm.loadIfNeeded()
            await vm.wait()

            let count = await probe.count()
            XCTAssertEqual(count, 1, service.rawValue)
            XCTAssertEqual(vm.rows(), ["current"], service.rawValue)
        }
    }

    func testRepeatedExplicitRefreshReplacesPendingTaskAndInvalidatesOlderNavigation() async {
        for service in BaseLazyService.allCases {
            let gate = TestGate()
            let probe = BaseLazyProbe(
                outcomes: [.success(["old"]), .success(["refreshed"])], gates: [1: gate]
            )
            let vm = makeHarness(service, probe: probe)
            let navigation = Task { await vm.loadDirectly() }
            await gate.waitForEntry()
            vm.refresh()
            vm.refresh()
            vm.loadIfNeeded()
            await vm.wait()
            await gate.open()
            await navigation.value

            let count = await probe.count()
            XCTAssertEqual(count, 2, service.rawValue)
            XCTAssertEqual(vm.rows(), ["refreshed"], service.rawValue)
        }
    }

    private func makeHarness(_ service: BaseLazyService, probe: BaseLazyProbe? = nil) -> BaseLazyHarness {
        switch service {
        case .ec2:
            let loader: EC2ViewModel.InstanceLoader? = probe.map { probe in
                { try await probe.load().map(baseLazyInstance) }
            }
            let vm = EC2ViewModel(instanceLoader: loader)
            return .init(
                loadIfNeeded: vm.loadIfNeeded, refresh: vm.refresh, wait: vm.waitForCurrentLoad,
                loadDirectly: { await vm.loadInstances(selectFirstIfNeeded: false) },
                cancel: vm.cancelLoading, reset: vm.reset,
                rows: { vm.instances.map(\.instanceId) }, isLoading: { vm.isLoading }, error: { vm.error }
            )
        case .lambda:
            let loader: LambdaViewModel.FunctionLoader? = probe.map { probe in
                { try await probe.load().map(baseLazyFunction) }
            }
            let vm = LambdaViewModel(functionLoader: loader)
            return .init(
                loadIfNeeded: vm.loadIfNeeded, refresh: vm.refresh, wait: vm.waitForCurrentLoad,
                loadDirectly: { await vm.loadFunctions(selectFirstIfNeeded: false) },
                cancel: vm.cancelLoading, reset: vm.reset,
                rows: { vm.functions.map(\.functionName) }, isLoading: { vm.isLoading }, error: { vm.error }
            )
        case .s3:
            let loader: S3ViewModel.BucketLoader? = probe.map { probe in
                { try await probe.load().map(baseLazyBucket) }
            }
            let vm = S3ViewModel(bucketLoader: loader)
            return .init(
                loadIfNeeded: vm.loadIfNeeded, refresh: vm.refresh, wait: vm.waitForCurrentLoad,
                loadDirectly: vm.loadBuckets, cancel: vm.cancelLoading, reset: vm.reset,
                rows: { vm.buckets.map(\.name) }, isLoading: { vm.isLoading }, error: { vm.error }
            )
        }
    }
}

private enum BaseLazyService: String, CaseIterable {
    case ec2, lambda, s3
}

@MainActor
private struct BaseLazyHarness {
    let loadIfNeeded: @MainActor () -> Void
    let refresh: @MainActor () -> Void
    let wait: @MainActor () async -> Void
    let loadDirectly: @MainActor () async -> Void
    let cancel: @MainActor () -> Void
    let reset: @MainActor () -> Void
    let rows: @MainActor () -> [String]
    let isLoading: @MainActor () -> Bool
    let error: @MainActor () -> String?
}

private enum BaseLazyOutcome: Equatable {
    case success([String])
    case failure
    case cancellation
}

private enum BaseLazyError: Error { case failed }

private actor BaseLazyProbe {
    private let outcomes: [BaseLazyOutcome]
    private let gates: [Int: TestGate]
    private var calls = 0

    init(outcomes: [BaseLazyOutcome] = [.success(["current"])], gates: [Int: TestGate] = [:]) {
        self.outcomes = outcomes
        self.gates = gates
    }

    func load() async throws -> [String] {
        calls += 1
        let call = calls
        let outcome = outcomes[min(call - 1, outcomes.count - 1)]
        await gates[call]?.wait()
        switch outcome {
        case .success(let rows): return rows
        case .failure: throw BaseLazyError.failed
        case .cancellation: throw CancellationError()
        }
    }

    func count() -> Int { calls }
}

private func baseLazyInstance(_ id: String) -> EC2InstanceModel {
    .init(
        instanceId: id, name: id, instanceType: "t3.micro", state: "running",
        privateIP: nil, publicIP: nil, platformDetails: nil, architecture: nil,
        vpcId: nil, subnetId: nil, availabilityZone: nil, securityGroups: [],
        imageId: nil, imageName: nil, keyName: nil, launchTime: nil, tags: [:]
    )
}

private func baseLazyFunction(_ name: String) -> LambdaFunctionModel {
    .init(
        functionName: name, runtime: nil, state: nil, lastUpdateStatus: nil,
        lastModified: nil, memorySize: nil, arn: nil, handler: nil, role: nil,
        codeSize: nil, timeout: nil, environment: [:], vpcConfig: nil,
        packageType: nil, imageUri: nil, tags: [:], codeLocation: nil, codeFiles: []
    )
}

private func baseLazyBucket(_ name: String) -> S3BucketModel {
    .init(name: name, region: nil, creationDate: nil, tags: [:])
}
