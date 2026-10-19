import XCTest
@testable import AWSPlatform

@MainActor
final class S3ObjectMergeLifecycleTests: XCTestCase {
    func testCancelResetAndLeavingBrowserCancelPendingMergeAndRejectItsLateResult() async {
        for action in 0..<3 {
            let gate = TestGate()
            let observation = MergeCancellationObservation()
            let vm = S3ViewModel(
                objectLoader: { _, _, _ in
                    .init(objects: [Self.object("old-profile/file")], nextContinuationToken: "stale-token")
                },
                objectMerger: { existing, page in
                    await gate.wait()
                    await observation.record(Task.isCancelled)
                    // Intentionally ignore cancellation to exercise the VM's generation guard.
                    return S3ObjectListing.mergeSorted(existing, with: page)
                }
            )
            let pending = Task { await vm.loadObjects(bucket: "example") }
            await gate.waitForEntry()
            XCTAssertTrue(vm.isLoading)
            XCTAssertTrue(vm.objects.isEmpty)
            switch action {
            case 0: vm.cancelLoading()
            case 1: vm.reset()
            default: vm.leaveObjectBrowser()
            }
            await gate.open()
            await pending.value
            let cancelled = await observation.wasCancelled
            XCTAssertTrue(cancelled, "Scope cancellation must propagate into the pending merge")
            XCTAssertTrue(vm.objects.isEmpty)
            XCTAssertNil(vm.selectedObject)
            XCTAssertNil(vm.nextObjectToken)
            XCTAssertNil(vm.error)
            XCTAssertNil(vm.objectPageError)
            XCTAssertFalse(vm.hasLoadedObjectPage)
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testOldMergeCannotOverwriteSamePrefixAfterNavigatingAwayAndBack() async {
        let gate = TestGate()
        var aRequests = 0
        let vm = S3ViewModel(
            objectLoader: { _, prefix, _ in
                if prefix == "a/" {
                    aRequests += 1
                    return .init(objects: [Self.object(aRequests == 1 ? "a/old" : "a/current")])
                }
                return .init(objects: [Self.object(prefix + "current")])
            },
            objectMerger: { existing, page in
                if page.first?.key == "a/old" { await gate.wait() }
                return S3ObjectListing.mergeSorted(existing, with: page)
            }
        )
        let old = Task { await vm.loadObjects(bucket: "example", prefix: "a/") }
        await gate.waitForEntry()
        await vm.loadObjects(bucket: "example", prefix: "b/")
        await vm.loadObjects(bucket: "example", prefix: "a/")
        XCTAssertEqual(vm.objects.map(\.key), ["a/current"])
        await gate.open()
        await old.value
        XCTAssertEqual(vm.objects.map(\.key), ["a/current"])
        XCTAssertEqual(vm.selectedObject?.key, "a/current")
        XCTAssertEqual(vm.currentPrefix, "a/")
        XCTAssertFalse(vm.isLoading)
    }

    func testSelectionChangedDuringAppendMergeUsesLatestChoiceAndFreshMetadata() async {
        let gate = TestGate()
        let vm = S3ViewModel(
            objectLoader: { _, _, token in
                token == nil
                    ? .init(objects: [Self.object("first"), Self.object("second", size: 1)], nextContinuationToken: "next")
                    : .init(objects: [Self.object("second", size: 2), Self.object("third")])
            },
            objectMerger: { existing, page in
                if !existing.isEmpty { await gate.wait() }
                return S3ObjectListing.mergeSorted(existing, with: page)
            }
        )
        await vm.loadObjects(bucket: "example")
        XCTAssertEqual(vm.selectedObject?.key, "first")
        vm.loadMoreObjects(bucket: "example")
        await gate.waitForEntry()
        vm.selectedObject = vm.objects.first { $0.key == "second" }
        await gate.open()
        await settle(vm)
        XCTAssertEqual(vm.selectedObject?.key, "second")
        XCTAssertEqual(vm.selectedObject?.size, 2)
        XCTAssertEqual(vm.objects.map(\.key), ["first", "second", "third"])
    }

    func testOldMergeFailureCannotEndNewPrefixLoadingOrSetItsError() async {
        let oldGate = TestGate()
        let newGate = TestGate()
        let vm = S3ViewModel(
            objectLoader: { _, prefix, _ in
                if prefix == "new/" { await newGate.wait() }
                return .init(objects: [Self.object(prefix + "file")])
            },
            objectMerger: { existing, page in
                if page.first?.key == "old/file" {
                    await oldGate.wait()
                    throw MergeFailure.failed
                }
                return S3ObjectListing.mergeSorted(existing, with: page)
            }
        )
        let old = Task { await vm.loadObjects(bucket: "example", prefix: "old/") }
        await oldGate.waitForEntry()
        let current = Task { await vm.loadObjects(bucket: "example", prefix: "new/") }
        await newGate.waitForEntry()
        await oldGate.open()
        await old.value
        XCTAssertTrue(vm.isLoading)
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.objectPageError)
        await newGate.open()
        await current.value
        XCTAssertEqual(vm.objects.map(\.key), ["new/file"])
    }

    func testCancelledAppendMergeDoesNotConsumeTokenOrBlockRetry() async {
        let gate = TestGate()
        var moreCalls = 0
        var tokens: [String?] = []
        let vm = S3ViewModel(
            objectLoader: { _, _, token in
                tokens.append(token)
                guard token != nil else {
                    return .init(objects: [Self.object("first")], nextContinuationToken: "next")
                }
                moreCalls += 1
                return .init(objects: [Self.object(moreCalls == 1 ? "discarded" : "accepted")])
            },
            objectMerger: { existing, page in
                if page.first?.key == "discarded" { await gate.wait() }
                return S3ObjectListing.mergeSorted(existing, with: page)
            }
        )
        await vm.loadObjects(bucket: "example")
        vm.loadMoreObjects(bucket: "example")
        await gate.waitForEntry()
        vm.cancelLoading()
        XCTAssertEqual(vm.objects.map(\.key), ["first"])
        XCTAssertEqual(vm.nextObjectToken, "next")
        vm.loadMoreObjects(bucket: "example")
        await settle(vm)
        await gate.open()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(tokens, [nil, "next", "next"])
        XCTAssertEqual(vm.objects.map(\.key), ["accepted", "first"])
        XCTAssertNil(vm.nextObjectToken)
        XCTAssertNil(vm.objectPageError)
    }

    private nonisolated static func object(_ key: String, size: Int64? = nil) -> S3ObjectModel {
        .init(key: key, size: size, lastModified: nil, storageClass: nil, isPrefix: false)
    }

    private func settle(_ vm: S3ViewModel, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if !vm.isLoading { return }
            await Task.yield()
        }
        XCTFail("Merge did not finish", file: file, line: line)
    }
}

private actor MergeCancellationObservation {
    private(set) var wasCancelled = false
    func record(_ value: Bool) { wasCancelled = value }
}

private enum MergeFailure: Error { case failed }
