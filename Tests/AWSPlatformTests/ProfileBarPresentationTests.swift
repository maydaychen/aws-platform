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
        for (language, scheme) in appearances {
            for width in [800.0, 1000.0, 1440.0, 2200.0] {
                try render(vm, language: language, scheme: scheme, width: width, showsRegion: true)
            }
            try render(vm, language: language, scheme: scheme, width: 800, showsRegion: false)
        }
        XCTAssertNil(vm.selectedProfileID)
        XCTAssertEqual(vm.selectedSession?.id, session)
        XCTAssertEqual(vm.profileStatus, .idle)
        vm.selectProfile(id: "production-platform-readonly-profile")
        for (language, scheme) in appearances {
            try render(vm, language: language, scheme: scheme, width: 800, showsRegion: true)
            try render(vm, language: language, scheme: scheme, width: 2200, showsRegion: true)
        }
        XCTAssertEqual(vm.selectedProfileID, "production-platform-readonly-profile")
        XCTAssertEqual(vm.profileStatus, .idle)
    }

    func testVerifiedIdentityAndFailureRenderingDoNotRevalidate() throws {
        let suite = "ProfileBarStatus.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ProfileViewModel(defaults: defaults, profileValidator: { _, _ in
            XCTFail("Rendering status must not revalidate or query AWS")
            throw HealthError.invalidScope
        }, ssoLogin: { _, _ in XCTFail("Rendering status must not sign in") })
        vm.loadProfiles([
            AWSProfile(name: "production-readonly", region: "eu-central-1", ssoStartURL: nil,
                       ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        ])
        vm.selectSource(.other)
        vm.selectProfile(id: "production-readonly")
        let identity = AWSIdentity(account: "111122223333",
                                   arn: "arn:aws:sts::111122223333:assumed-role/AWSReservedSSO_ProductionReadOnlyAccess_0123456789abcdef/user-session",
                                   userID: "offline-preview")
        for status in [ProfileStatus.checking, .valid(identity), .failed("The selected Profile could not be verified.")] {
            vm.profileStatus = status
            for (language, scheme) in appearances {
                try render(vm, language: language, scheme: scheme, width: 800, showsRegion: true)
            }
            XCTAssertEqual(vm.profileStatus, status)
            XCTAssertEqual(vm.selectedProfileID, "production-readonly")
        }
    }

    func testIdentitySummaryShowsRoleWithoutTemporarySessionName() {
        let summary = ProfileIdentitySummary(identity: AWSIdentity(
            account: "111122223333", arn: "arn:aws:sts::111122223333:assumed-role/ReadOnlyAccess/temporary-session", userID: "fixture"))
        XCTAssertEqual(summary.account, "111122223333")
        XCTAssertEqual(summary.principal, "ReadOnlyAccess")
        XCTAssertEqual(summary.principalLabel, "Role")
    }

    func testIdentitySummaryPreservesRolePathAndNonRoleIdentity() {
        let role = ProfileIdentitySummary(identity: AWSIdentity(
            account: "111122223333", arn: "arn:aws-cn:iam::111122223333:role/team/platform/Reader", userID: "fixture"))
        XCTAssertEqual(role.principal, "team/platform/Reader")
        XCTAssertEqual(role.principalLabel, "Role")
        for arn in ["arn:aws:iam::111122223333:user/team/operator", "arn:aws:iam::111122223333:root", "unrecognized-identity", "arn:aws:sts::111122223333:assumed-role//session"] {
            let summary = ProfileIdentitySummary(identity: AWSIdentity(account: "111122223333", arn: arn, userID: "fixture"))
            XCTAssertEqual(summary.principal, arn)
            XCTAssertEqual(summary.principalLabel, "Identity")
        }
    }

    private var appearances: [(String, ColorScheme)] {
        [("en", .light), ("en", .dark), ("zh-Hans", .light), ("zh-Hans", .dark)]
    }

    private func render(_ vm: ProfileViewModel, language: String, scheme: ColorScheme, width: Double, showsRegion: Bool) throws {
        let root = ProfileBarView(vm: vm, onRetry: { XCTFail("Layout must not retry a connection") },
                                  onLogin: { XCTFail("Layout must not start login") },
                                  onCancelLogin: { XCTFail("Layout must not cancel login") }, showsResourceRegion: showsRegion)
            .frame(width: width, height: 200, alignment: .topLeading)
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor))
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        // The mounted native tree has one focus-ring view per rendered control,
        // including disabled Region controls. KeyViewProxy exists only for
        // focusable controls, so it cannot measure the complete visible layout.
        let controls = descendants(view).filter {
            NSStringFromClass(type(of: $0)).hasSuffix("_FocusRingView")
                && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0
        }
        let frames = controls.map { controlFrame($0, in: view) }
        let expectedCount = (showsRegion ? 5 : 3) + (vm.selectedSession != nil || vm.isSigningIn ? 1 : 0)
        let context = "\(language)-\(scheme == .dark ? "dark" : "light")-\(Int(width))-\(showsRegion ? "regional" : "global")-\(vm.selectedSession == nil ? "other" : "sso")-\(vm.selectedProfileID == nil ? "empty" : "selected")"
        XCTAssertGreaterThanOrEqual(frames.count, expectedCount, context)
        let firstRowY = try XCTUnwrap(frames.map(\.minY).min())
        let firstRow = frames.filter { abs($0.minY - firstRowY) < 1 }
        let session = try XCTUnwrap(firstRow.min { $0.minX < $1.minX }, "The Session control must remain in the first row")
        let region: NSRect?
        if showsRegion {
            region = try XCTUnwrap(frames.filter { $0 != session && abs($0.width - WorkspaceLayout.regionWidth) < 1 }.max {
                abs($0.minY - $1.minY) > 1 ? $0.minY < $1.minY : $0.minX < $1.minX
            }, "The fixed-width Region control must remain mounted: \(context)")
        } else {
            region = nil
        }
        let profile = try XCTUnwrap(firstRow.filter { $0 != session && $0 != region }.max { $0.width < $1.width },
                                   "The flexible Profile control must remain beside Session")
        let retry = try XCTUnwrap(frames.max { $0.midY < $1.midY }, "The Retry control must remain in the last row")
        XCTAssertLessThan(session.minX, 40, "The Session control must align to the leading content edge")
        XCTAssertGreaterThanOrEqual(profile.width, WorkspaceLayout.profileMinimum)
        XCTAssertGreaterThanOrEqual(profile.width, width - 900, "Profile must absorb the extra width")
        XCTAssertEqual(profile.minY, session.minY, accuracy: 1, "Session and Profile must remain in the same control row")
        XCTAssertGreaterThan(retry.maxX, width - 24, "Retry must remain at the trailing edge of the status row")
        XCTAssertGreaterThan(retry.minY, profile.maxY, "Retry must follow the context controls in the status row")
        if let region {
            XCTAssertEqual(region.width, WorkspaceLayout.regionWidth, accuracy: 1)
            if width == 800 && vm.selectedSession != nil {
                XCTAssertGreaterThan(region.minY, session.maxY, "Region must wrap below the first row")
                XCTAssertEqual(region.minX, session.minX, accuracy: 1, "The wrapped Region control must align to Session")
            } else if width >= 1000 {
                XCTAssertEqual(region.minY, session.minY, accuracy: 1, "Wide windows must keep a single control row")
            } else {
                XCTAssertGreaterThanOrEqual(region.minY, session.minY, "Only the Region group may move to a lower control row")
            }
        }
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, width)
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxY, 200, "Grouped controls and the status row must remain visible")
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/native-layout-redesign/profile-header", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let selection = vm.selectedProfileID == nil ? "empty" : "selected"
        let status: String
        switch vm.profileStatus {
        case .idle: status = "idle"
        case .checking: status = "checking"
        case .valid: status = "verified"
        case .failed: status = "failed"
        }
        try png.write(to: output.appendingPathComponent("\(language)-\(scheme == .dark ? "dark" : "light")-\(Int(width))-\(showsRegion ? "regional" : "global")-\(selection)-\(status).png"))
    }

    private func controlFrame(_ control: NSView, in view: NSView) -> NSRect {
        let frame = control.convert(control.bounds, to: view)
        return view.isFlipped ? frame : NSRect(x: frame.minX, y: view.bounds.maxY - frame.maxY,
                                              width: frame.width, height: frame.height)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

}
