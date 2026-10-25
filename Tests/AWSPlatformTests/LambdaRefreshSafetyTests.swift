import Foundation
import SotoLambda
import XCTest
@testable import AWSPlatform

final class LambdaRefreshSafetyTests: XCTestCase {
    @MainActor
    func testRefreshFailureKeepsListSelectionAndDetailUntilSuccessfulRetry() async throws {
        var calls = 0
        let original = Self.function(memory: 128)
        let updated = Self.function(memory: 512)
        let vm = LambdaViewModel(functionLoader: {
            calls += 1
            if calls == 2 { throw LambdaRefreshTestError.failed }
            return calls == 1 ? [original] : [updated]
        }, detailLoader: { name in
            try LambdaResponseMapper.detail(functionName: name, response: .init(configuration: .init(version: "1")))
        })
        await vm.loadFunctions()
        while vm.isDetailLoading { await Task.yield() }
        let detail = try XCTUnwrap(vm.functionDetail)
        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.functions, [original])
        XCTAssertEqual(vm.selectedFunction, original)
        XCTAssertEqual(vm.functionDetail, detail)
        XCTAssertTrue(vm.isStale)
        XCTAssertNotNil(vm.error)

        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.functions, [updated])
        XCTAssertEqual(vm.selectedFunction, updated)
        XCTAssertFalse(vm.isStale)
        XCTAssertNil(vm.error)
    }

    @MainActor
    func testInitialLoadFailureHasNoStaleInventory() async {
        let vm = LambdaViewModel(functionLoader: { throw LambdaRefreshTestError.failed })
        await vm.loadFunctions()
        XCTAssertTrue(vm.functions.isEmpty)
        XCTAssertNil(vm.selectedFunction)
        XCTAssertFalse(vm.isStale)
        XCTAssertNotNil(vm.error)
    }

    @MainActor
    func testScopeChangeClearsStaleInventoryAndSelection() async {
        var calls = 0
        let function = Self.function()
        let vm = LambdaViewModel(functionLoader: {
            calls += 1
            if calls > 1 { throw LambdaRefreshTestError.failed }
            return [function]
        })
        await vm.loadFunctions()
        await vm.loadFunctions()
        XCTAssertTrue(vm.isStale)
        let scope = S3TransferFixtures.context(profileName: "new-profile").scope
        vm.configure(provider: AWSServiceProvider(), scope: scope, refreshImmediately: false)
        XCTAssertEqual(vm.scope, scope)
        XCTAssertTrue(vm.functions.isEmpty)
        XCTAssertNil(vm.selectedFunction)
        XCTAssertNil(vm.functionDetail)
        XCTAssertFalse(vm.isStale)
        XCTAssertNil(vm.error)
        vm.reset()
        XCTAssertNil(vm.scope)
    }

    @MainActor
    func testScopeChangeRejectsLateFailureFromPreviousRefresh() async {
        let gate = TestGate()
        var calls = 0
        let function = Self.function()
        let vm = LambdaViewModel(functionLoader: {
            calls += 1
            if calls > 1 {
                await gate.wait()
                throw LambdaRefreshTestError.failed
            }
            return [function]
        })
        await vm.loadFunctions()
        let refresh = Task { await vm.loadFunctions() }
        await gate.waitForEntry()
        let scope = S3TransferFixtures.context(profileName: "new-profile").scope
        vm.configure(provider: AWSServiceProvider(), scope: scope, refreshImmediately: false)
        await gate.open()
        await refresh.value
        XCTAssertEqual(vm.scope, scope)
        XCTAssertTrue(vm.functions.isEmpty)
        XCTAssertNil(vm.selectedFunction)
        XCTAssertFalse(vm.isStale)
        XCTAssertNil(vm.error)
    }

    @MainActor
    func testCancelledRefreshKeepsInventoryWithoutMarkingFailure() async {
        let gate = TestGate()
        var calls = 0
        let function = Self.function()
        let vm = LambdaViewModel(functionLoader: {
            calls += 1
            if calls > 1 {
                await gate.wait()
                throw LambdaRefreshTestError.failed
            }
            return [function]
        })
        await vm.loadFunctions()
        vm.refresh()
        await gate.waitForEntry()
        vm.cancelLoading()
        await gate.open()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.functions, [function])
        XCTAssertEqual(vm.selectedFunction, function)
        XCTAssertFalse(vm.isStale)
        XCTAssertNil(vm.error)
    }

    private static func function(memory: Int = 128) -> LambdaFunctionModel {
        LambdaResponseMapper.function(.init(functionArn: "arn:aws:lambda:us-east-1:111122223333:function:example",
                                            functionName: "example", memorySize: memory))
    }
}

private enum LambdaRefreshTestError: LocalizedError {
    case failed
    var errorDescription: String? { "Lambda fixture refresh failed." }
}
