import SotoCore
import XCTest
@testable import AWSPlatform

@MainActor
final class S3ObjectPaginationTests: XCTestCase {
    func testOwnerRejectionOrDeletedBucketClearsPreviouslyVisiblePages() async {
        for code in ["AccessDenied", "Forbidden", "NoSuchBucket"] {
            let vm = S3ViewModel(objectLoader: { _, _, token in
                if token != nil { throw AWSResponseError(errorCode: code) }
                return .init(objects: [self.object("old-owner/file")], nextContinuationToken: "next")
            })
            await vm.loadObjects(bucket: "example")
            XCTAssertFalse(vm.objects.isEmpty)
            vm.loadMoreObjects(bucket: "example")
            await settle(vm)
            XCTAssertTrue(vm.objects.isEmpty)
            XCTAssertNil(vm.selectedObject)
            XCTAssertNil(vm.nextObjectToken)
            XCTAssertFalse(vm.hasLoadedObjectPage)
            XCTAssertNotNil(vm.objectPageError)
        }
    }

    func testInitialLoadFetchesOnePageAndMorePreservesSelectionAndLocalSearch() async {
        var requests: [String?] = []
        let vm = S3ViewModel(objectLoader: { bucket, prefix, token in
            XCTAssertEqual(bucket, "example")
            XCTAssertEqual(prefix, "a//中文/")
            requests.append(token)
            return token == nil
                ? .init(objects: [self.object("a//中文/first", size: 1)], nextContinuationToken: "opaque+/=")
                : .init(objects: [self.object("a//中文/last"), self.object("a//中文/first", size: 2)])
        })
        await vm.loadObjects(bucket: "example", prefix: "a//中文/")
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests[0])
        XCTAssertTrue(vm.hasMoreObjects)
        vm.objectSearchText = "last"
        XCTAssertTrue(vm.filteredObjects.isEmpty)
        XCTAssertEqual(requests.count, 1, "Local search must not request additional pages")
        vm.loadMoreObjects(bucket: "example")
        await settle(vm)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1], "opaque+/=")
        XCTAssertEqual(vm.filteredObjects.map(\.key), ["a//中文/last"])
        XCTAssertEqual(vm.selectedObject?.key, "a//中文/first")
        XCTAssertEqual(vm.selectedObject?.size, 2)
        XCTAssertFalse(vm.hasMoreObjects)
        vm.loadMoreObjects(bucket: "example")
        XCTAssertEqual(requests.count, 2)
    }

    func testEmptyPageDoesNotAutoAdvanceOrHideContinuation() async {
        var calls = 0
        let vm = S3ViewModel(objectLoader: { _, _, token in
            calls += 1
            return token == nil ? .init(objects: [], nextContinuationToken: "next") : .init(objects: [self.object("file")])
        })
        await vm.loadObjects(bucket: "example")
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(vm.objects.isEmpty)
        XCTAssertTrue(vm.hasMoreObjects)
        XCTAssertTrue(vm.hasLoadedObjectPage)
        vm.loadMoreObjects(bucket: "example")
        await settle(vm)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(vm.objects.map(\.key), ["file"])
        XCTAssertFalse(vm.hasMoreObjects)
    }

    func testAppendingCanonicallyEquivalentKeysPreservesExactSelectedKey() async {
        let composed = object("caf\u{e9}", size: 1)
        let decomposed = object("cafe\u{301}", size: 2)
        let vm = S3ViewModel(objectLoader: { _, _, token in
            token == nil ? .init(objects: [composed], nextContinuationToken: "next") : .init(objects: [decomposed])
        })
        await vm.loadObjects(bucket: "example")
        vm.loadMoreObjects(bucket: "example")
        await settle(vm)
        XCTAssertEqual(vm.objects.count, 2)
        XCTAssertEqual(vm.selectedObject.map { Data($0.key.utf8) }, Data(composed.key.utf8))
        XCTAssertEqual(vm.selectedObject?.size, 1)
    }

    func testMoreFailureKeepsRowsAndTokenAndRetriesTheSamePage() async {
        var tokens: [String?] = []
        let vm = S3ViewModel(objectLoader: { _, _, token in
            tokens.append(token)
            if token == nil { return .init(objects: [self.object("first")], nextContinuationToken: "next") }
            if tokens.count == 2 { throw PageFailure.failed }
            return .init(objects: [self.object("last")])
        })
        await vm.loadObjects(bucket: "example")
        vm.loadMoreObjects(bucket: "example")
        await settle(vm)
        XCTAssertEqual(vm.objects.map(\.key), ["first"])
        XCTAssertEqual(vm.selectedObject?.key, "first")
        XCTAssertEqual(vm.nextObjectToken, "next")
        XCTAssertEqual(vm.objectPageError, "Mock page failed")
        XCTAssertNil(vm.error)
        vm.loadMoreObjects(bucket: "example")
        await settle(vm)
        XCTAssertEqual(tokens, [nil, "next", "next"])
        XCTAssertNil(vm.objectPageError)
        XCTAssertEqual(vm.objects.map(\.key), ["first", "last"])
    }

    func testDuplicateClicksAndWrongBucketCannotStartAnotherPage() async {
        let gate = TestGate()
        var calls = 0
        let vm = S3ViewModel(objectLoader: { _, _, token in
            calls += 1
            if token == nil { return .init(objects: [self.object("first")], nextContinuationToken: "next") }
            await gate.wait()
            return .init(objects: [])
        })
        vm.loadMoreObjects(bucket: "example")
        XCTAssertEqual(calls, 0)
        await vm.loadObjects(bucket: "example")
        vm.loadMoreObjects(bucket: "other")
        XCTAssertFalse(vm.isLoading)
        vm.loadMoreObjects(bucket: "example")
        XCTAssertTrue(vm.isLoadingMoreObjects)
        vm.loadMoreObjects(bucket: "example")
        await gate.waitForEntry()
        XCTAssertEqual(calls, 2)
        await gate.open()
        await settle(vm)
        XCTAssertFalse(vm.isLoadingMoreObjects)
    }

    func testRefreshRestartsAtFirstPageAndNavigationClearsScopeSynchronously() async {
        var requests: [(String, String?)] = []
        let vm = S3ViewModel(objectLoader: { _, prefix, token in
            requests.append((prefix, token))
            return .init(objects: [self.object(prefix + (token == nil ? "first" : "last"))],
                         nextContinuationToken: token == nil ? "next" : nil)
        })
        await vm.loadObjects(bucket: "example", prefix: "a/b/")
        vm.loadMoreObjects(bucket: "example")
        await settle(vm)
        vm.navigateToPrefix(bucket: "example", prefix: "a/b/")
        XCTAssertTrue(vm.objects.isEmpty)
        XCTAssertNil(vm.nextObjectToken)
        await settle(vm)
        XCTAssertEqual(requests.last?.1, nil)
        XCTAssertEqual(vm.objects.map(\.key), ["a/b/first"])
        vm.navigateToPrefix(bucket: "example", prefix: "a/")
        XCTAssertEqual(vm.currentPrefix, "a/", "Upload target must change before the next event")
        XCTAssertTrue(vm.objects.isEmpty)
        await settle(vm)
        XCTAssertEqual(requests.map(\.0), ["a/b/", "a/b/", "a/b/", "a/"])
        XCTAssertNil(requests.last?.1)
    }

    func testLateMorePageCannotRepopulateResetProfileOrLeaveBrowser() async {
        for leaveBrowser in [false, true] {
            let gate = TestGate()
            let vm = S3ViewModel(objectLoader: { _, _, token in
                if token == nil { return .init(objects: [self.object("first")], nextContinuationToken: "next") }
                await gate.wait()
                return .init(objects: [self.object("old-account")], nextContinuationToken: "stale")
            })
            await vm.loadObjects(bucket: "example")
            vm.loadMoreObjects(bucket: "example")
            await gate.waitForEntry()
            if leaveBrowser { vm.leaveObjectBrowser() } else { vm.reset() }
            await gate.open()
            for _ in 0..<50 { await Task.yield() }
            XCTAssertTrue(vm.objects.isEmpty)
            XCTAssertNil(vm.selectedObject)
            XCTAssertNil(vm.nextObjectToken)
            XCTAssertNil(vm.objectPageError)
            XCTAssertFalse(vm.isLoading)
            XCTAssertFalse(vm.hasLoadedObjectPage)
        }
    }

    func testOldPageFailureCannotEndNewPrefixLoadingOrSetItsError() async {
        let oldGate = TestGate()
        let newGate = TestGate()
        let vm = S3ViewModel(objectLoader: { _, prefix, token in
            if prefix == "old/", token != nil { await oldGate.wait(); throw PageFailure.failed }
            if prefix == "new/" { await newGate.wait() }
            return .init(objects: [self.object(prefix + "file")], nextContinuationToken: prefix == "old/" ? "next" : nil)
        })
        await vm.loadObjects(bucket: "example", prefix: "old/")
        vm.loadMoreObjects(bucket: "example")
        await oldGate.waitForEntry()
        vm.navigateToPrefix(bucket: "example", prefix: "new/")
        await newGate.waitForEntry()
        await oldGate.open()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(vm.isLoading)
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.objectPageError)
        await newGate.open()
        await settle(vm)
        XCTAssertEqual(vm.objects.map(\.key), ["new/file"])
    }

    func testCancelKeepsLoadedRowsAndUnconsumedTokenAndAllowsRetry() async {
        let gate = TestGate()
        var moreCalls = 0
        let vm = S3ViewModel(objectLoader: { _, _, token in
            if token == nil { return .init(objects: [self.object("first")], nextContinuationToken: "next") }
            moreCalls += 1
            if moreCalls == 1 { await gate.wait() }
            return .init(objects: [self.object(moreCalls == 1 ? "discarded" : "accepted")])
        })
        await vm.loadObjects(bucket: "example")
        vm.loadMoreObjects(bucket: "example")
        await gate.waitForEntry()
        vm.cancelLoading()
        XCTAssertEqual(vm.nextObjectToken, "next")
        await gate.open()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(vm.objects.map(\.key), ["first"])
        vm.loadMoreObjects(bucket: "example")
        await settle(vm)
        XCTAssertEqual(vm.objects.map(\.key), ["accepted", "first"])
        XCTAssertEqual(moreCalls, 2)
    }

    func testSelectingAnotherBucketDropsContinuationAndOldObjectState() async {
        var calls = 0
        let vm = S3ViewModel(objectLoader: { _, _, _ in
            calls += 1
            return .init(objects: [self.object("old/file")], nextContinuationToken: "old-token")
        })
        await vm.loadObjects(bucket: "old", prefix: "old/")
        vm.selectBucket(.init(name: "new", region: "us-east-1", creationDate: nil, versioningEnabled: nil,
                              encryptionEnabled: nil, publicAccessBlock: nil, tags: [:], detailError: nil))
        XCTAssertTrue(vm.objects.isEmpty)
        XCTAssertNil(vm.nextObjectToken)
        XCTAssertEqual(vm.currentPrefix, "")
        vm.loadMoreObjects(bucket: "old")
        XCTAssertEqual(calls, 1)
    }

    func testRepeatedAndCyclicTokensFailWithoutAppendingDuplicatePages() async {
        for cycle in [false, true] {
            var requests: [String?] = []
            let vm = S3ViewModel(objectLoader: { _, _, token in
                requests.append(token)
                if token == nil { return .init(objects: [self.object("first")], nextContinuationToken: "one") }
                if cycle && token == "one" { return .init(objects: [self.object("second")], nextContinuationToken: "two") }
                return .init(objects: [self.object("invalid")], nextContinuationToken: "one")
            })
            await vm.loadObjects(bucket: "example")
            vm.loadMoreObjects(bucket: "example")
            await settle(vm)
            if cycle { vm.loadMoreObjects(bucket: "example"); await settle(vm) }
            XCTAssertEqual(vm.objects.map(\.key), cycle ? ["first", "second"] : ["first"])
            XCTAssertEqual(vm.nextObjectToken, cycle ? "two" : "one")
            XCTAssertNotNil(vm.objectPageError)
            XCTAssertNil(vm.error)
            XCTAssertEqual(requests.count, cycle ? 3 : 2)
        }
    }

    private func object(_ key: String, size: Int64? = nil) -> S3ObjectModel {
        .init(key: key, size: size, lastModified: nil, storageClass: nil, isPrefix: false)
    }

    private func settle(_ vm: S3ViewModel, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if !vm.isLoading { return }
            await Task.yield()
        }
        XCTFail("Page did not finish", file: file, line: line)
    }
}

private enum PageFailure: LocalizedError {
    case failed
    var errorDescription: String? { "Mock page failed" }
}
