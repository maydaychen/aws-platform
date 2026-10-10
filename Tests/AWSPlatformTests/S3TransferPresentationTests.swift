import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class S3TransferPresentationTests: XCTestCase {
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

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
