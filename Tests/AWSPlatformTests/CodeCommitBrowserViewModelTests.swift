import Foundation
import XCTest
@testable import AWSPlatform

@MainActor
final class CodeCommitBrowserViewModelTests: XCTestCase {
    func testConfigureIsSilentAndMissingScopeNeverRequestsContent() async {
        let probe = BrowserStateProbe(), vm = makeVM(BrowserStateProbe())
        let validVM = makeVM(probe)
        validVM.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        await validVM.waitForLoading()
        let calls = await probe.calls(); XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(validVM.commitSHA, codeCommitSHA); XCTAssertEqual(validVM.beforeSHA, browserBeforeSHA)
        vm.loadFolder(); vm.loadDifferences(); vm.loadPullRequests(); vm.loadPullRequest("1")
        await vm.waitForLoading()
        XCTAssertTrue(vm.loading.isEmpty); XCTAssertNil(vm.folder)
    }

    func testFolderAndFileLoadOnlyOnRequestAndLinkDoesNotExecute() async {
        let probe = BrowserStateProbe(), vm = makeVM(BrowserStateProbe())
        let subject = makeVM(probe)
        subject.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        subject.loadFolder(); await subject.waitForLoading()
        XCTAssertEqual(subject.folder?.path, "/"); XCTAssertNil(subject.file)
        let entry = try! XCTUnwrap(subject.folder?.entries.first)
        subject.openEntry(entry); await subject.waitForLoading()
        XCTAssertEqual(subject.file?.blobID, browserBlobID)
        let calls = await probe.calls(); XCTAssertEqual(calls, ["folder:/", "file:/main.swift"])
        vm.openEntry(entry); await vm.waitForLoading(); XCTAssertNil(vm.file)
    }

    func testCommitAndPathEditsClearOldContentAndInvalidateLateFolderResponse() async {
        let gate = CodeCommitRequestGate(), probe = BrowserStateProbe(gate: gate, gatedOperation: "folder")
        let vm = makeVM(probe)
        vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        vm.loadFolder(); await gate.waitForEntry()
        vm.folderPath = "/new"
        await gate.open(); await probe.waitForFinish(); await Task.yield()
        XCTAssertNil(vm.folder); XCTAssertNil(vm.file); XCTAssertTrue(vm.loading.isEmpty)
        vm.commitSHA = browserBeforeSHA
        XCTAssertTrue(vm.differences.isEmpty); XCTAssertNil(vm.selectedChange)
    }

    func testScopeRepositoryAndCommitChangesDiscardLateSuccessAndFailure() async {
        for fail in [false, true] {
            for variation in 0..<3 {
                let gate = CodeCommitRequestGate(), probe = BrowserStateProbe(gate: gate, gatedOperation: "folder", fail: fail)
                let vm = makeVM(probe)
                vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
                vm.loadFolder(); await gate.waitForEntry()
                if variation == 0 { vm.configure(scope: codeCommitScope(profile: "other"), repository: browserRepository, commit: browserCommit()) }
                else if variation == 1 { vm.configure(scope: codeCommitScope(), repository: .init(id: "99999999-1111-2222-3333-444444444444", name: "other"), commit: browserCommit()) }
                else { vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit(browserBeforeSHA)) }
                await gate.open(); await probe.waitForFinish(); await Task.yield()
                XCTAssertNil(vm.folder); XCTAssertNil(vm.errors[.folder]); XCTAssertTrue(vm.loading.isEmpty)
            }
        }
    }

    func testResetAndCancelDiscardLateResultsAndDoNotAutoReload() async {
        for reset in [false, true] {
            let gate = CodeCommitRequestGate(), probe = BrowserStateProbe(gate: gate, gatedOperation: "folder")
            let vm = makeVM(probe)
            vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
            vm.loadFolder(); await gate.waitForEntry()
            if reset { vm.reset() } else { vm.cancel() }
            await gate.open(); await probe.waitForFinish(); await Task.yield()
            XCTAssertNil(vm.folder); XCTAssertTrue(vm.errors.isEmpty); XCTAssertTrue(vm.loading.isEmpty)
            XCTAssertEqual(vm.scope == nil, reset)
            let calls = await probe.calls(); XCTAssertEqual(calls.count, 1)
        }
    }

    func testDifferencesAndBeforeAfterPreviewsUseFixedSHAsAndSelectedBlob() async throws {
        let probe = BrowserStateProbe(), vm = makeVM(BrowserStateProbe())
        let subject = makeVM(probe)
        subject.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        subject.loadDifferences(); await subject.waitForLoading()
        XCTAssertEqual(subject.differences.count, 1); XCTAssertNil(subject.selectedChange)
        subject.selectChange(try XCTUnwrap(subject.differences.first))
        subject.loadChangeFile(before: true); await subject.waitForLoading()
        XCTAssertEqual(subject.changeFile?.commitID, browserBeforeSHA)
        XCTAssertEqual(subject.changeFile?.blobID, browserBeforeSHA)
        subject.loadChangeFile(before: false); await subject.waitForLoading()
        XCTAssertEqual(subject.changeFile?.commitID, codeCommitSHA)
        XCTAssertEqual(subject.changeFile?.blobID, browserBlobID)
        vm.selectChange(try XCTUnwrap(subject.differences.first)); XCTAssertNil(vm.selectedChange)
        subject.beforeSHA = ""; XCTAssertTrue(subject.differences.isEmpty); XCTAssertNil(subject.changeFile)
    }

    func testChangingDiffSelectionInvalidatesLateContent() async throws {
        let gate = CodeCommitRequestGate(), probe = BrowserStateProbe(gate: gate, gatedOperation: "file")
        let vm = makeVM(probe)
        vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        vm.loadDifferences(); await vm.waitForLoading()
        let change = try XCTUnwrap(vm.differences.first)
        vm.selectChange(change); vm.loadChangeFile(before: false); await gate.waitForEntry()
        vm.selectChange(change)
        await gate.open(); await probe.waitForFinish(); await Task.yield()
        XCTAssertNil(vm.changeFile); XCTAssertNil(vm.errors[.changeFile])
    }

    func testInvalidCommitAndPathFailWithoutCallingInjectedLoaders() async {
        let probe = BrowserStateProbe(), vm = makeVM(probe)
        vm.configure(scope: codeCommitScope(), repository: browserRepository)
        vm.commitSHA = "HEAD"; vm.loadFolder(); vm.loadDifferences()
        vm.commitSHA = codeCommitSHA; vm.folderPath = "/../bad"; vm.loadFolder()
        await vm.waitForLoading()
        let calls = await probe.calls(); XCTAssertTrue(calls.isEmpty)
        XCTAssertNotNil(vm.errors[.folder])
    }

    func testPullRequestsLoadDetailsOnlyOnClickAndFilterClearsOldSelection() async {
        let probe = BrowserStateProbe(), vm = makeVM(probe)
        vm.configure(scope: codeCommitScope(), repository: browserRepository)
        vm.loadPullRequests(); await vm.waitForLoading()
        XCTAssertEqual(vm.pullRequestIDs, ["1"]); XCTAssertNil(vm.pullRequest)
        vm.loadPullRequest("other"); await vm.waitForLoading()
        vm.loadPullRequest("1"); await vm.waitForLoading()
        XCTAssertEqual(vm.pullRequest?.id, "1")
        vm.pullRequestStatus = "CLOSED"
        XCTAssertTrue(vm.pullRequestIDs.isEmpty); XCTAssertNil(vm.pullRequest)
        let calls = await probe.calls(); XCTAssertEqual(calls, ["prs:OPEN", "pr:1"])
    }

    func testPullRequestFilterChangeRejectsLateSuccessAndFailure() async {
        for fail in [false, true] {
            let gate = CodeCommitRequestGate(), probe = BrowserStateProbe(gate: gate, gatedOperation: "prs", fail: fail)
            let vm = makeVM(probe)
            vm.configure(scope: codeCommitScope(), repository: browserRepository)
            vm.loadPullRequests(); await gate.waitForEntry()
            vm.pullRequestStatus = "CLOSED"
            await gate.open(); await probe.waitForFinish(); await Task.yield()
            XCTAssertTrue(vm.pullRequestIDs.isEmpty); XCTAssertNil(vm.errors[.pullRequests])
        }
    }

    func testIndependentFailuresDoNotClearSuccessfulContentAndRawErrorsStayHidden() async {
        let probe = BrowserStateProbe(gatedOperation: "prs", fail: true), vm = makeVM(probe)
        vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        vm.loadFolder(); vm.loadPullRequests(); await vm.waitForLoading()
        XCTAssertNotNil(vm.folder); XCTAssertEqual(vm.errors[.pullRequests], CodeCommitBrowserError.permission.localizedDescription)
        XCTAssertFalse(vm.errors.values.contains { $0.contains("private-codecommit-token") })
    }

    func testSameConfigurationPreservesLoadedDataAndManualCommitDraft() async {
        let vm = makeVM(BrowserStateProbe())
        vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        vm.commitSHA = browserBeforeSHA; vm.loadFolder(); await vm.waitForLoading()
        vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        XCTAssertEqual(vm.commitSHA, browserBeforeSHA); XCTAssertNotNil(vm.folder)
    }

    func testUnicodeEquivalentFolderDraftChangeCancelsLateResponse() async {
        let gate = CodeCommitRequestGate(), probe = BrowserStateProbe(gate: gate, gatedOperation: "folder")
        let vm = makeVM(probe)
        vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        vm.folderPath = "/caf\u{e9}"; vm.loadFolder(); await gate.waitForEntry()
        let waiting = Task { await vm.waitForLoading() }
        await Task.yield()
        vm.folderPath = "/cafe\u{301}"
        XCTAssertTrue(vm.loading.isEmpty)
        await gate.open(); await waiting.value
        XCTAssertNil(vm.folder); XCTAssertNil(vm.errors[.folder])
    }

    func testUnicodeEquivalentEntriesAndChangesHaveExactMembershipAndSelection() async throws {
        let paths = ["/caf\u{e9}", "/cafe\u{301}"]
        let entries = paths.map { CodeCommitTreeEntry(path: $0, kind: .file, objectID: browserBlobID) }
        let changes = paths.map { CodeCommitFileChange(type: "A", before: nil, after: .init(id: browserBlobID, path: $0, mode: "100644")) }
        let vm = pathVM(entries: entries, changes: changes)
        vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        vm.loadFolder(); vm.loadDifferences(); await vm.waitForLoading()
        XCTAssertEqual(vm.folder?.entries.count, 2); XCTAssertEqual(vm.differences.count, 2)
        for index in paths.indices {
            vm.openEntry(entries[index]); await vm.waitForLoading()
            XCTAssertEqual(vm.file.map { Data($0.path.utf8) }, Data(paths[index].utf8))
            vm.selectChange(changes[index]); vm.loadChangeFile(before: false); await vm.waitForLoading()
            XCTAssertEqual(vm.selectedChange?.id, changes[index].id)
            XCTAssertEqual(vm.changeFile.map { Data($0.path.utf8) }, Data(paths[index].utf8))
        }
        let single = pathVM(entries: [entries[0]], changes: [changes[0]])
        single.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        single.loadFolder(); single.loadDifferences(); await single.waitForLoading()
        single.openEntry(entries[1]); single.selectChange(changes[1]); await single.waitForLoading()
        XCTAssertNil(single.file); XCTAssertNil(single.selectedChange)
    }

    func testUnicodeEquivalentWrongInjectedFolderAndFileResponsesAreRejected() async throws {
        let requested = "/caf\u{e9}", other = "/cafe\u{301}"
        let entry = CodeCommitTreeEntry(path: requested, kind: .file, objectID: browserBlobID)
        let change = CodeCommitFileChange(type: "A", before: nil, after: .init(id: browserBlobID, path: requested, mode: "100644"))
        let vm = pathVM(entries: [entry], changes: [change], returnedFilePath: other)
        vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        vm.loadFolder(); vm.loadDifferences(); await vm.waitForLoading()
        vm.openEntry(entry); vm.selectChange(change); vm.loadChangeFile(before: false); await vm.waitForLoading()
        XCTAssertNil(vm.file); XCTAssertNil(vm.changeFile)
        XCTAssertEqual(vm.errors[.file], CodeCommitBrowserError.invalidResponse.localizedDescription)
        XCTAssertEqual(vm.errors[.changeFile], CodeCommitBrowserError.invalidResponse.localizedDescription)
        let folderVM = pathVM(entries: [], changes: [], returnedFolderPath: other)
        folderVM.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        folderVM.folderPath = requested; folderVM.loadFolder(); await folderVM.waitForLoading()
        XCTAssertNil(folderVM.folder)
        XCTAssertEqual(folderVM.errors[.folder], CodeCommitBrowserError.invalidResponse.localizedDescription)
    }

    func testSwitchingUnicodeEquivalentFileSelectionInvalidatesOldRequest() async throws {
        let paths = ["/caf\u{e9}", "/cafe\u{301}"]
        let entries = paths.map { CodeCommitTreeEntry(path: $0, kind: .file, objectID: browserBlobID) }
        let gate = CodeCommitRequestGate()
        let vm = CodeCommitBrowserViewModel(
            folderLoader: { _, _, sha, path in .init(commitID: sha, path: path, entries: entries) },
            fileLoader: { _, _, sha, path, blob in
                if CodeCommitPath.matches(path, paths[0]) { await gate.enter() }
                return browserPreview(commit: sha, path: path, blob: blob ?? browserBlobID)
            }, differencesLoader: { _, _, _, _ in [] }, pullRequestsLoader: { _, _, _ in [] },
            pullRequestLoader: { _, _, _ in throw CodeCommitBrowserError.failed })
        vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        vm.loadFolder(); await vm.waitForLoading()
        vm.openEntry(entries[0]); await gate.waitForEntry()
        let oldRequest = Task { await vm.waitForLoading() }; await Task.yield()
        vm.openEntry(entries[1]); await vm.waitForLoading()
        XCTAssertEqual(vm.file.map { Data($0.path.utf8) }, Data(paths[1].utf8))
        await gate.open(); await oldRequest.value
        XCTAssertEqual(vm.file.map { Data($0.path.utf8) }, Data(paths[1].utf8))
    }

    private func pathVM(entries: [CodeCommitTreeEntry], changes: [CodeCommitFileChange],
                        returnedFolderPath: String? = nil, returnedFilePath: String? = nil) -> CodeCommitBrowserViewModel {
        .init(folderLoader: { _, _, sha, path in .init(commitID: sha, path: returnedFolderPath ?? path, entries: entries) },
              fileLoader: { _, _, sha, path, blob in browserPreview(commit: sha, path: returnedFilePath ?? path, blob: blob ?? browserBlobID) },
              differencesLoader: { _, _, _, _ in changes }, pullRequestsLoader: { _, _, _ in [] },
              pullRequestLoader: { _, _, _ in throw CodeCommitBrowserError.failed })
    }

    private func makeVM(_ probe: BrowserStateProbe) -> CodeCommitBrowserViewModel {
        .init(folderLoader: { _, _, sha, path in try await probe.folder(sha, path) },
              fileLoader: { _, _, sha, path, blob in try await probe.file(sha, path, blob) },
              differencesLoader: { _, _, _, _ in try await probe.differences() },
              pullRequestsLoader: { _, _, status in try await probe.pullRequests(status) },
              pullRequestLoader: { _, _, id in try await probe.pullRequest(id) })
    }
}

private actor BrowserStateProbe {
    let gate: CodeCommitRequestGate?
    let gatedOperation: String?
    let fail: Bool
    private var values: [String] = []
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(gate: CodeCommitRequestGate? = nil, gatedOperation: String? = nil, fail: Bool = false) {
        self.gate = gate; self.gatedOperation = gatedOperation; self.fail = fail
    }
    func calls() -> [String] { values }
    func waitForFinish() async { if !finished { await withCheckedContinuation { waiters.append($0) } } }
    private func check(_ operation: String, _ value: String) async throws {
        values.append("\(operation):\(value)")
        if operation == gatedOperation {
            await gate?.enter()
            finished = true; waiters.forEach { $0.resume() }; waiters.removeAll()
            if fail { throw CodeCommitFixtureError("AccessDeniedException") }
        }
    }
    func folder(_ sha: String, _ path: String) async throws -> CodeCommitFolder {
        try await check("folder", path)
        return .init(commitID: sha, path: path, entries: [.init(path: "/main.swift", kind: .file, objectID: browserBlobID)])
    }
    func file(_ sha: String, _ path: String, _ blob: String?) async throws -> CodeCommitFilePreview {
        try await check("file", path); return browserPreview(commit: sha, path: path, blob: blob ?? browserBlobID)
    }
    func differences() async throws -> [CodeCommitFileChange] {
        try await check("diff", "")
        return [.init(type: "M", before: .init(id: browserBeforeSHA, path: "/main.swift", mode: "100644"),
                      after: .init(id: browserBlobID, path: "/main.swift", mode: "100644"))]
    }
    func pullRequests(_ status: String?) async throws -> [String] { try await check("prs", status ?? "all"); return ["1"] }
    func pullRequest(_ id: String) async throws -> CodeCommitPullRequest {
        try await check("pr", id)
        return .init(id: id, title: "Fixture", description: nil, status: "OPEN", authorARN: nil, createdAt: nil,
                     updatedAt: nil, sourceReference: nil, destinationReference: nil, sourceCommit: nil, destinationCommit: nil)
    }
}
