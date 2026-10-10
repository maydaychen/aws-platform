import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class S3FileDropPresentationTests: XCTestCase {
    func testEmptyListAndDropHintRenderAtMinimumWidthInBothLanguages() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = S3TransferFixtures.context()
        let context = S3TransferContext(scope: original.scope, bucket: original.bucket,
            prefix: "nested/" + String(repeating: "long-folder-name/", count: 12), knownRegion: original.knownRegion)
        let listVM = S3ViewModel()
        listVM.currentPrefix = context.prefix
        let transferVM = S3TransferViewModel(uploader: { _, _ in XCTFail("Rendering must not upload") }, downloader: { _, _, _, _ in })
        transferVM.configure(scope: context.scope)
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark)] {
            for targeted in [false, true] {
                let root = S3ObjectListView(vm: listVM, transferVM: transferVM, bucketName: context.bucket, transferContext: context)
                    .overlay {
                        if targeted { S3UploadDropOverlay(context: context).allowsHitTesting(false) }
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
                let view = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 280, height: 480),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.orderBack(nil)
                defer { window.close() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".tmp/s3-drop/screenshots", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent("\(language)-\(targeted ? "drop" : "list").png"))
                XCTAssertEqual(view.bounds.width, 280)
                XCTAssertNil(transferVM.pendingUpload)
            }
        }
    }
}
