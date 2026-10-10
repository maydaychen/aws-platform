import Foundation
import XCTest
@testable import AWSPlatform

@MainActor
final class S3UploadDropTests: XCTestCase {
    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Drop state was not reached", file: file, line: line)
    }

    func testDropRequiresSelectedProfileSingleFileAndIdleWindow() async throws {
        let vm = S3TransferViewModel(uploader: { _, _ in XCTFail("No write") }, downloader: { _, _, _, _ in })
        let context = S3TransferFixtures.context()
        XCTAssertFalse(vm.receiveUploadDrop(context: context, numberOfFiles: 1) { XCTFail("No Profile"); return URL(fileURLWithPath: "/tmp/file") })
        vm.configure(scope: S3TransferFixtures.context(profileName: "other").scope)
        XCTAssertFalse(vm.receiveUploadDrop(context: context, numberOfFiles: 1) { XCTFail("Wrong Profile"); return URL(fileURLWithPath: "/tmp/file") })
        vm.configure(scope: context.scope)
        XCTAssertFalse(vm.receiveUploadDrop(context: context, numberOfFiles: 0) { XCTFail("No file"); return URL(fileURLWithPath: "/tmp/file") })
        XCTAssertFalse(vm.receiveUploadDrop(context: context, numberOfFiles: 2) { XCTFail("Multiple files"); return URL(fileURLWithPath: "/tmp/file") })
        XCTAssertEqual(vm.error, S3TransferError.multipleFiles.errorDescription)
        let gate = TestGate()
        XCTAssertTrue(vm.receiveUploadDrop(context: context, numberOfFiles: 1) { await gate.wait(); return URL(fileURLWithPath: "/tmp/file") })
        await gate.waitForEntry()
        XCTAssertFalse(vm.receiveUploadDrop(context: context, numberOfFiles: 1) { XCTFail("Already loading"); return URL(fileURLWithPath: "/tmp/file") })
        vm.cancel()
        await gate.open()
    }

    func testDropUsesCapturedCurrentPrefixAndDoesNotWriteBeforeConfirmation() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let original = S3TransferFixtures.context()
        let context = S3TransferContext(scope: original.scope, bucket: original.bucket, prefix: "nested/current/", knownRegion: original.knownRegion)
        let uploaded = expectation(description: "confirmed upload")
        let vm = S3TransferViewModel(uploader: { intent, _ in
            XCTAssertEqual(intent.context, context)
            XCTAssertEqual(intent.key, "nested/current/file.txt")
            XCTAssertNil(intent.overwriteETag)
            uploaded.fulfill()
        }, downloader: { _, _, _, _ in })
        vm.configure(scope: context.scope)
        XCTAssertTrue(vm.receiveUploadDrop(context: context, numberOfFiles: 1) { file.url })
        await waitFor { vm.pendingUpload != nil }
        let intent = try XCTUnwrap(vm.pendingUpload)
        XCTAssertNil(vm.refreshID)
        XCTAssertEqual(intent.key, "nested/current/file.txt")
        XCTAssertFalse(vm.receiveUploadDrop(context: context, numberOfFiles: 1) { XCTFail("Confirmation open"); return file.url })
        vm.confirmUpload(intent)
        await fulfillment(of: [uploaded], timeout: 1)
        await waitFor { vm.status == "Upload complete" }
        XCTAssertEqual(vm.completedContext, context)
    }

    func testProfilePrefixChangeAndCancellationInvalidateLateDropResolution() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let context = S3TransferFixtures.context()
        for operation in [0, 1, 2] {
            let gate = TestGate()
            let vm = S3TransferViewModel(uploader: { _, _ in XCTFail("Stale drop must not upload") }, downloader: { _, _, _, _ in })
            vm.configure(scope: context.scope)
            XCTAssertTrue(vm.receiveUploadDrop(context: context, numberOfFiles: 1) { await gate.wait(); return file.url })
            await gate.waitForEntry()
            switch operation {
            case 0: vm.configure(scope: S3TransferFixtures.context(profileName: "new").scope)
            case 1: vm.leaveBrowser()
            default: vm.cancel()
            }
            await gate.open()
            for _ in 0..<20 { await Task.yield() }
            XCTAssertNil(vm.pendingUpload)
            XCTAssertNil(vm.error)
            XCTAssertNil(vm.refreshID)
            XCTAssertFalse(vm.isBusy)
        }
    }

    func testFoldersNonlocalFilesAndProviderFailuresLeaveRetryAvailable() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = S3TransferFixtures.context()
        for url in [directory, try XCTUnwrap(URL(string: "https://example.com/file.txt"))] {
            let vm = S3TransferViewModel(uploader: { _, _ in XCTFail("Invalid file must not upload") }, downloader: { _, _, _, _ in })
            vm.configure(scope: context.scope)
            XCTAssertTrue(vm.receiveUploadDrop(context: context, numberOfFiles: 1) { url })
            await waitFor { vm.error != nil }
            XCTAssertEqual(vm.error, S3TransferError.invalidFile.errorDescription)
            XCTAssertNil(vm.pendingUpload)
            XCTAssertTrue(vm.canStart)
        }
        let vm = S3TransferViewModel(uploader: { _, _ in }, downloader: { _, _, _, _ in })
        vm.configure(scope: context.scope)
        XCTAssertTrue(vm.receiveUploadDrop(context: context, numberOfFiles: 1) { throw NSError(domain: "private-provider-detail", code: 1) })
        await waitFor { vm.error != nil }
        XCTAssertEqual(vm.error, S3TransferError.failed.errorDescription)
        XCTAssertTrue(vm.canStart)
    }

    func testDropMessagesRenderInBothLanguages() {
        for text in ["Preparing upload", "Drop a file to upload here", "or drop a file", S3TransferError.multipleFiles.errorDescription!] {
            XCTAssertEqual(L10n.text(text, locale: Locale(identifier: "en")), text)
            XCTAssertNotEqual(L10n.text(text, locale: Locale(identifier: "zh-Hans")), text)
        }
    }
}
