import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class RDSInsightsPresentationTests: XCTestCase {
    func testDatabaseTabsAndLongEventMessagesFitNarrowPaneInBothLanguages() async throws {
        let database = RDSInsightsFixture.database()
        let message = String(repeating: "Long database maintenance message 维护事件描述 ", count: 12)
        for (language, scheme) in [ ("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark) ] {
            let list = RDSViewModel(instanceLoader: { _ in [database] }, clusterLoader: { _ in [] })
            list.configure(scope: rdsServiceScope())
            list.loadIfNeeded()
            await list.waitForLoading()
            list.selectedDatabase = database
            let insights = RDSInsightsViewModel(eventsLoader: { _, db in RDSInsightsFixture.eventsResult(db, message: message) },
                                               snapshotsLoader: { _, db in RDSInsightsFixture.snapshotsResult(db) })
            insights.configure(scope: rdsServiceScope(), database: database)
            insights.loadEvents()
            await insights.waitForLoading()
            try snapshot(RDSDatabaseDetailView(vm: list, insightsVM: insights, initialTab: .events),
                         name: "rds-events-\(language)", language: language, scheme: scheme,
                         nativeTabs: (labels: ["Overview", "Events", "Snapshots"].map { L10n.text($0, locale: Locale(identifier: language)) }, selectedIndex: 1)) {
                XCTAssertEqual(list.selectedDatabase, database)
                XCTAssertEqual(insights.scope, list.scope)
                XCTAssertEqual(insights.database, database)
                XCTAssertEqual(insights.eventsSnapshot?.databaseARN, database.arn)
                XCTAssertEqual(insights.eventsSnapshot?.events.count, 1)
                XCTAssertEqual(insights.eventsSnapshot?.events.first?.message, message)
                XCTAssertNil(insights.eventsError)
                XCTAssertFalse(insights.isEventsLoading)
            }
        }
    }

    func testSnapshotUnknownFieldsAndLongIdentifiersFitNarrowPaneInBothLanguages() async throws {
        let database = RDSInsightsFixture.database(.cluster, engine: "aurora-postgresql")
        let identifier = String(repeating: "snapshot-", count: 8) + "production"
        for (language, scheme) in [ ("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark) ] {
            let insights = RDSInsightsViewModel(eventsLoader: { _, db in RDSInsightsFixture.eventsResult(db) },
                                               snapshotsLoader: { _, db in RDSInsightsFixture.snapshotsResult(db, identifier: identifier) })
            insights.configure(scope: rdsServiceScope(), database: database)
            insights.loadSnapshots()
            await insights.waitForLoading()
            try snapshot(RDSDatabaseSnapshotsView(vm: insights, scope: rdsServiceScope(), database: database),
                         name: "rds-snapshots-\(language)", language: language, scheme: scheme) {
                XCTAssertEqual(insights.database, database)
                XCTAssertEqual(insights.snapshots.count, 1)
                XCTAssertEqual(insights.snapshots.first?.identifier, identifier)
                XCTAssertNil(insights.snapshots.first?.encrypted)
                XCTAssertNil(insights.snapshots.first?.createdAt)
                XCTAssertTrue(insights.hasLoadedSnapshots)
                XCTAssertNil(insights.snapshotsError)
            }
        }
    }

    func testManualEmptyAndPermissionStatesStayReadableWithoutLoadingOtherResources() async throws {
        let database = RDSInsightsFixture.database()
        let insights = RDSInsightsViewModel(eventsLoader: { _, _ in throw RDSInsightsError.eventsPermission },
                                           snapshotsLoader: { _, _ in [] })
        insights.configure(scope: rdsServiceScope(), database: database)
        try snapshot(RDSDatabaseEventsView(vm: insights, scope: rdsServiceScope(), database: database),
                     name: "rds-events-manual", language: "en", scheme: .light) {
            XCTAssertNil(insights.eventsSnapshot)
            XCTAssertFalse(insights.isEventsLoading)
        }
        insights.loadEvents()
        insights.loadSnapshots()
        await insights.waitForLoading()
        try snapshot(RDSDatabaseEventsView(vm: insights, scope: rdsServiceScope(), database: database),
                     name: "rds-events-permission", language: "zh-Hans", scheme: .dark) {
            XCTAssertEqual(insights.eventsError, RDSInsightsError.eventsPermission.localizedDescription)
            XCTAssertNil(insights.eventsSnapshot)
        }
        try snapshot(RDSDatabaseSnapshotsView(vm: insights, scope: rdsServiceScope(), database: database),
                     name: "rds-snapshots-empty", language: "zh-Hans", scheme: .dark) {
            XCTAssertTrue(insights.hasLoadedSnapshots)
            XCTAssertTrue(insights.snapshots.isEmpty)
            XCTAssertNil(insights.snapshotsError)
        }
    }

    func testAuroraMetricsAndUnsupportedClusterExplanationFitNarrowPane() async throws {
        let database = RDSInsightsFixture.database(.cluster, engine: "aurora-postgresql")
        let target = database.metricTarget
        let metrics = ResourceMetricsViewModel { _, target, range in
            let end = RDSInsightsFixture.now
            return .init(target: target, range: range, start: end.addingTimeInterval(-range.duration), end: end,
                         series: [.init(id: "volume_bytes", title: "Aurora volume bytes used", unit: "Bytes",
                                        statistic: "Average", points: [], status: .missing)], fetchedAt: end)
        }
        metrics.configure(scope: rdsServiceScope(), target: target)
        metrics.refresh()
        await metrics.waitForCurrentLoad()
        try snapshot(ResourceMetricsView(vm: metrics, scope: rdsServiceScope(), target: target),
                     name: "rds-aurora-metrics", language: "en", scheme: .light) {
            XCTAssertEqual(metrics.target, target)
            XCTAssertEqual(metrics.snapshot?.target, target)
            XCTAssertEqual(metrics.snapshot?.series.map(\.id), ["volume_bytes"])
            XCTAssertNil(metrics.error)
        }

        let ordinary = RDSInsightsFixture.database(.cluster, engine: "postgres")
        let list = RDSViewModel(instanceLoader: { _ in [] }, clusterLoader: { _ in [ordinary] })
        list.configure(scope: rdsServiceScope())
        list.loadIfNeeded()
        await list.waitForLoading()
        list.selectedDatabase = ordinary
        let unsupportedMetrics = ResourceMetricsViewModel { _, _, _ in throw ResourceMetricsError.invalidContext }
        try snapshot(RDSDatabaseDetailView(vm: list, metricsVM: unsupportedMetrics, initialTab: .metrics),
                     name: "rds-cluster-instance-metrics", language: "zh-Hans", scheme: .dark,
                     nativeTabs: (labels: ["Overview", "Metrics"].map { L10n.text($0, locale: Locale(identifier: "zh-Hans")) }, selectedIndex: 1)) {
            XCTAssertEqual(list.selectedDatabase, ordinary)
            XCTAssertFalse(ordinary.metricTarget.isValid)
            XCTAssertNil(unsupportedMetrics.target)
            XCTAssertNil(unsupportedMetrics.snapshot)
        }
    }

    private func snapshot<Content: View>(_ content: Content, name: String, language: String, scheme: ColorScheme,
                                        nativeTabs: (labels: [String], selectedIndex: Int)? = nil,
                                        assertContent: () -> Void = {}) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let width: CGFloat = 480
        let height: CGFloat = 900
        let root = content.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let appearance = try XCTUnwrap(window.appearance)
        appearance.performAsCurrentDrawingAppearance {
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            view.displayIfNeeded()
        }
        assertContent()
        XCTAssertLessThanOrEqual(view.fittingSize.width, width)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/service-submodules/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if let nativeTabs {
            // Native tab glyphs are omitted by the current offscreen renderer. Verify actual
            // control labels and selection here; screenshots cover the selected child content.
            let tab = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTabView }.first)
            let control = try XCTUnwrap(descendants(view).compactMap { $0 as? NSSegmentedControl }.first)
            let tabLabels = tab.tabViewItems.map(\.label)
            let tabIndex = tab.selectedTabViewItem.map { tab.indexOfTabViewItem($0) }
            let controlLabels = (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
            XCTAssertEqual(tabLabels, nativeTabs.labels)
            XCTAssertEqual(tabIndex, nativeTabs.selectedIndex)
            XCTAssertEqual(controlLabels, nativeTabs.labels)
            XCTAssertEqual(control.selectedSegment, nativeTabs.selectedIndex)
            XCTAssertTrue(control.isEnabled)
            let evidence = "Capture limitation: native tab glyphs are not visually verified by this offscreen renderer.\nNSTabView labels=\(tabLabels) selected=\(tabIndex ?? -1)\nNSSegmentedControl labels=\(controlLabels) selected=\(control.selectedSegment) enabled=\(control.isEnabled)\n"
            try evidence.write(to: output.appendingPathComponent("\(name)-native-tabs.txt"), atomically: true, encoding: .utf8)
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(name).png"))
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
