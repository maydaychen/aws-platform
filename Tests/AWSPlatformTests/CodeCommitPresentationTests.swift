import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class CodeCommitPresentationTests: XCTestCase {
    func testLongRepositoryAndBranchFitNarrowDetailInBothLanguages() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let name = String(repeating: "project-service-", count: 6)
        let repository = CodeCommitRepository(id: "12345678-1234-1234-1234-123456789abc", name: name)
        let branch = "feature/" + String(repeating: "long-branch-", count: 18)
        let vm = CodeCommitViewModel(listLoader: { _ in [repository] }, repositoryLoader: { scope, _ in
            CodeCommitRepositoryDetail(id: repository.id, name: name,
                arn: "arn:aws:codecommit:us-east-1:\(scope.accountID):\(name)", accountID: scope.accountID,
                description: "Repository description 仓库说明 " + String(repeating: "long-text ", count: 12),
                defaultBranch: branch, cloneURLHTTP: "https://git-codecommit.us-east-1.amazonaws.com/v1/repos/\(name)",
                cloneURLSSH: "ssh://git-codecommit.us-east-1.amazonaws.com/v1/repos/\(name)",
                creationDate: Date(timeIntervalSince1970: 1_700_000_000), lastModifiedDate: nil)
        }, branchesLoader: { _, _ in [branch] }, commitLoader: { _, _, _ in
            CodeCommitCommit(id: String(repeating: "a", count: 40),
                message: "Support long commit messages 支持长提交说明\n" + String(repeating: "Details. ", count: 30),
                authorName: "Example author", authorEmail: "author@example.invalid", authorDate: "1700000000 +0800",
                committerName: nil, committerEmail: nil, committerDate: nil, parentIDs: [String(repeating: "b", count: 40)])
        })
        vm.configure(scope: scope())
        vm.loadIfNeeded()
        await vm.waitForLoading()
        vm.selectedRepository = repository
        await vm.waitForDetails()
        XCTAssertEqual(vm.selectedBranch, branch)
        XCTAssertNotNil(vm.commit)
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark)] {
            try snapshot(CodeCommitRepositoryDetailView(vm: vm), name: "detail-\(language)",
                         width: 480, height: 1100, language: language, scheme: scheme)
            try snapshot(CodeCommitRepositoryDetailView(vm: vm), name: "branches-\(language)",
                         width: 480, height: 1100, language: language, scheme: scheme, scrollToBottom: true)
            try snapshot(CodeCommitCommitView(commit: vm.commit, isLoading: false, error: nil, onRefresh: {})
                .padding(16), name: "commit-\(language)",
                         width: 480, height: 900, language: language, scheme: scheme)
            try snapshot(CodeCommitRepositoryListView(vm: vm), name: "list-\(language)",
                         width: 280, height: 500, language: language, scheme: scheme)
        }
    }

    func testEmptyAndPermissionFailureStatesFitNarrowDetail() async throws {
        let repository = CodeCommitRepository(id: "12345678-1234-1234-1234-123456789abc", name: "empty-repository")
        let vm = CodeCommitViewModel(listLoader: { _ in [repository] }, repositoryLoader: { _, _ in
            throw AWSCodeCommitService.RequestError.repositoryPermission
        }, branchesLoader: { _, _ in [] }, commitLoader: { _, _, _ in
            XCTFail("An empty repository must not request a commit")
            throw CodeCommitError.invalidResponse
        })
        vm.configure(scope: scope())
        vm.loadIfNeeded()
        await vm.waitForLoading()
        vm.selectedRepository = repository
        await vm.waitForDetails()
        XCTAssertNotNil(vm.repositoryError)
        XCTAssertNil(vm.branchesError)
        XCTAssertNil(vm.selectedBranch)
        try snapshot(CodeCommitRepositoryDetailView(vm: vm), name: "partial-error-zh-Hans",
                     width: 480, height: 650, language: "zh-Hans", scheme: .dark)
    }

    private func scope() -> MonitoringScope {
        let profile = AWSProfile(name: "mock", region: "us-east-1", ssoStartURL: nil,
                                 ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        return providerTestScope(profile, paths: AWSConfigurationPaths(environment: [:]))
    }

    private func snapshot<Content: View>(_ content: Content, name: String, width: CGFloat, height: CGFloat,
                                        language: String, scheme: ColorScheme, scrollToBottom: Bool = false) throws {
        let root = content.frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.orderBack(nil)
        defer { window.close() }
        settleLayout(view, window: window)
        if scrollToBottom {
            let scroll = try XCTUnwrap(descendants(view).first { $0 is NSScrollView } as? NSScrollView)
            let document = try XCTUnwrap(scroll.documentView)
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            settleLayout(view, window: window)
        }
        XCTAssertLessThanOrEqual(view.fittingSize.width, width, "Long identifiers must not enlarge the pane")
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 1, accuracy: 0.01,
                       "Screenshots need an opaque window background to make text contrast inspectable")
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/codecommit-query/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(name).png"))
    }

    private func settleLayout(_ view: NSView, window: NSWindow) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        view.displayIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
