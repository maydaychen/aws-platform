import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class CodeCommitBrowserLifecycleTests: XCTestCase {
    func testClearingSelectionResetsMountedDetailAndDiscardsLateFileAndPullRequestResults() async throws {
        for fail in [false, true] { try await assertMountedDetailReset(unmount: false, fail: fail) }
    }

    func testLeavingMountedDetailResetsBrowserAndDiscardsLateFileAndPullRequestResults() async throws {
        for fail in [false, true] { try await assertMountedDetailReset(unmount: true, fail: fail) }
    }

    private func assertMountedDetailReset(unmount: Bool, fail: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let vm = CodeCommitViewModel(listLoader: { _ in [browserRepository] },
            repositoryLoader: { _, _ in throw CodeCommitError.invalidResponse },
            branchesLoader: { _, _ in [] }, commitLoader: { _, _, _ in browserCommit() })
        vm.configure(scope: codeCommitScope()); vm.refresh(); await vm.waitForLoading()
        vm.selectedRepository = browserRepository; await vm.waitForDetails()
        let fileGate = CodeCommitRequestGate(), requestGate = CodeCommitRequestGate()
        let entry = CodeCommitTreeEntry(path: "/file", kind: .file, objectID: browserBlobID)
        let browser = CodeCommitBrowserViewModel(
            folderLoader: { _, _, sha, path in .init(commitID: sha, path: path, entries: [entry]) },
            fileLoader: { _, _, sha, path, blob in
                await fileGate.enter()
                if fail { throw CodeCommitBrowserError.permission }
                return browserPreview(commit: sha, path: path, blob: blob ?? browserBlobID)
            }, differencesLoader: { _, _, _, _ in [] }, pullRequestsLoader: { _, _, _ in ["1"] },
            pullRequestLoader: { _, _, id in
                await requestGate.enter()
                if fail { throw CodeCommitBrowserError.permission }
                return .init(id: id, title: "Late result", description: nil, status: "OPEN", authorARN: nil,
                    createdAt: nil, updatedAt: nil, sourceReference: nil, destinationReference: nil,
                    sourceCommit: nil, destinationCommit: nil)
            })
        let view = NSHostingView(rootView: AnyView(CodeCommitRepositoryDetailView(vm: vm, browserVM: browser)))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
        defer { window.close() }
        settle(window, view)
        XCTAssertEqual(browser.repository, browserRepository)
        browser.commitSHA = codeCommitSHA
        browser.loadFolder(); browser.loadPullRequests(); await browser.waitForLoading()
        browser.openEntry(entry); browser.loadPullRequest("1")
        await fileGate.waitForEntry(); await requestGate.waitForEntry()
        let oldRequests = Task { await browser.waitForLoading() }; await Task.yield()
        if unmount { view.rootView = AnyView(Text("Another service")) }
        else { vm.selectedRepository = nil }
        settle(window, view)
        XCTAssertNil(browser.scope); XCTAssertNil(browser.repository)
        XCTAssertNil(browser.folder); XCTAssertTrue(browser.pullRequestIDs.isEmpty)
        XCTAssertTrue(browser.loading.isEmpty)
        await fileGate.open(); await requestGate.open(); await oldRequests.value
        XCTAssertNil(browser.file); XCTAssertNil(browser.pullRequest)
        XCTAssertTrue(browser.errors.isEmpty); XCTAssertTrue(browser.completed.isEmpty)
        if !unmount {
            vm.selectedRepository = browserRepository; await vm.waitForDetails()
            settle(window, view)
            XCTAssertEqual(browser.repository, browserRepository)
            XCTAssertEqual(browser.scope, codeCommitScope())
            XCTAssertNil(browser.file); XCTAssertNil(browser.pullRequest)
        }
    }

    private func settle(_ window: NSWindow, _ view: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); view.displayIfNeeded()
    }
}
