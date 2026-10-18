import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class RDSPresentationTests: XCTestCase {
    func testInstancesAndServerlessClustersFitNarrowPanesInBothLanguages() async throws {
        let instance = database(.instance)
        let cluster = database(.cluster)
        let vm = RDSViewModel(instanceLoader: { _ in [instance] }, clusterLoader: { _ in [cluster] })
        vm.configure(scope: scope())
        vm.loadIfNeeded()
        await vm.waitForLoading()
        XCTAssertNil(vm.selectedDatabase)
        XCTAssertNotNil(NSImage(systemSymbolName: AWSService.rds.icon, accessibilityDescription: nil))
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark)] {
            try snapshot(RDSDatabaseListView(vm: vm), name: "list-\(language)", width: 280, height: 550,
                         language: language, scheme: scheme)
            vm.selectedDatabase = instance
            try snapshot(RDSDatabaseDetailView(vm: vm), name: "instance-\(language)", width: 480, height: 1000,
                         language: language, scheme: scheme)
            vm.selectedDatabase = cluster
            try snapshot(RDSDatabaseDetailView(vm: vm), name: "cluster-\(language)", width: 480, height: 1000,
                         language: language, scheme: scheme, scrollToBottom: true)
        }
    }

    func testCreatingDatabaseWithUnknownFieldsFitsNarrowPane() throws {
        let db = RDSDatabase(arn: "arn:aws:rds:us-east-1:111122223333:db:creating",
                             identifier: "creating", kind: .instance, engine: "future-engine", status: "creating")
        XCTAssertNil(db.publiclyAccessible)
        XCTAssertNil(db.encrypted)
        XCTAssertNil(db.endpoint)
        try snapshot(ScrollView { RDSDatabaseFieldsView(database: db, scope: scope()).padding(16) },
                     name: "unknown-zh-Hans", width: 480, height: 1000, language: "zh-Hans", scheme: .dark,
                     scrollToBottom: true)
    }

    func testPartialAndCompletePermissionFailuresStayReadable() async throws {
        let cluster = database(.cluster)
        for allFailed in [false, true] {
            let vm = RDSViewModel(instanceLoader: { _ in throw AWSRDSService.RequestError.instancesPermission },
                                 clusterLoader: { _ in
                if allFailed { throw AWSRDSService.RequestError.clustersPermission }
                return [cluster]
            })
            vm.configure(scope: scope())
            vm.loadIfNeeded()
            await vm.waitForLoading()
            XCTAssertNotNil(vm.instanceError)
            XCTAssertEqual(vm.clusters.count, allFailed ? 0 : 1)
            let translated = L10n.text(try XCTUnwrap(vm.error), locale: Locale(identifier: "zh-Hans"))
            XCTAssertFalse(translated.contains("could not be read"))
            XCTAssertTrue(translated.contains("rds:DescribeDBInstances"))
            if allFailed { XCTAssertTrue(translated.contains("rds:DescribeDBClusters")) }
            try snapshot(RDSDatabaseListView(vm: vm), name: allFailed ? "errors-zh-Hans" : "partial-error-zh-Hans",
                         width: 280, height: 550, language: "zh-Hans", scheme: .dark)
        }
    }

    private func scope() -> MonitoringScope {
        let profile = AWSProfile(name: "mock", region: "us-east-1", ssoStartURL: nil,
                                 ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        return providerTestScope(profile, paths: AWSConfigurationPaths(environment: [:]))
    }

    private func database(_ kind: RDSResourceKind) -> RDSDatabase {
        let name = String(repeating: "database-", count: 6) + "prod"
        let resource = kind == .instance ? "db" : "cluster"
        return RDSDatabase(arn: "arn:aws:rds:us-east-1:111122223333:\(resource):\(name)", identifier: name, kind: kind,
            engine: kind == .instance ? "postgres" : "aurora-postgresql", engineVersion: "16.6", status: "available",
            instanceClass: kind == .instance ? "db.r7g.large" : nil,
            clusterIdentifier: kind == .instance ? "example-cluster" : nil,
            endpoint: "\(name).example.us-east-1.rds.amazonaws.com",
            readerEndpoint: kind == .cluster ? "\(name).cluster-ro.example.us-east-1.rds.amazonaws.com" : nil,
            availabilityZone: "us-east-1a", secondaryAvailabilityZone: "us-east-1b", storageType: "gp3",
            kmsKeyID: "arn:aws:kms:us-east-1:111122223333:key/00000000-0000-0000-0000-000000000000",
            vpcID: kind == .instance ? "vpc-00000000000000000" : nil, subnetGroup: name + "-subnet-group",
            engineMode: kind == .cluster ? "provisioned" : nil, port: 5432, allocatedStorageGB: 100,
            backupRetentionDays: 7, multiAZ: true, publiclyAccessible: false, encrypted: true, deletionProtection: true,
            availabilityZones: ["us-east-1a", "us-east-1b"],
            subnetIDs: kind == .instance ? ["subnet-00000000000000000", "subnet-11111111111111111"] : [],
            securityGroupIDs: ["sg-00000000000000000"],
            members: kind == .cluster ? [.init(identifier: name + "-writer", isWriter: true, promotionTier: 0),
                                         .init(identifier: name + "-unknown")] : [],
            tags: ["Name": name, "long-key-标签": String(repeating: "Long tag value 标签值 ", count: 12)],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            serverlessV2MinACU: kind == .cluster ? 0 : nil, serverlessV2MaxACU: kind == .cluster ? 8 : nil)
    }

    private func snapshot<Content: View>(_ content: Content, name: String, width: CGFloat, height: CGFloat,
                                        language: String, scheme: ColorScheme, scrollToBottom: Bool = false) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
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
        settle(view, window: window)
        if scrollToBottom {
            let scroll = try XCTUnwrap(descendants(view).first { $0 is NSScrollView } as? NSScrollView)
            let document = try XCTUnwrap(scroll.documentView)
            let y = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(view, window: window)
        }
        XCTAssertLessThanOrEqual(view.fittingSize.width, width)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 1, accuracy: 0.01)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/rds-query/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(name).png"))
    }

    private func settle(_ view: NSView, window: NSWindow) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        view.displayIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
