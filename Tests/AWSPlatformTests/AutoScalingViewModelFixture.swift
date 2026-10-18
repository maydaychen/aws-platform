import Foundation
@testable import AWSPlatform

actor ASGStateProbe {
    private var calls: [String: Int] = [:]
    private var completed: Set<String> = []
    private(set) var scopes: [MonitoringScope] = []
    private let gates: [String: TestGate]
    private let failures: Set<String>
    private let safeFailures: Set<String>
    private let cancellations: Set<String>
    private let groups: [String: [ASGGroup]]
    private let policies: [String: [ASGPolicy]]
    private let activities: [String: [ASGActivity]]

    init(gates: [String: TestGate] = [:], failures: Set<String> = [], safeFailures: Set<String> = [],
         cancellations: Set<String> = [], groups: [String: [ASGGroup]] = [:],
         policies: [String: [ASGPolicy]] = [:], activities: [String: [ASGActivity]] = [:]) {
        self.gates = gates
        self.failures = failures
        self.safeFailures = safeFailures
        self.cancellations = cancellations
        self.groups = groups
        self.policies = policies
        self.activities = activities
    }

    func counts() -> [Int] { ["groups", "policies", "activities"].map { calls[$0, default: 0] } }
    func finished(_ key: String) -> Bool { completed.contains(key) }

    func loadGroups(_ scope: MonitoringScope) async throws -> [ASGGroup] {
        let key = try await begin("groups", scope: scope)
        return groups[key] ?? [asgStateGroup(scope: scope), asgStateGroup("other", scope: scope)]
    }

    func loadPolicies(_ scope: MonitoringScope, group: ASGGroup) async throws -> [ASGPolicy] {
        let key = try await begin("policies", scope: scope)
        return policies[key] ?? [asgStatePolicy(group)]
    }

    func loadActivities(_ scope: MonitoringScope, group: ASGGroup) async throws -> [ASGActivity] {
        let key = try await begin("activities", scope: scope)
        return activities[key] ?? [asgStateActivity(group)]
    }

    private func begin(_ operation: String, scope: MonitoringScope) async throws -> String {
        calls[operation, default: 0] += 1
        scopes.append(scope)
        let key = "\(operation)-\(calls[operation]!)"
        await gates[key]?.wait()
        completed.insert(key)
        if failures.contains(key) { throw NSError(domain: "secret-response-body", code: 1) }
        if safeFailures.contains(key) { throw AutoScalingError.invalidResponse }
        if cancellations.contains(key) { throw CancellationError() }
        return key
    }
}

func asgStateGroup(_ name: String = "shared", scope: MonitoringScope = asgStateScope(),
                   token: String = "11111111-1111-4111-8111-111111111111", desired: Int = 2) -> ASGGroup {
    let arn = "arn:aws:autoscaling:\(scope.region):\(scope.accountID):autoScalingGroup:\(token):autoScalingGroupName/\(name)"
    return ASGGroup(arn: arn, name: name, minSize: 1, maxSize: 4, desiredCapacity: desired)
}

func asgStatePolicy(_ group: ASGGroup = asgStateGroup()) -> ASGPolicy {
    let arn = group.arn.replacingOccurrences(of: "autoScalingGroup:", with: "scalingPolicy:") + ":policyName/cpu"
    return ASGPolicy(arn: arn, name: "cpu", groupName: group.name, policyType: "TargetTrackingScaling")
}

func asgStateActivity(_ group: ASGGroup = asgStateGroup()) -> ASGActivity {
    ASGActivity(activityID: "activity-\(group.name)", groupName: group.name, groupARN: group.arn, statusCode: "Successful")
}

func asgStateScope(profile: String = "test", account: String = "111122223333", region: String = "us-east-1",
                   role: String = "ReadOnly", paths: AWSConfigurationPaths = AWSConfigurationPaths()) -> MonitoringScope {
    MonitoringScope(profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil,
                                        ssoAccountID: nil, ssoRoleName: nil),
                    identity: AWSIdentity(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/test", userID: "fixture"),
                    region: region, paths: paths)
}
