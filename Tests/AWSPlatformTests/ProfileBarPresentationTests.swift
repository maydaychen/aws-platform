import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class ProfileBarPresentationTests: XCTestCase {
    func testHeaderUsesWindowWidthAndWrapsWithoutSelectingProfile() throws {
        let suite = "ProfileBarPresentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in
            XCTFail("Resizing must not validate or query AWS")
            throw HealthError.invalidScope
        }, ssoLogin: { _, _ in XCTFail("Resizing must not sign in") })
        let session = "company-production-sso-session"
        vm.loadProfiles([
            AWSProfile(name: "production-platform-readonly-profile", region: "us-east-1", ssoStartURL: nil,
                       ssoRegion: nil, ssoAccountID: "111122223333", ssoRoleName: "ReadOnlyAccess", ssoSessionName: session)
        ], sessions: [AWSSOSession(name: session)])
        vm.selectSource(.session(session))
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", .dark)] {
            for width in [960.0, 1440.0, 2200.0] {
                try render(vm, language: language, scheme: scheme, width: width, showsRegion: true)
            }
            try render(vm, language: language, scheme: scheme, width: 960, showsRegion: false)
        }
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertEqual(vm.selectedSession?.id, session)
        XCTAssertEqual(vm.profileStatus, .idle)
        vm.selectProfile(id: "production-platform-readonly-profile")
        try render(vm, language: "zh-Hans", scheme: .dark, width: 960, showsRegion: true)
        try render(vm, language: "zh-Hans", scheme: .dark, width: 2200, showsRegion: true)
        XCTAssertEqual(vm.selectedProfileID, "production-platform-readonly-profile")
    }

    private func render(_ vm: ProfileViewModel, language: String, scheme: ColorScheme, width: Double, showsRegion: Bool) throws {
        let root = ProfileBarView(vm: vm, onRetry: {}, showsResourceRegion: showsRegion)
            .frame(width: width, height: 140, alignment: .topLeading)
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor))
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 140),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        let controls = descendants(view).filter { String(describing: type(of: $0)) == "KeyViewProxy" || $0 is NSPopUpButton }
        let frames = controls.map { $0.convert($0.bounds, to: view) }.filter { $0.width > 0 && $0.height > 0 }
        print("HEADER \(language) \(Int(width)) region=\(showsRegion): \(frames)")
        XCTAssertGreaterThanOrEqual(frames.count, 4)
        if frames.count >= 4 {
            XCTAssertLessThan(frames[0].minX, 80, "The Session control must stay beside its label")
            XCTAssertGreaterThanOrEqual(frames[2].width, width - 900, "Profile must absorb the extra width")
            XCTAssertGreaterThan(frames.map(\.maxX).max() ?? 0, width - 24, "Connection actions must stay at the trailing edge")
        }
        if vm.selectedProfileID != nil && showsRegion {
            let region = try XCTUnwrap(frames.first { abs($0.width - 260) < 1 })
            if width == 960 {
                XCTAssertGreaterThan(region.minY, frames[0].maxY, "Region must wrap below the first row")
            } else {
                XCTAssertEqual(region.minY, frames[0].minY, accuracy: 1, "Wide windows must keep a single control row")
            }
        }
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, width)
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/sso-fluid-header/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let selection = vm.selectedProfileID == nil ? "empty" : "selected"
        try png.write(to: output.appendingPathComponent("\(language)-\(Int(width))-\(showsRegion ? "regional" : "global")-\(selection).png"))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
