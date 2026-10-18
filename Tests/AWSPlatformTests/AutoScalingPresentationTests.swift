import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class AutoScalingPresentationTests: XCTestCase {
    func testWeightedGroupAndDetailSectionsFitNarrowPanesInBothLanguages() async throws {
        let group = group()
        let vm = viewModel(group)
        vm.configure(scope: scope())
        vm.loadIfNeeded()
        await vm.waitForLoading()
        XCTAssertNil(vm.selectedGroup)
        XCTAssertNotNil(NSImage(systemSymbolName: AWSService.autoScaling.icon, accessibilityDescription: nil))
        vm.selectedGroup = group
        await vm.waitForDetails()
        XCTAssertEqual(vm.policies.count, 1)
        XCTAssertEqual(vm.activities.count, 1)
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark)] {
            try snapshot(AutoScalingGroupListView(vm: vm), name: "list-\(language)", width: 280, height: 550,
                         language: language, scheme: scheme)
            try snapshot(AutoScalingGroupDetailView(vm: vm), name: "overview-\(language)", width: 480, height: 1000,
                         language: language, scheme: scheme)
            try snapshot(ScrollView { AutoScalingGroupFieldsView(group: group, scope: scope()).padding(16) },
                         name: "members-\(language)", width: 480, height: 1000, language: language,
                         scheme: scheme, scrollFraction: 1)
            try snapshot(ScrollView { AutoScalingGroupHistoryView(vm: vm).padding(16) },
                         name: "policy-\(language)", width: 480, height: 1000, language: language, scheme: scheme)
            try snapshot(ScrollView { AutoScalingGroupHistoryView(vm: vm).padding(16) },
                         name: "activity-\(language)", width: 480, height: 1000, language: language,
                         scheme: scheme, scrollFraction: 1)
        }
    }

    func testOptionalFieldsAndMixedInstanceAliasesStayReadable() throws {
        let group = ASGGroup(arn: "arn:aws:autoscaling:us-east-1:111122223333:autoScalingGroup:unknown:autoScalingGroupName/unknown",
                             name: "unknown", mixedInstances: .init(launchTemplate: .init(name: "按属性选择实例的模板", version: "$Default"),
                                 overrides: [.init(usesInstanceRequirements: true)], onDemandPercentageAboveBaseCapacity: 0))
        XCTAssertNil(group.desiredCapacity)
        XCTAssertNil(group.newInstancesProtectedFromScaleIn)
        try snapshot(ScrollView { AutoScalingGroupFieldsView(group: group, scope: scope()).padding(16) },
                     name: "unknown-mixed-zh-Hans", width: 480, height: 1000, language: "zh-Hans", scheme: .dark,
                     scrollFraction: 0.45)
    }

    func testPartialAndCompleteDetailPermissionFailuresAreLocalized() async throws {
        let group = group()
        for allFailed in [false, true] {
            let vm = AutoScalingViewModel(groupLoader: { _ in [group] }, policyLoader: { _, _ in
                throw AWSAutoScalingService.RequestError.policiesPermission
            }, activityLoader: { _, _ in
                if allFailed { throw AWSAutoScalingService.RequestError.activitiesPermission }
                return []
            })
            vm.configure(scope: scope())
            vm.loadIfNeeded()
            await vm.waitForLoading()
            vm.selectedGroup = group
            await vm.waitForDetails()
            XCTAssertNotNil(vm.policiesError)
            XCTAssertEqual(vm.activitiesError != nil, allFailed)
            let translated = L10n.text(try XCTUnwrap(vm.policiesError), locale: Locale(identifier: "zh-Hans"))
            XCTAssertTrue(translated.contains("autoscaling:DescribePolicies"))
            XCTAssertFalse(translated.contains("could not be read"))
            try snapshot(ScrollView { AutoScalingGroupHistoryView(vm: vm).padding(16) },
                         name: allFailed ? "errors-zh-Hans" : "partial-error-zh-Hans", width: 480, height: 700,
                         language: "zh-Hans", scheme: .dark)
        }
    }

    private func viewModel(_ group: ASGGroup) -> AutoScalingViewModel {
        let policy = ASGPolicy(arn: "arn:aws:autoscaling:us-east-1:111122223333:scalingPolicy:example:autoScalingGroupName/\(group.name):policyName/cpu-target",
            name: "cpu-target", groupName: group.name, policyType: "TargetTrackingScaling", enabled: true,
            estimatedInstanceWarmup: 120, targetValue: 60, targetMetricType: "ASGAverageCPUUtilization",
            usesCustomizedMetric: false, disableScaleIn: false,
            alarms: [.init(arn: "arn:aws:cloudwatch:us-east-1:111122223333:alarm/very-long-cpu-alarm-name", name: "cpu-alarm")])
        let activity = ASGActivity(activityID: "00000000-1111-2222-3333-444444444444", groupName: group.name, groupARN: group.arn,
            groupState: "InService", statusCode: "Failed", statusMessage: String(repeating: "Insufficient capacity in the selected Availability Zone. ", count: 4),
            description: "Launching a new EC2 instance", cause: String(repeating: "A policy changed desired capacity. 扩缩容原因。", count: 5),
            details: "{\"Availability Zone\":\"us-east-1a\",\"Subnet ID\":\"subnet-00000000000000000\"}", progress: 0,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: Date(timeIntervalSince1970: 1_700_000_060))
        return AutoScalingViewModel(groupLoader: { _ in [group] }, policyLoader: { _, _ in [policy] }, activityLoader: { _, _ in [activity] })
    }

    private func scope() -> MonitoringScope {
        providerTestScope(AWSProfile(name: "mock", region: "us-east-1", ssoStartURL: nil, ssoRegion: nil,
                                     ssoAccountID: nil, ssoRoleName: nil), paths: AWSConfigurationPaths(environment: [:]))
    }

    private func group() -> ASGGroup {
        let name = String(repeating: "production-group-", count: 4) + "web"
        return ASGGroup(arn: "arn:aws:autoscaling:us-east-1:111122223333:autoScalingGroup:00000000-1111-2222-3333-444444444444:autoScalingGroupName/\(name)",
            name: name, minSize: 4, maxSize: 64, desiredCapacity: 16, desiredCapacityType: "vcpu",
            availabilityZones: ["us-east-1a", "us-east-1b"], subnetIDs: ["subnet-00000000000000000", "subnet-11111111111111111"],
            mixedInstances: .init(launchTemplate: .init(templateID: "lt-00000000000000000", name: name + "-template", version: "$Latest"),
                overrides: [.init(instanceType: "m7g.xlarge", weightedCapacity: "4")], onDemandBaseCapacity: 4,
                onDemandPercentageAboveBaseCapacity: 25, onDemandAllocationStrategy: "prioritized", spotAllocationStrategy: "price-capacity-optimized"),
            targetGroupARNs: ["arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/\(name)/0000000000000000"],
            healthCheckType: "EC2,ELB", healthCheckGracePeriod: 300, defaultCooldown: 300, defaultInstanceWarmup: 120,
            newInstancesProtectedFromScaleIn: false, capacityRebalance: true, terminationPolicies: ["Default"],
            suspendedProcesses: [.init(name: "AZRebalance", reason: "Temporarily suspended by an operator")],
            members: [.init(instanceID: "i-00000000000000000", instanceType: "m7g.xlarge", availabilityZone: "us-east-1a",
                            lifecycleState: "InService", healthStatus: "Healthy", protectedFromScaleIn: true, weightedCapacity: "4")],
            tags: [.init(key: "Name", value: name, propagateAtLaunch: true),
                   .init(key: "标签", value: String(repeating: "Long tag value 标签值 ", count: 8)),
                   .init(key: "empty-value", value: ""), .init(key: "unknown-value")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func snapshot<Content: View>(_ content: Content, name: String, width: CGFloat, height: CGFloat,
                                        language: String, scheme: ColorScheme, scrollFraction: CGFloat? = nil) throws {
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
        if let scrollFraction {
            let scroll = try XCTUnwrap(descendants(view).first { $0 is NSScrollView } as? NSScrollView)
            let document = try XCTUnwrap(scroll.documentView)
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let y = document.isFlipped ? maximum * scrollFraction : maximum * (1 - scrollFraction)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(view, window: window)
        }
        XCTAssertLessThanOrEqual(view.fittingSize.width, width)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 1, accuracy: 0.01)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".tmp/asg-query/screenshots")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name).png"))
    }

    private func settle(_ view: NSView, window: NSWindow) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        view.displayIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
