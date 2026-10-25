import XCTest
@testable import AWSPlatform

final class LambdaDemandLoadingTests: XCTestCase {
    @MainActor
    func testBaseListIsVisibleAndSelectableBeforeSummaryCompletes() async {
        let gate = LambdaSummaryGate()
        let rows = [Self.function("first"), Self.function("second")]
        let vm = LambdaViewModel(functionLoader: { rows }, summaryLoader: { _ in
            await gate.wait()
            return LambdaFunctionSummary(state: "Active", lastUpdateStatus: "Successful", tags: ["team": "core"])
        })
        let request = Task { await vm.loadFunctions() }
        await gate.waitForEntry()
        XCTAssertEqual(vm.functions.map(\.functionName), ["first", "second"])
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.isSummaryLoading)
        XCTAssertNil(vm.functions[0].state, "Unknown summary must not appear active")
        vm.selectedFunction = vm.functions[1]
        await gate.open()
        await request.value
        XCTAssertEqual(vm.selectedFunction?.functionName, "second")
        XCTAssertEqual(vm.selectedFunction?.tags, ["team": "core"])
        XCTAssertFalse(vm.isSummaryLoading)
    }

    @MainActor
    func testSummaryBatchesPublishBeforeNextBatchAndLimitConcurrency() async {
        let firstGate = LambdaSummaryGate()
        let secondGate = LambdaSummaryGate()
        let recorder = LambdaSummaryRecorder()
        let rows = (0..<9).map { Self.function("function-\($0)") }
        let vm = LambdaViewModel(functionLoader: { rows }, summaryLoader: { name in
            await recorder.record(name)
            if ["function-0", "function-1", "function-2", "function-3"].contains(name) {
                await firstGate.wait()
            } else { await secondGate.wait() }
            return LambdaFunctionSummary(state: "Active", lastUpdateStatus: nil, tags: [:])
        })
        let request = Task { await vm.loadFunctions(selectFirstIfNeeded: false) }
        await firstGate.waitForEntry()
        while await recorder.count < 4 { await Task.yield() }
        let initialCount = await recorder.count
        XCTAssertEqual(initialCount, 4)
        await firstGate.open()
        await secondGate.waitForEntry()
        XCTAssertEqual(vm.functions.prefix(4).compactMap(\.state), Array(repeating: "Active", count: 4))
        XCTAssertNil(vm.functions[4].state)
        let secondCount = await recorder.count
        XCTAssertLessThanOrEqual(secondCount, 8, "Only the next bounded batch may be running")
        await secondGate.open()
        await request.value
        let finalCount = await recorder.count
        XCTAssertEqual(finalCount, 9)
    }

    @MainActor
    func testOverviewLoadsOnlyBaseDetailAndEachSectionIsLoadedOnce() async {
        var baseCalls = 0
        var sectionCalls: [LambdaDetailSection: Int] = [:]
        let vm = LambdaViewModel(detailLoader: { name in
            baseCalls += 1
            return Self.detail(name)
        }, sectionLoader: { _, section in
            sectionCalls[section, default: 0] += 1
            return LambdaDetailSectionData()
        })
        vm.selectedFunction = Self.function("example")
        while vm.isDetailLoading { await Task.yield() }
        XCTAssertEqual(baseCalls, 1)
        XCTAssertTrue(sectionCalls.isEmpty)
        XCTAssertEqual(vm.functionDetail?.logGroup, "/aws/lambda/example")
        for section in LambdaDetailSection.allCases {
            vm.selectDetailSection(section)
            await vm.waitForDetailSection(section)
            vm.selectDetailSection(nil)
            vm.selectDetailSection(section)
            await vm.waitForDetailSection(section)
            XCTAssertEqual(sectionCalls[section], 1)
            XCTAssertEqual(vm.detailSectionState(section), .loaded)
        }
    }

    @MainActor
    func testSectionSelectedWhileBaseIsLoadingStartsAfterBaseCompletes() async {
        let gate = TestGate()
        var calls = 0
        let vm = LambdaViewModel(detailLoader: { name in
            await gate.wait()
            return Self.detail(name)
        }, sectionLoader: { _, section in
            XCTAssertEqual(section, .triggers)
            calls += 1
            return LambdaDetailSectionData()
        })
        vm.selectedFunction = Self.function("example")
        await gate.waitForEntry()
        vm.selectDetailSection(.triggers)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(vm.detailSectionState(.triggers), .idle)
        await gate.open()
        while vm.isDetailLoading { await Task.yield() }
        await vm.waitForDetailSection(.triggers)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(vm.detailSectionState(.triggers), .loaded)
    }

    @MainActor
    func testSectionFailureIsIndependentAndRequiresExplicitRetry() async {
        var calls: [LambdaDetailSection: Int] = [:]
        let vm = LambdaViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, section in
            calls[section, default: 0] += 1
            if section == .triggers && calls[section] == 1 { throw LambdaDemandError.denied }
            return LambdaDetailSectionData(policyRevisionId: "policy")
        })
        vm.selectedFunction = Self.function("example")
        while vm.isDetailLoading { await Task.yield() }
        vm.selectDetailSection(.triggers)
        await vm.waitForDetailSection(.triggers)
        XCTAssertEqual(vm.detailSectionState(.triggers), .failed("Permission denied."))
        XCTAssertNil(vm.detailError)
        XCTAssertNotNil(vm.functionDetail)
        vm.selectDetailSection(.configuration)
        await vm.waitForDetailSection(.configuration)
        XCTAssertEqual(vm.functionDetail?.policyRevisionId, "policy")
        vm.selectDetailSection(.triggers)
        await vm.waitForDetailSection(.triggers)
        XCTAssertEqual(calls[.triggers], 1)
        vm.retryDetailSection(.triggers)
        await vm.waitForDetailSection(.triggers)
        XCTAssertEqual(calls[.triggers], 2)
        XCTAssertEqual(vm.detailSectionState(.triggers), .loaded)
        XCTAssertEqual(vm.functionDetail?.policyRevisionId, "policy", "A section merge must preserve other groups")
    }

    @MainActor
    func testConcurrentSectionResultsMergeOnlyTheirOwnFields() async {
        let policyGate = TestGate()
        let versionsGate = TestGate()
        let vm = LambdaViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, section in
            switch section {
            case .configuration:
                await policyGate.wait()
                return LambdaDetailSectionData(policyRevisionId: "policy")
            case .versions:
                await versionsGate.wait()
                return LambdaDetailSectionData(aliases: [
                    LambdaAliasModel(name: "live", functionVersion: "2", description: nil,
                                     revisionId: nil, additionalVersionWeights: [:])
                ])
            case .triggers: return LambdaDetailSectionData()
            }
        })
        vm.selectedFunction = Self.function("example")
        while vm.isDetailLoading { await Task.yield() }
        vm.selectDetailSection(.configuration)
        await policyGate.waitForEntry()
        vm.selectDetailSection(.versions)
        await versionsGate.waitForEntry()
        await versionsGate.open()
        await vm.waitForDetailSection(.versions)
        await policyGate.open()
        await vm.waitForDetailSection(.configuration)
        XCTAssertEqual(vm.functionDetail?.policyRevisionId, "policy")
        XCTAssertEqual(vm.functionDetail?.aliases.first?.name, "live")
        XCTAssertEqual(vm.detailSectionState(.versions), .loaded)
    }

    @MainActor
    func testPartialSectionShowsSuccessAndRetriesOnlyTheRequestedGroup() async {
        var sectionCalls: [LambdaDetailSection: Int] = [:]
        var aliasCalls = 0
        let vm = LambdaViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, section in
            sectionCalls[section, default: 0] += 1
            return try await LambdaDetailSectionReader.versions(
                versions: {
                    if sectionCalls[section] == 1 { throw LambdaDemandError.denied }
                    return []
                },
                aliases: {
                    aliasCalls += 1
                    return [LambdaAliasModel(name: "live", functionVersion: "2", description: nil,
                                             revisionId: nil, additionalVersionWeights: [:])]
                },
                provisionedConcurrency: { [] }
            )
        })
        vm.selectedFunction = Self.function("example")
        while vm.isDetailLoading { await Task.yield() }
        vm.selectDetailSection(.versions)
        await vm.waitForDetailSection(.versions)
        XCTAssertEqual(vm.detailSectionState(.versions), .loaded)
        XCTAssertEqual(vm.functionDetail?.aliases.first?.name, "live")
        XCTAssertEqual(vm.detailSectionIssue(.versions)?.message, "Permission denied.")
        XCTAssertNil(vm.detailSectionIssue(.aliases))
        vm.selectDetailSection(nil)
        vm.selectDetailSection(.versions)
        XCTAssertEqual(sectionCalls[.versions], 1, "Partial results are retained until explicit retry")
        vm.retryDetailSection(.versions)
        await vm.waitForDetailSection(.versions)
        XCTAssertEqual(sectionCalls, [.versions: 2])
        XCTAssertEqual(aliasCalls, 2)
        XCTAssertEqual(vm.functionDetail?.aliases.first?.name, "live")
        XCTAssertTrue(vm.detailSectionIssues[.versions]?.isEmpty == true)
    }

    @MainActor
    func testCancelledSectionRequiresExplicitRetry() async {
        var calls = 0
        let vm = LambdaViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, _ in
            calls += 1
            if calls == 1 { throw CancellationError() }
            return LambdaDetailSectionData()
        })
        vm.selectedFunction = Self.function("example")
        while vm.isDetailLoading { await Task.yield() }
        vm.selectDetailSection(.versions)
        await vm.waitForDetailSection(.versions)
        XCTAssertEqual(vm.detailSectionState(.versions), .cancelled)
        vm.selectDetailSection(.versions)
        XCTAssertEqual(calls, 1)
        vm.retryDetailSection(.versions)
        await vm.waitForDetailSection(.versions)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(vm.detailSectionState(.versions), .loaded)
    }

    @MainActor
    func testLateSectionSuccessCannotReturnAfterSelectionABA() async {
        let gate = TestGate()
        var calls = 0
        let vm = LambdaViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, _ in
            calls += 1
            if calls == 1 { await gate.wait() }
            return LambdaDetailSectionData(policyRevisionId: calls == 1 ? "old" : "new")
        })
        vm.selectedFunction = Self.function("first")
        while vm.isDetailLoading { await Task.yield() }
        vm.selectDetailSection(.configuration)
        await gate.waitForEntry()
        vm.selectedFunction = Self.function("second")
        vm.selectedFunction = Self.function("first")
        while vm.isDetailLoading { await Task.yield() }
        await gate.open()
        await Task.yield()
        XCTAssertNil(vm.functionDetail?.policyRevisionId)
        XCTAssertEqual(vm.detailSectionState(.configuration), .idle)
        vm.selectDetailSection(.configuration)
        await vm.waitForDetailSection(.configuration)
        XCTAssertEqual(vm.functionDetail?.policyRevisionId, "new")
    }

    @MainActor
    func testLateBaseFailureCannotReturnAfterSelectionABA() async {
        let gate = TestGate()
        var calls = 0
        let vm = LambdaViewModel(detailLoader: { name in
            calls += 1
            if calls == 1 {
                await gate.wait()
                throw LambdaDemandError.denied
            }
            return Self.detail(name)
        })
        vm.selectedFunction = Self.function("first")
        await gate.waitForEntry()
        vm.selectedFunction = Self.function("second")
        vm.selectedFunction = Self.function("first")
        while vm.isDetailLoading { await Task.yield() }
        await gate.open()
        await Task.yield()
        XCTAssertEqual(vm.functionDetail?.functionName, "first")
        XCTAssertNil(vm.detailError)
        XCTAssertFalse(vm.isDetailLoading)
    }

    @MainActor
    func testResetRejectsLateSectionFailureForSameName() async {
        let gate = TestGate()
        let finished = expectation(description: "old section completed")
        let vm = LambdaViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, _ in
            await gate.wait()
            defer { finished.fulfill() }
            throw LambdaDemandError.denied
        })
        vm.selectedFunction = Self.function("example")
        while vm.isDetailLoading { await Task.yield() }
        vm.selectDetailSection(.versions)
        await gate.waitForEntry()
        vm.reset()
        vm.selectedFunction = Self.function("example")
        while vm.isDetailLoading { await Task.yield() }
        await gate.open()
        await fulfillment(of: [finished], timeout: 1)
        await Task.yield()
        XCTAssertEqual(vm.detailSectionState(.versions), .idle)
        XCTAssertNil(vm.detailError)
    }

    @MainActor
    func testSameNameBaseReloadRejectsPreviousSuccess() async {
        let gate = TestGate()
        let finished = expectation(description: "old base completed")
        var calls = 0
        let vm = LambdaViewModel(detailLoader: { name in
            calls += 1
            let call = calls
            if call == 1 {
                await gate.wait()
                finished.fulfill()
            }
            var result = Self.detail(name)
            result.policyRevisionId = "revision-\(call)"
            return result
        })
        vm.selectedFunction = Self.function("example")
        await gate.waitForEntry()
        vm.reset()
        vm.selectedFunction = Self.function("example")
        while vm.isDetailLoading { await Task.yield() }
        await gate.open()
        await fulfillment(of: [finished], timeout: 1)
        await Task.yield()
        XCTAssertEqual(vm.functionDetail?.policyRevisionId, "revision-2")
        XCTAssertNil(vm.detailError)
    }

    @MainActor
    func testSameNameRefreshInvalidatesOldSectionAndReloadsActiveSection() async {
        let gate = TestGate()
        let finished = expectation(description: "old section completed")
        var calls = 0
        let vm = LambdaViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, _ in
            calls += 1
            let call = calls
            if call == 1 {
                await gate.wait()
                finished.fulfill()
            }
            return LambdaDetailSectionData(policyRevisionId: "revision-\(call)")
        })
        vm.selectedFunction = Self.function("example")
        while vm.isDetailLoading { await Task.yield() }
        vm.selectDetailSection(.configuration)
        await gate.waitForEntry()
        vm.loadDetailForSelection()
        while vm.isDetailLoading { await Task.yield() }
        await vm.waitForDetailSection(.configuration)
        XCTAssertEqual(vm.functionDetail?.policyRevisionId, "revision-2")
        await gate.open()
        await fulfillment(of: [finished], timeout: 1)
        await Task.yield()
        XCTAssertEqual(vm.functionDetail?.policyRevisionId, "revision-2")
        XCTAssertEqual(vm.detailSectionState(.configuration), .loaded)
    }

    @MainActor
    func testSelectionReleasesPreviousCodeAndReturningRequiresManualLoad() async {
        let rows = [Self.function("first"), Self.function("second")]
        var calls = 0
        let vm = LambdaViewModel(codeLoader: { function in
            calls += 1
            var result = function
            result.codeFiles = [LambdaCodeFile(path: "index.js", content: "source", isBinary: false)]
            return result
        })
        vm.functions = rows
        vm.selectedFunction = rows[0]
        await vm.loadCode(for: "first")
        XCTAssertEqual(vm.functions[0].codeFiles.count, 1)
        vm.selectedFunction = vm.functions[1]
        XCTAssertTrue(vm.functions.allSatisfy { $0.codeFiles.isEmpty })
        await vm.loadCode(for: "second")
        XCTAssertTrue(vm.functions[0].codeFiles.isEmpty)
        XCTAssertEqual(vm.functions[1].codeFiles.count, 1)
        vm.selectedFunction = vm.functions[0]
        XCTAssertTrue(vm.functions.allSatisfy { $0.codeFiles.isEmpty })
        XCTAssertTrue(vm.selectedFunction?.codeFiles.isEmpty == true)
        XCTAssertEqual(calls, 2)
    }

    private static func function(_ name: String) -> LambdaFunctionModel {
        LambdaFunctionModel(
            functionName: name, runtime: "nodejs22.x", state: nil, lastUpdateStatus: nil,
            lastModified: nil, memorySize: 128, arn: nil, handler: nil, role: nil,
            codeSize: nil, timeout: 3, environment: [:], vpcConfig: nil,
            packageType: "Zip", imageUri: nil, tags: [:], codeLocation: nil, codeFiles: []
        )
    }

    private static func detail(_ name: String) -> LambdaFunctionDetailModel {
        LambdaFunctionDetailModel(
            functionName: name, description: nil, state: "Active", stateReason: nil,
            stateReasonCode: nil, lastUpdateStatus: "Successful", lastUpdateStatusReason: nil,
            lastUpdateStatusReasonCode: nil, version: "$LATEST", architectures: ["arm64"],
            runtimeVersionARN: nil, revisionId: nil, codeSHA256: nil, configSHA256: nil,
            ephemeralStorageMB: 512, environment: [:], environmentError: nil, vpcId: nil,
            subnetIds: [], securityGroupIds: [], ipv6AllowedForDualStack: nil, layers: [],
            fileSystems: [], deadLetterTargetARN: nil, tracingMode: nil,
            logGroup: "/aws/lambda/\(name)", logFormat: "Text", applicationLogLevel: nil,
            systemLogLevel: nil, kmsKeyARN: nil, sourceKMSKeyARN: nil, snapStartApplyOn: nil,
            snapStartOptimizationStatus: nil, imageEntryPoint: [], imageCommand: [],
            imageWorkingDirectory: nil, codeLocation: nil, imageURI: nil, resolvedImageURI: nil,
            repositoryType: nil, reservedConcurrency: nil, tags: [:], eventSources: [],
            asyncInvokeConfigs: [], functionURLs: [], versions: [], aliases: [],
            provisionedConcurrency: [], policyRevisionId: nil, policyStatements: [], warnings: []
        )
    }
}

private actor LambdaSummaryRecorder {
    private(set) var count = 0
    func record(_ name: String) { count += 1 }
}

private actor LambdaSummaryGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var entered = false
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation {
            continuations.append($0)
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters = []
        }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        opened = true
        continuations.forEach { $0.resume() }
        continuations = []
    }
}

private enum LambdaDemandError: LocalizedError {
    case denied
    var errorDescription: String? { "Permission denied." }
}
