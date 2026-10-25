import Foundation
import SotoCore
import SotoAutoScaling
@testable import AWSPlatform

struct ASGFixtureError: AWSErrorType {
    let errorCode: String
    var context: AWSErrorContext? { nil }
    var description: String { "\(errorCode): private-asg-token" }
    init(_ code: String) { errorCode = code }
    init?(errorCode: String, context: AWSErrorContext) { self.errorCode = errorCode }
}

func asgServiceScope(account: String = "111122223333", region: String = "eu-west-1",
                     profile: String = "work", partition: String = "aws") -> MonitoringScope {
    MonitoringScope(
        profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
        identity: AWSIdentity(account: account, arn: "arn:\(partition):sts::\(account):assumed-role/Test/session", userID: "fixture"),
        region: region,
        paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/config", "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials"])
    )
}

func asgServiceARN(_ name: String = "example", uniqueID: String = "group-identity") -> String {
    "arn:aws:autoscaling:eu-west-1:111122223333:autoScalingGroup:\(uniqueID):autoScalingGroupName/\(name)"
}

func asgServiceGroup(_ name: String = "example", uniqueID: String = "group-identity") -> ASGGroup {
    ASGGroup(arn: asgServiceARN(name, uniqueID: uniqueID), name: name)
}

func asgRawGroup(_ name: String = "example", arn: String? = nil) -> AutoScaling.AutoScalingGroup {
    .init(autoScalingGroupARN: arn ?? asgServiceARN(name), autoScalingGroupName: name)
}

func asgRawPolicy(_ name: String = "scale", group: String = "example", arn: String? = nil) -> AutoScaling.ScalingPolicy {
    .init(autoScalingGroupName: group,
          policyARN: arn ?? "arn:aws:autoscaling:eu-west-1:111122223333:scalingPolicy:policy-identity:autoScalingGroupName/\(group):policyName/\(name)",
          policyName: name)
}

func asgRawActivity(_ activityID: String = "activity", group: String = "example", arn: String? = nil) -> AutoScaling.Activity {
    .init(activityId: activityID, autoScalingGroupARN: arn, autoScalingGroupName: group)
}

actor AutoScalingServiceFixture {
    enum Operation: CaseIterable, Sendable { case groups, policies, activities }
    struct Requests: Sendable {
        var groups: [AutoScaling.AutoScalingGroupNamesType] = []
        var policies: [AutoScaling.DescribePoliciesType] = []
        var activities: [AutoScaling.DescribeScalingActivitiesType] = []
        var total: Int { groups.count + policies.count + activities.count }
    }

    private var calls = Requests()
    private let groupPages: [AutoScaling.AutoScalingGroupsType]
    private let policyPages: [AutoScaling.PoliciesType]
    private let activityPages: [AutoScaling.ActivitiesType]
    private let failOperation: Operation?
    private let failAt: Int
    private let failure: Error
    private let gate: AutoScalingServiceRequestGate?

    init(groupPages: [AutoScaling.AutoScalingGroupsType] = [.init()], policyPages: [AutoScaling.PoliciesType] = [.init()],
         activityPages: [AutoScaling.ActivitiesType] = [.init()], failOperation: Operation? = nil, failAt: Int = 0,
         failure: Error = ASGFixtureError("AccessDeniedException"), gate: AutoScalingServiceRequestGate? = nil) {
        self.groupPages = groupPages
        self.policyPages = policyPages
        self.activityPages = activityPages
        self.failOperation = failOperation
        self.failAt = failAt
        self.failure = failure
        self.gate = gate
    }

    func requests() -> Requests { calls }

    func groups(_ input: AutoScaling.AutoScalingGroupNamesType) async throws -> AutoScaling.AutoScalingGroupsType {
        let index = calls.groups.count
        calls.groups.append(input)
        try await check(.groups, index: index)
        return index < groupPages.count ? groupPages[index] : .init()
    }

    func policies(_ input: AutoScaling.DescribePoliciesType) async throws -> AutoScaling.PoliciesType {
        let index = calls.policies.count
        calls.policies.append(input)
        try await check(.policies, index: index)
        return index < policyPages.count ? policyPages[index] : .init()
    }

    func activities(_ input: AutoScaling.DescribeScalingActivitiesType) async throws -> AutoScaling.ActivitiesType {
        let index = calls.activities.count
        calls.activities.append(input)
        try await check(.activities, index: index)
        return index < activityPages.count ? activityPages[index] : .init()
    }

    private func check(_ operation: Operation, index: Int) async throws {
        if let gate { await gate.enter() }
        if failOperation == operation, failAt == index { throw failure }
    }

    nonisolated var service: AWSAutoScalingService {
        AWSAutoScalingService(groupLoader: { try await self.groups($0) }, policyLoader: { try await self.policies($0) },
                              activityLoader: { try await self.activities($0) })
    }
}

actor AutoScalingServiceRequestGate {
    private var entered = false
    private var opened = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiting: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if !opened { await withCheckedContinuation { waiting = $0 } }
    }

    func waitForEntry() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }
}
