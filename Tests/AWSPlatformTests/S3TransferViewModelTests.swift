import Foundation
import XCTest
@testable import AWSPlatform

final class S3TransferViewModelTests: XCTestCase {
    @MainActor
    func testChangingProfileDuringPreparationDropsLateSnapshotAndConfirmation() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try S3TransferFixtures.file(in: directory)
        let gate = TestGate()
        let vm = S3TransferViewModel(uploader: { _, _ in XCTFail("No unconfirmed upload") }, downloader: { _, _, _, _ in },
            filePreparer: { url in
                let file = try await S3LocalFile.prepare(url: url, temporaryRoot: directory)
                await gate.wait()
                return file
            })
        let context = S3TransferFixtures.context()
        vm.configure(scope: context.scope)
        vm.chooseUpload(context: context) { source.url }
        await gate.waitForEntry()
        XCTAssertTrue(vm.isBusy)
        XCTAssertEqual(vm.status, "Preparing upload")
        vm.configure(scope: S3TransferFixtures.context(profileName: "next").scope)
        await gate.open()
        await waitFor { (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["file.txt"] }
        XCTAssertNil(vm.pendingUpload)
        XCTAssertFalse(vm.isBusy)
        XCTAssertNil(vm.error)
    }

    @MainActor
    func testCancelledUploadMustActuallyExitBeforeRestart() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let gate = TestGate()
        let activity = TransferActivity()
        let vm = S3TransferViewModel(uploader: { _, _ in await gate.wait() }, downloader: { _, _, _, _ in }, activity: activity)
        let context = S3TransferFixtures.context()
        vm.configure(scope: context.scope)
        vm.chooseUpload(context: context) { file.url }
        await waitFor { vm.pendingUpload != nil }
        vm.confirmUpload(try XCTUnwrap(vm.pendingUpload))
        await gate.waitForEntry()
        vm.cancel()
        XCTAssertFalse(vm.isBusy)
        XCTAssertEqual(activity.activeCount, 1)
        var restarted = false
        XCTAssertTrue(activity.postponeUpdate { restarted = true })
        XCTAssertFalse(vm.canStart)
        XCTAssertFalse(restarted)
        await gate.open()
        await waitFor { restarted }
        XCTAssertEqual(activity.activeCount, 0)
        XCTAssertNil(vm.refreshID)
    }

    @MainActor
    func testProfileResetKeepsDownloadLeaseUntilServiceActuallyReturns() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TestGate()
        let activity = TransferActivity()
        let vm = S3TransferViewModel(uploader: { _, _ in }, downloader: { _, _, _, _ in await gate.wait() }, activity: activity)
        let context = S3TransferFixtures.context()
        let object = S3ObjectModel(key: "file", size: 1, lastModified: nil, storageClass: nil, isPrefix: false)
        vm.configure(scope: context.scope)
        vm.chooseDownload(context: context, object: object) { directory.appendingPathComponent("saved") }
        await gate.waitForEntry()
        vm.configure(scope: S3TransferFixtures.context(profileName: "next").scope)
        var restarted = false
        XCTAssertTrue(activity.postponeTermination { restarted = true })
        XCTAssertFalse(vm.canStart)
        XCTAssertFalse(restarted)
        await gate.open()
        await waitFor { restarted }
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.status)
    }

    @MainActor
    func testPendingRestartPreventsDownloadAfterSavePanelReturns() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TestGate()
        let activity = TransferActivity()
        let vm = S3TransferViewModel(uploader: { _, _ in }, downloader: { _, _, _, _ in XCTFail("Restart must block download") }, activity: activity)
        let context = S3TransferFixtures.context()
        let object = S3ObjectModel(key: "file", size: 1, lastModified: nil, storageClass: nil, isPrefix: false)
        vm.configure(scope: context.scope)
        vm.chooseDownload(context: context, object: object) { await gate.wait(); return directory.appendingPathComponent("saved") }
        await gate.waitForEntry()
        XCTAssertFalse(activity.postponeUpdate { XCTFail("No active transfer to postpone") })
        await gate.open()
        await waitFor { !vm.isBusy }
        XCTAssertEqual(activity.activeCount, 0)
        XCTAssertNil(vm.error)
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected transfer state was not reached", file: file, line: line)
    }

    @MainActor
    func testUnselectedOrMismatchedProfileCannotOpenFilePicker() {
        let vm = S3TransferViewModel(uploader: { _, _ in XCTFail("No upload") }, downloader: { _, _, _, _ in XCTFail("No download") })
        let context = S3TransferFixtures.context()
        XCTAssertFalse(vm.canStart)
        vm.chooseUpload(context: context) { XCTFail("No picker without Profile"); return nil }
        vm.configure(scope: S3TransferFixtures.context(profileName: "other").scope)
        vm.chooseUpload(context: context) { XCTFail("No picker for mismatched Profile"); return nil }
        XCTAssertFalse(vm.isBusy)
        XCTAssertNil(vm.pendingUpload)
    }

    @MainActor
    func testChoosingFileDoesNotWriteUntilUserConfirmsAndSuccessRequestsRefresh() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let calls = TransferCalls()
        let vm = S3TransferViewModel(uploader: { intent, progress in
            await calls.add(intent)
            await progress(.init(bytes: intent.file.size, total: intent.file.size))
        }, downloader: { _, _, _, _ in XCTFail("No download") })
        let context = S3TransferFixtures.context()
        vm.configure(scope: context.scope)
        vm.chooseUpload(context: context) { file.url }
        await waitFor { vm.pendingUpload != nil }
        let before = await calls.values
        XCTAssertTrue(before.isEmpty)
        let intent = try XCTUnwrap(vm.pendingUpload)
        XCTAssertEqual(intent.key, "folder/file.txt")
        vm.confirmUpload(intent)
        await waitFor { vm.status == "Upload complete" }
        let after = await calls.values
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(vm.completedContext, context)
        XCTAssertNotNil(vm.refreshID)
        XCTAssertEqual(vm.progress.fraction, 1)
        XCTAssertTrue(vm.canStart)
    }

    @MainActor
    func testCollisionDoesNotAutomaticallyOverwriteAndRequiresMatchingConfirmation() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let calls = TransferCalls()
        let vm = S3TransferViewModel(uploader: { intent, _ in
            await calls.add(intent)
            if intent.overwriteETag == nil { throw S3TransferError.objectExists(etag: "etag", region: "ap-southeast-1") }
        }, downloader: { _, _, _, _ in })
        let context = S3TransferFixtures.context()
        vm.configure(scope: context.scope)
        vm.chooseUpload(context: context) { file.url }
        await waitFor { vm.pendingUpload != nil }
        let initial = try XCTUnwrap(vm.pendingUpload)
        vm.confirmUpload(initial)
        await waitFor { vm.pendingUpload?.overwriteETag != nil }
        let callsBefore = await calls.values
        XCTAssertEqual(callsBefore.count, 1)
        vm.confirmUpload(initial)
        XCTAssertNotNil(vm.pendingUpload, "Old dialog must not authorize overwrite")
        let overwrite = try XCTUnwrap(vm.pendingUpload)
        vm.confirmUpload(overwrite)
        await waitFor { vm.status == "Upload complete" }
        let requests = await calls.values
        XCTAssertEqual(requests.map(\.overwriteETag), [nil, "etag"])
        XCTAssertEqual(requests.last?.resolvedRegion, "ap-southeast-1")
    }

    @MainActor
    func testProfileChangeInvalidatesLatePickerAndPendingConfirmation() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let gate = TestGate()
        let vm = S3TransferViewModel(uploader: { _, _ in XCTFail("Stale confirmation must not upload") }, downloader: { _, _, _, _ in })
        let context = S3TransferFixtures.context()
        vm.configure(scope: context.scope)
        vm.chooseUpload(context: context) { await gate.wait(); return file.url }
        await gate.waitForEntry()
        vm.configure(scope: S3TransferFixtures.context(profileName: "new").scope)
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(vm.pendingUpload)
        XCTAssertNil(vm.error)
        vm.configure(scope: context.scope)
        vm.chooseUpload(context: context) { file.url }
        await waitFor { vm.pendingUpload != nil }
        let old = try XCTUnwrap(vm.pendingUpload)
        vm.reset()
        vm.confirmUpload(old)
        XCTAssertNil(vm.pendingUpload)
        XCTAssertFalse(vm.isBusy)
        XCTAssertFalse(vm.canStart)
    }

    @MainActor
    func testCancelledUploadRejectsLateProgressAndSuccess() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let gate = TestGate()
        let finished = expectation(description: "late upload returned")
        let vm = S3TransferViewModel(uploader: { _, progress in
            await gate.wait()
            await progress(.init(bytes: 99, total: 99))
            finished.fulfill()
        }, downloader: { _, _, _, _ in })
        let context = S3TransferFixtures.context()
        vm.configure(scope: context.scope)
        vm.chooseUpload(context: context) { file.url }
        await waitFor { vm.pendingUpload != nil }
        vm.confirmUpload(try XCTUnwrap(vm.pendingUpload))
        await gate.waitForEntry()
        vm.cancel()
        await gate.open()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertFalse(vm.isBusy)
        XCTAssertNil(vm.refreshID)
        XCTAssertEqual(vm.progress.bytes, 0)
        XCTAssertTrue(vm.status?.contains("may already") == true)
    }

    @MainActor
    func testPrefixNavigationInvalidatesDownloadPanelAndFoldersCannotDownload() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TestGate()
        let vm = S3TransferViewModel(uploader: { _, _ in }, downloader: { _, _, _, _ in XCTFail("Stale panel must not download") })
        let context = S3TransferFixtures.context()
        let object = S3ObjectModel(key: "file", size: 1, lastModified: nil, storageClass: nil, isPrefix: false)
        vm.configure(scope: context.scope)
        vm.chooseDownload(context: context, object: object) { await gate.wait(); return directory.appendingPathComponent("saved") }
        await gate.waitForEntry()
        vm.leaveBrowser()
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.status)
        XCTAssertTrue(vm.canStart)
        let folder = S3ObjectModel(key: "folder/", size: nil, lastModified: nil, storageClass: nil, isPrefix: true)
        vm.chooseDownload(context: context, object: folder) { XCTFail("No folder download"); return nil }
        XCTAssertFalse(vm.isBusy)
    }

    @MainActor
    func testFailedTransferLeavesRetryAvailableAndDoesNotRequestRefresh() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let vm = S3TransferViewModel(uploader: { _, _ in throw S3TransferError.accessDenied }, downloader: { _, _, _, _ in })
        let context = S3TransferFixtures.context()
        vm.configure(scope: context.scope)
        vm.chooseUpload(context: context) { file.url }
        await waitFor { vm.pendingUpload != nil }
        vm.confirmUpload(try XCTUnwrap(vm.pendingUpload))
        await waitFor { vm.error != nil }
        XCTAssertEqual(vm.error, S3TransferError.accessDenied.errorDescription)
        XCTAssertNil(vm.refreshID)
        XCTAssertTrue(vm.canStart)
    }
}

private actor TransferCalls {
    private(set) var values: [S3UploadIntent] = []
    func add(_ intent: S3UploadIntent) { values.append(intent) }
}
