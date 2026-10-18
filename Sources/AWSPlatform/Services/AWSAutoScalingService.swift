import Foundation
import SotoCore
import SotoAutoScaling

struct AWSAutoScalingService: Sendable {
    typealias GroupLoader = @Sendable (AutoScaling.AutoScalingGroupNamesType) async throws -> AutoScaling.AutoScalingGroupsType
    typealias PolicyLoader = @Sendable (AutoScaling.DescribePoliciesType) async throws -> AutoScaling.PoliciesType
    typealias ActivityLoader = @Sendable (AutoScaling.DescribeScalingActivitiesType) async throws -> AutoScaling.ActivitiesType

    private struct Operations: Sendable {
        let groups: GroupLoader
        let policies: PolicyLoader
        let activities: ActivityLoader
    }

    private let provider: AWSServiceProvider?
    private let injected: Operations?

    init(provider: AWSServiceProvider) {
        self.provider = provider
        injected = nil
    }

    init(groupLoader: @escaping GroupLoader, policyLoader: @escaping PolicyLoader, activityLoader: @escaping ActivityLoader) {
        provider = nil
        injected = Operations(groups: groupLoader, policies: policyLoader, activities: activityLoader)
    }

    func loadGroups(scope: MonitoringScope) async throws -> [ASGGroup] {
        do {
            let operations = try await operations(scope: scope)
            let groups = try await Self.pages { token in
                let response = try await operations.groups(.init(includeInstances: true, maxRecords: 100, nextToken: token))
                try Task.checkCancellation()
                return (try (response.autoScalingGroups ?? []).map { try Self.group($0, scope: scope) }, response.nextToken)
            }
            try Self.requireUnique(groups.map(\.arn))
            try Self.requireUnique(groups.map(\.name))
            return groups.sorted { $0.name < $1.name }
        } catch { throw Self.sanitized(error, operation: .groups) }
    }

    func loadPolicies(scope: MonitoringScope, group: ASGGroup) async throws -> [ASGPolicy] {
        do {
            try Self.validateGroup(group, scope: scope)
            let operations = try await operations(scope: scope)
            let policies = try await Self.pages { token in
                let response = try await operations.policies(.init(autoScalingGroupName: group.name, maxRecords: 100, nextToken: token))
                try Task.checkCancellation()
                return (try (response.scalingPolicies ?? []).map { try Self.policy($0, group: group, scope: scope) }, response.nextToken)
            }
            try Self.requireUnique(policies.map(\.arn))
            try Self.requireUnique(policies.map(\.name))
            return policies.sorted { $0.name < $1.name }
        } catch { throw Self.sanitized(error, operation: .policies) }
    }

    func loadActivities(scope: MonitoringScope, group: ASGGroup) async throws -> [ASGActivity] {
        do {
            try Self.validateGroup(group, scope: scope)
            let operations = try await operations(scope: scope)
            let activities = try await Self.pages { token in
                let response = try await operations.activities(.init(autoScalingGroupName: group.name, includeDeletedGroups: false,
                                                                      maxRecords: 100, nextToken: token))
                try Task.checkCancellation()
                return (try (response.activities ?? []).map { try Self.activity($0, group: group) }, response.nextToken)
            }
            try Self.requireUnique(activities.map(\.activityID))
            return activities
        } catch { throw Self.sanitized(error, operation: .activities) }
    }

    private func operations(scope: MonitoringScope) async throws -> Operations {
        try Task.checkCancellation()
        guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty else { throw AutoScalingError.invalidScope }
        if let injected { return injected }
        guard let provider else { throw AutoScalingError.invalidScope }
        let client = try await provider.autoScalingClient(scope: scope)
        try Task.checkCancellation()
        return Operations(groups: { try await client.describeAutoScalingGroups($0) },
                          policies: { try await client.describePolicies($0) },
                          activities: { try await client.describeScalingActivities($0) })
    }

    private static func pages<Value: Sendable>(
        _ loader: @Sendable (String?) async throws -> ([Value], String?)
    ) async throws -> [Value] {
        var values: [Value] = []
        var token: String?
        var seenTokens: Set<String> = []
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            let (page, next) = try await loader(token)
            try Task.checkCancellation()
            values.append(contentsOf: page)
            guard let next, !next.isEmpty else { return values }
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenTokens.insert(next).inserted else { throw AutoScalingError.incompletePagination }
            token = next
        }
        throw AutoScalingError.incompletePagination
    }

    private static func name(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { throw AutoScalingError.invalidResponse }
        return value
    }

    private static func arn(_ value: String?, type: String, suffix: String, scope: MonitoringScope) throws -> String {
        guard scope.isValid else { throw AutoScalingError.invalidScope }
        let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
        let prefix = "arn:\(partition):autoscaling:\(scope.region):\(scope.accountID):\(type):"
        guard let value, value.hasPrefix(prefix), value.hasSuffix(suffix) else { throw AutoScalingError.invalidResponse }
        let identity = String(value.dropFirst(prefix.count).dropLast(suffix.count))
        guard !identity.isEmpty, !identity.contains(":"), !identity.contains("/"),
              !identity.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              !identity.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw AutoScalingError.invalidResponse }
        return value
    }

    private static func validateGroup(_ group: ASGGroup, scope: MonitoringScope) throws {
        let groupName = try name(group.name)
        _ = try arn(group.arn, type: "autoScalingGroup", suffix: ":autoScalingGroupName/\(groupName)", scope: scope)
    }

    private static func requireUnique(_ values: [String]) throws {
        guard Set(values).count == values.count else { throw AutoScalingError.invalidResponse }
    }

    private static func group(_ raw: AutoScaling.AutoScalingGroup, scope: MonitoringScope) throws -> ASGGroup {
        let groupName = try name(raw.autoScalingGroupName)
        let groupARN = try arn(raw.autoScalingGroupARN, type: "autoScalingGroup", suffix: ":autoScalingGroupName/\(groupName)", scope: scope)
        let members = try (raw.instances ?? []).map { raw in
            ASGMember(instanceID: try name(raw.instanceId), instanceType: raw.instanceType,
                      availabilityZone: raw.availabilityZone, lifecycleState: raw.lifecycleState?.rawValue,
                      healthStatus: raw.healthStatus, protectedFromScaleIn: raw.protectedFromScaleIn,
                      weightedCapacity: raw.weightedCapacity, launchConfiguration: raw.launchConfigurationName,
                      launchTemplate: template(raw.launchTemplate))
        }
        try requireUnique(members.map(\.instanceID))
        let tags = try (raw.tags ?? []).map { raw in
            if let resourceID = raw.resourceId, resourceID != groupName { throw AutoScalingError.invalidResponse }
            if let resourceType = raw.resourceType, resourceType != "auto-scaling-group" { throw AutoScalingError.invalidResponse }
            guard let key = raw.key, !key.isEmpty else { throw AutoScalingError.invalidResponse }
            return ASGTag(key: key, value: raw.value, propagateAtLaunch: raw.propagateAtLaunch)
        }
        try requireUnique(tags.map(\.key))
        return ASGGroup(
            arn: groupARN, name: groupName, minSize: raw.minSize, maxSize: raw.maxSize,
            desiredCapacity: raw.desiredCapacity, desiredCapacityType: raw.desiredCapacityType, status: raw.status,
            availabilityZones: raw.availabilityZones ?? [],
            subnetIDs: raw.vpcZoneIdentifier?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? [],
            launchConfiguration: raw.launchConfigurationName, launchTemplate: template(raw.launchTemplate),
            mixedInstances: mixed(raw.mixedInstancesPolicy), loadBalancerNames: raw.loadBalancerNames ?? [],
            targetGroupARNs: raw.targetGroupARNs ?? [], healthCheckType: raw.healthCheckType,
            healthCheckGracePeriod: raw.healthCheckGracePeriod, defaultCooldown: raw.defaultCooldown,
            defaultInstanceWarmup: raw.defaultInstanceWarmup, newInstancesProtectedFromScaleIn: raw.newInstancesProtectedFromScaleIn,
            capacityRebalance: raw.capacityRebalance, serviceLinkedRoleARN: raw.serviceLinkedRoleARN,
            terminationPolicies: raw.terminationPolicies ?? [],
            suspendedProcesses: (raw.suspendedProcesses ?? []).map { .init(name: $0.processName, reason: $0.suspensionReason) },
            members: members, tags: tags.sorted { $0.key < $1.key }, createdAt: raw.createdTime
        )
    }

    private static func template(_ raw: AutoScaling.LaunchTemplateSpecification?) -> ASGLaunchTemplate? {
        raw.map { ASGLaunchTemplate(templateID: $0.launchTemplateId, name: $0.launchTemplateName, version: $0.version) }
    }

    private static func mixed(_ raw: AutoScaling.MixedInstancesPolicy?) -> ASGMixedInstances? {
        raw.map { raw in
            ASGMixedInstances(launchTemplate: template(raw.launchTemplate?.launchTemplateSpecification),
                overrides: (raw.launchTemplate?.overrides ?? []).map {
                    .init(instanceType: $0.instanceType, weightedCapacity: $0.weightedCapacity,
                          usesInstanceRequirements: $0.instanceRequirements != nil, launchTemplate: template($0.launchTemplateSpecification))
                }, onDemandBaseCapacity: raw.instancesDistribution?.onDemandBaseCapacity,
                onDemandPercentageAboveBaseCapacity: raw.instancesDistribution?.onDemandPercentageAboveBaseCapacity,
                onDemandAllocationStrategy: raw.instancesDistribution?.onDemandAllocationStrategy,
                spotAllocationStrategy: raw.instancesDistribution?.spotAllocationStrategy)
        }
    }

    private static func policy(_ raw: AutoScaling.ScalingPolicy, group: ASGGroup, scope: MonitoringScope) throws -> ASGPolicy {
        guard raw.autoScalingGroupName == group.name else { throw AutoScalingError.invalidResponse }
        let policyName = try name(raw.policyName)
        let policyARN = try arn(raw.policyARN, type: "scalingPolicy",
                                suffix: ":autoScalingGroupName/\(group.name):policyName/\(policyName)", scope: scope)
        return ASGPolicy(arn: policyARN, name: policyName, groupName: group.name, policyType: raw.policyType,
            enabled: raw.enabled, adjustmentType: raw.adjustmentType, scalingAdjustment: raw.scalingAdjustment,
            minAdjustmentMagnitude: raw.minAdjustmentMagnitude, cooldown: raw.cooldown,
            estimatedInstanceWarmup: raw.estimatedInstanceWarmup, metricAggregationType: raw.metricAggregationType,
            targetValue: raw.targetTrackingConfiguration?.targetValue,
            targetMetricType: raw.targetTrackingConfiguration?.predefinedMetricSpecification?.predefinedMetricType?.rawValue,
            usesCustomizedMetric: raw.targetTrackingConfiguration.map { $0.customizedMetricSpecification != nil },
            disableScaleIn: raw.targetTrackingConfiguration?.disableScaleIn,
            predictiveMode: raw.predictiveScalingConfiguration?.mode?.rawValue,
            alarms: (raw.alarms ?? []).map { .init(arn: $0.alarmARN, name: $0.alarmName) },
            stepAdjustments: (raw.stepAdjustments ?? []).map {
                .init(lowerBound: $0.metricIntervalLowerBound, upperBound: $0.metricIntervalUpperBound, adjustment: $0.scalingAdjustment)
            })
    }

    private static func activity(_ raw: AutoScaling.Activity, group: ASGGroup) throws -> ASGActivity {
        guard raw.autoScalingGroupName == group.name,
              raw.autoScalingGroupARN == group.arn else { throw AutoScalingError.invalidResponse }
        return ASGActivity(activityID: try name(raw.activityId), groupName: group.name, groupARN: raw.autoScalingGroupARN,
            groupState: raw.autoScalingGroupState, statusCode: raw.statusCode?.rawValue, statusMessage: raw.statusMessage,
            description: raw.description, cause: raw.cause, details: raw.details, progress: raw.progress,
            startedAt: raw.startTime, endedAt: raw.endTime)
    }

    private enum Operation { case groups, policies, activities }

    private static func sanitized(_ error: Error, operation: Operation) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? AutoScalingError { return error }
        if let error = error as? RequestError { return error }
        if error is AWSServiceError { return AutoScalingError.invalidScope }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedException", "UnauthorizedOperation", "ForbiddenException"].contains(code) {
            switch operation {
            case .groups: return RequestError.groupsPermission
            case .policies: return RequestError.policiesPermission
            case .activities: return RequestError.activitiesPermission
            }
        }
        if UserFacingError.requiresSSOLogin(error) { return RequestError.credentials }
        if error is URLError { return RequestError.network }
        switch code {
        case "Throttling", "ThrottlingException", "TooManyRequestsException", "ResourceContention": return RequestError.throttled
        case "InvalidNextToken", "InvalidNextTokenException", "InvalidPaginationToken": return AutoScalingError.incompletePagination
        default: return RequestError.failed
        }
    }

    enum RequestError: LocalizedError, Equatable {
        case groupsPermission, policiesPermission, activitiesPermission, credentials, network, throttled, failed

        var errorDescription: String? {
            switch self {
            case .groupsPermission: return "Auto Scaling groups could not be read. Check autoscaling:DescribeAutoScalingGroups permission for the selected profile."
            case .policiesPermission: return "Scaling policies could not be read. Check autoscaling:DescribePolicies permission for the selected profile."
            case .activitiesPermission: return "Scaling activities could not be read. Check autoscaling:DescribeScalingActivities permission for the selected profile."
            case .credentials: return "AWS credentials expired or are unavailable. Sign in to the session, select the profile again, then reload Auto Scaling."
            case .network: return "Unable to reach Auto Scaling. Check your network or proxy, then refresh."
            case .throttled: return "Auto Scaling is limiting requests. Wait a moment, then refresh manually."
            case .failed: return "The Auto Scaling request failed. Check the selected profile, region and service availability, then refresh."
            }
        }
    }
}
