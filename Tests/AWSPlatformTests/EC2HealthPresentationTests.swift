import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class EC2HealthPresentationTests: XCTestCase {
    func testHealthStatesAndReadWarningFitNarrowListInBothLanguages() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/ec2-health-fix/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let failure = "AWS permission denied. Check the selected profile and IAM permissions."
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark)] {
            for reduceMotion in [false, true] {
                let locale = Locale(identifier: language)
                let root = VStack(alignment: .leading, spacing: 8) {
                    indicatorRow("Loading status checks…", health: nil, loading: true, reduceMotion: reduceMotion, locale: locale)
                    indicatorRow("Status checks passed", health: health("ok"), locale: locale)
                    indicatorRow("Needs attention", health: health("impaired"), locale: locale)
                    indicatorRow("Unable to read status checks", health: nil, error: failure, locale: locale)
                    indicatorRow("Status checks not applicable", health: health("not-applicable"), locale: locale)
                    Divider()
                    EC2HealthReadWarning(errors: ["i-mock": failure])
                }
                .padding(.vertical, 8)
                .frame(width: 280)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.locale, locale)
                .environment(\.colorScheme, scheme)
                let view = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 280, height: 380),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.orderBack(nil)
                defer { window.close() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                view.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(view.fittingSize.width, 280)
                XCTAssertGreaterThan(view.fittingSize.height, 180)
                XCTAssertLessThan(view.fittingSize.height, 380, "The warning must remain readable in the narrow list")
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("health-\(language)-\(reduceMotion ? "reduced" : "animated").png"))
            }
        }
    }

    private func indicatorRow(_ key: String, health: EC2InstanceHealth?, loading: Bool = false,
                              reduceMotion: Bool = false, error: String? = nil, locale: Locale) -> some View {
        HStack {
            Text(L10n.text(key, locale: locale)).font(.caption)
            Spacer()
            if loading {
                EC2HealthLoadingIndicator(reduceMotion: reduceMotion)
            } else {
                EC2HealthStatusIndicator(health: health, isLoading: false, error: error)
            }
        }.padding(.horizontal, 12)
    }

    private func health(_ state: String) -> EC2InstanceHealth {
        EC2InstanceHealth(systemStatus: state, instanceStatus: state, attachedEBSStatus: nil, events: [])
    }
}
