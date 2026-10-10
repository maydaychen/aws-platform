import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class HealthOrganizationPresentationTests: XCTestCase {
    func testOrganizationControlsAndMemberDetailsRenderInBothLanguages() async throws {
        let vm = HealthViewModel(
            listLoader: { _ in [organizationHealthEvent()] },
            detailLoader: { _, event in
                HealthEventDetails(event: event, description: "Scheduled EC2 maintenance for this account. Review affected resources before the scheduled date.")
            },
            entityLoader: { _, event in
                [HealthAffectedEntity(id: "mock-resource", value: "i-0123456789abcdef0", status: "PENDING", accountID: event.affectedAccountID)]
            },
            accountsLoader: { _, _ in ["444455556666", "777788889999"] }
        )
        vm.configure(scope: organizationHealthScope())
        vm.setQueryMode(.organization)
        await vm.waitForCurrentLoad()
        vm.selectedEvent = vm.events[0]
        await vm.waitForDetails()
        vm.selectAccount("444455556666")
        await vm.waitForDetails()
        try render(vm)
    }

    private func render(_ vm: HealthViewModel) throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/health-organization/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (language, scheme, width) in [("en", ColorScheme.light, 760.0), ("zh-Hans", ColorScheme.dark, 1060.0)] {
            let root = HealthView(vm: vm)
                .frame(width: width, height: 720)
                .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
                .background(Color(nsColor: .windowBackgroundColor))
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 720),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.orderBack(nil)
            defer { window.close() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(language).png"))
            XCTAssertEqual(view.bounds.width, width)
            XCTAssertEqual(view.bounds.height, 720)
            XCTAssertEqual(vm.selectedAccount, "444455556666")
            XCTAssertEqual(vm.queryMode, .organization)
        }
    }

    func testOrganizationSetupAndAccountErrorsAreLocalized() {
        let errors: [Error] = [HealthError.invalidAccountFilter, AWSHealthService.RequestError.organizationListPermission,
                               AWSHealthService.RequestError.organizationAccountsPermission,
                               AWSHealthService.RequestError.organizationDetailPermission,
                               AWSHealthService.RequestError.organizationEntitiesPermission,
                               AWSHealthService.RequestError.organizationUnavailable]
        for error in errors {
            XCTAssertNotEqual(L10n.text(error.localizedDescription, locale: Locale(identifier: "zh-Hans")), error.localizedDescription)
        }
    }
}
