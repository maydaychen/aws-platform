import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class S3TransferPresentationTests: XCTestCase {
    func testRecoveryPathWrapsAtNarrowWidthInBothLanguages() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = S3TransferFixtures.context()
        let recovery = URL(fileURLWithPath: "/Volumes/Shared/" + String(repeating: "long-folder-中文/", count: 12)
            + "AWSPlatform Recovery 00000000-0000-0000-0000-000000000000")
        let vm = S3TransferViewModel(uploader: { _, _ in },
            downloader: { _, _, _, _ in .init(recoveryURL: recovery) }, activity: TransferActivity())
        vm.configure(scope: context.scope)
        let object = S3ObjectModel(key: "document.txt", size: 0, lastModified: nil, storageClass: nil, isPrefix: false)
        vm.chooseDownload(context: context, object: object) { directory.appendingPathComponent("download.txt") }
        for _ in 0..<1_000 {
            if vm.completedDownload != nil { break }
            await Task.yield()
        }
        XCTAssertEqual(vm.completedDownload?.recoveryURL, recovery)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/audit-fixes/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark)] {
            let root = S3TransferStatusView(vm: vm).frame(width: 280)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 280, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.orderBack(nil)
            defer { window.close() }
            settleLayout(view)
            XCTAssertLessThanOrEqual(view.fittingSize.width, 280)
            XCTAssertGreaterThan(view.fittingSize.height, 50, "The full path must wrap instead of truncating")
            XCTAssertLessThan(view.fittingSize.height, 300)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("download-recovery-\(language).png"))
        }
    }

    func testConfirmationWithLongKeyKeepsActionsOutsideScrollableDetailsInBothLanguages() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let context = S3TransferFixtures.context(profileName: "production-long-profile-name-for-review")
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark)] {
            for overwrite in [false, true] {
                var intent = S3UploadIntent(context: context, file: file,
                    key: "folder/" + String(repeating: "long-object-name-", count: 50) + "file.txt")
                if overwrite { intent.overwriteETag = "etag" }
                let root = S3UploadConfirmationView(intent: intent, onCancel: {}, onConfirm: {})
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
                let view = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 520, height: 530),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.orderBack(nil)
                defer { window.close() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                view.layoutSubtreeIfNeeded()
                XCTAssertLessThan(view.fittingSize.height, 600, "Long keys must not enlarge the modal beyond the window")
                let scroll = try XCTUnwrap(descendants(view).first { $0 is NSScrollView } as? NSScrollView)
                XCTAssertLessThanOrEqual(scroll.frame.height, WorkspaceLayout.s3ConfirmationDetailsHeight)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".tmp/s3-transfer/screenshots", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent("\(language)-\(overwrite ? "overwrite" : "upload").png"))
            }
        }
    }

    private func settleLayout(_ view: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
