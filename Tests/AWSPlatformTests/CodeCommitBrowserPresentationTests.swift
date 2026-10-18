import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class CodeCommitBrowserPresentationTests: XCTestCase {
    func testSourceAndDiffPreviewRenderLiteralContentInNarrowPaneInBothLanguages() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let file = browserPreview(preview: .text("<script>alert('literal')</script>\n" + String(repeating: "long source content ", count: 40)))
        let entry = CodeCommitTreeEntry(path: file.path, kind: .file, objectID: file.blobID)
        let change = CodeCommitFileChange(type: "M", before: .init(id: browserBeforeSHA, path: file.path, mode: "100644"),
                                         after: .init(id: browserBlobID, path: file.path, mode: "100644"))
        let vm = CodeCommitBrowserViewModel(folderLoader: { _, _, sha, path in .init(commitID: sha, path: path, entries: [entry]) },
            fileLoader: { _, _, _, _, _ in file }, differencesLoader: { _, _, _, _ in [change] },
            pullRequestsLoader: { _, _, _ in [] }, pullRequestLoader: { _, _, _ in throw CodeCommitBrowserError.failed })
        vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        vm.loadFolder(); await vm.waitForLoading(); vm.openEntry(entry); await vm.waitForLoading()
        vm.loadDifferences(); await vm.waitForLoading(); vm.selectChange(change); vm.loadChangeFile(before: false); await vm.waitForLoading()
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark)] {
            try snapshot(CodeCommitBrowserView(vm: vm, section: "Source files"), name: "source-\(language)", language: language, scheme: scheme)
            try snapshot(CodeCommitBrowserView(vm: vm, section: "Commit differences"), name: "diff-\(language)", language: language, scheme: scheme)
        }
    }

    func testEmptyPermissionBinaryAndTooLargeViewsRender() async throws {
        let vm = CodeCommitBrowserViewModel(folderLoader: { _, _, _, _ in throw CodeCommitBrowserError.permission },
            fileLoader: { _, _, _, _, _ in throw CodeCommitBrowserError.failed }, differencesLoader: { _, _, _, _ in [] },
            pullRequestsLoader: { _, _, _ in [] }, pullRequestLoader: { _, _, _ in throw CodeCommitBrowserError.failed })
        vm.configure(scope: codeCommitScope(), repository: browserRepository, commit: browserCommit())
        vm.loadFolder(); vm.loadPullRequests(); await vm.waitForLoading()
        try snapshot(CodeCommitBrowserView(vm: vm, section: "Source files"), name: "permission-zh-Hans", language: "zh-Hans", scheme: .dark)
        try snapshot(CodeCommitBrowserView(vm: vm, section: "Pull requests"), name: "empty-pr-en", language: "en", scheme: .light)
        try snapshot(CodeCommitFilePreviewView(file: browserPreview(preview: .binary)).padding(16), name: "binary-en", language: "en", scheme: .light)
        try snapshot(CodeCommitFilePreviewView(file: browserPreview(preview: .tooLarge)).padding(16), name: "large-zh-Hans", language: "zh-Hans", scheme: .dark)
    }

    private func snapshot<Content: View>(_ content: Content, name: String, language: String, scheme: ColorScheme) throws {
        let width: CGFloat = 480, height: CGFloat = 900
        let root = content.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor; window.isOpaque = true; window.orderBack(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); view.displayIfNeeded()
        XCTAssertLessThanOrEqual(view.fittingSize.width, width)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/service-submodules/screenshots/codecommit", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name).png"))
    }
}
