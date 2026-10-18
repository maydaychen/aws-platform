import Foundation

struct ASGLaunchTemplate: Hashable, Sendable {
    let templateID: String?
    let name: String?
    let version: String?

    init(templateID: String? = nil, name: String? = nil, version: String? = nil) {
        self.templateID = templateID
        self.name = name
        self.version = version
    }
}

struct ASGInstanceOverride: Hashable, Sendable {
    let instanceType: String?
    let weightedCapacity: String?
    let usesInstanceRequirements: Bool
    let launchTemplate: ASGLaunchTemplate?

    init(instanceType: String? = nil, weightedCapacity: String? = nil,
         usesInstanceRequirements: Bool = false, launchTemplate: ASGLaunchTemplate? = nil) {
        self.instanceType = instanceType
        self.weightedCapacity = weightedCapacity
        self.usesInstanceRequirements = usesInstanceRequirements
        self.launchTemplate = launchTemplate
    }
}

struct ASGMixedInstances: Hashable, Sendable {
    let launchTemplate: ASGLaunchTemplate?
    let overrides: [ASGInstanceOverride]
    let onDemandBaseCapacity: Int?
    let onDemandPercentageAboveBaseCapacity: Int?
    let onDemandAllocationStrategy: String?
    let spotAllocationStrategy: String?

    init(launchTemplate: ASGLaunchTemplate? = nil, overrides: [ASGInstanceOverride] = [],
         onDemandBaseCapacity: Int? = nil, onDemandPercentageAboveBaseCapacity: Int? = nil,
         onDemandAllocationStrategy: String? = nil, spotAllocationStrategy: String? = nil) {
        self.launchTemplate = launchTemplate
        self.overrides = overrides
        self.onDemandBaseCapacity = onDemandBaseCapacity
        self.onDemandPercentageAboveBaseCapacity = onDemandPercentageAboveBaseCapacity
        self.onDemandAllocationStrategy = onDemandAllocationStrategy
        self.spotAllocationStrategy = spotAllocationStrategy
    }
}

struct ASGMember: Identifiable, Hashable, Sendable {
    let instanceID: String
    let instanceType: String?
    let availabilityZone: String?
    let lifecycleState: String?
    let healthStatus: String?
    let protectedFromScaleIn: Bool?
    let weightedCapacity: String?
    let launchConfiguration: String?
    let launchTemplate: ASGLaunchTemplate?

    var id: String { instanceID }

    init(instanceID: String, instanceType: String? = nil, availabilityZone: String? = nil,
         lifecycleState: String? = nil, healthStatus: String? = nil, protectedFromScaleIn: Bool? = nil,
         weightedCapacity: String? = nil, launchConfiguration: String? = nil, launchTemplate: ASGLaunchTemplate? = nil) {
        self.instanceID = instanceID
        self.instanceType = instanceType
        self.availabilityZone = availabilityZone
        self.lifecycleState = lifecycleState
        self.healthStatus = healthStatus
        self.protectedFromScaleIn = protectedFromScaleIn
        self.weightedCapacity = weightedCapacity
        self.launchConfiguration = launchConfiguration
        self.launchTemplate = launchTemplate
    }
}

struct ASGTag: Identifiable, Hashable, Sendable {
    let key: String
    let value: String?
    let propagateAtLaunch: Bool?
    var id: String { key }

    init(key: String, value: String? = nil, propagateAtLaunch: Bool? = nil) {
        self.key = key
        self.value = value
        self.propagateAtLaunch = propagateAtLaunch
    }
}

struct ASGSuspendedProcess: Hashable, Sendable {
    let name: String?
    let reason: String?

    init(name: String? = nil, reason: String? = nil) {
        self.name = name
        self.reason = reason
    }
}

struct ASGGroup: Identifiable, Hashable, Sendable {
    let arn: String
    let name: String
    let minSize: Int?
    let maxSize: Int?
    let desiredCapacity: Int?
    let desiredCapacityType: String?
    let status: String?
    let availabilityZones: [String]
    let subnetIDs: [String]
    let launchConfiguration: String?
    let launchTemplate: ASGLaunchTemplate?
    let mixedInstances: ASGMixedInstances?
    let loadBalancerNames: [String]
    let targetGroupARNs: [String]
    let healthCheckType: String?
    let healthCheckGracePeriod: Int?
    let defaultCooldown: Int?
    let defaultInstanceWarmup: Int?
    let newInstancesProtectedFromScaleIn: Bool?
    let capacityRebalance: Bool?
    let serviceLinkedRoleARN: String?
    let terminationPolicies: [String]
    let suspendedProcesses: [ASGSuspendedProcess]
    let members: [ASGMember]
    let tags: [ASGTag]
    let createdAt: Date?
    var id: String { arn }

    init(arn: String, name: String, minSize: Int? = nil, maxSize: Int? = nil,
         desiredCapacity: Int? = nil, desiredCapacityType: String? = nil, status: String? = nil,
         availabilityZones: [String] = [], subnetIDs: [String] = [], launchConfiguration: String? = nil,
         launchTemplate: ASGLaunchTemplate? = nil, mixedInstances: ASGMixedInstances? = nil,
         loadBalancerNames: [String] = [], targetGroupARNs: [String] = [], healthCheckType: String? = nil,
         healthCheckGracePeriod: Int? = nil, defaultCooldown: Int? = nil, defaultInstanceWarmup: Int? = nil,
         newInstancesProtectedFromScaleIn: Bool? = nil, capacityRebalance: Bool? = nil,
         serviceLinkedRoleARN: String? = nil, terminationPolicies: [String] = [],
         suspendedProcesses: [ASGSuspendedProcess] = [], members: [ASGMember] = [], tags: [ASGTag] = [], createdAt: Date? = nil) {
        self.arn = arn
        self.name = name
        self.minSize = minSize
        self.maxSize = maxSize
        self.desiredCapacity = desiredCapacity
        self.desiredCapacityType = desiredCapacityType
        self.status = status
        self.availabilityZones = availabilityZones
        self.subnetIDs = subnetIDs
        self.launchConfiguration = launchConfiguration
        self.launchTemplate = launchTemplate
        self.mixedInstances = mixedInstances
        self.loadBalancerNames = loadBalancerNames
        self.targetGroupARNs = targetGroupARNs
        self.healthCheckType = healthCheckType
        self.healthCheckGracePeriod = healthCheckGracePeriod
        self.defaultCooldown = defaultCooldown
        self.defaultInstanceWarmup = defaultInstanceWarmup
        self.newInstancesProtectedFromScaleIn = newInstancesProtectedFromScaleIn
        self.capacityRebalance = capacityRebalance
        self.serviceLinkedRoleARN = serviceLinkedRoleARN
        self.terminationPolicies = terminationPolicies
        self.suspendedProcesses = suspendedProcesses
        self.members = members
        self.tags = tags
        self.createdAt = createdAt
    }
}

struct ASGAlarm: Hashable, Sendable {
    let arn: String?
    let name: String?

    init(arn: String? = nil, name: String? = nil) {
        self.arn = arn
        self.name = name
    }
}

struct ASGStepAdjustment: Hashable, Sendable {
    let lowerBound: Double?
    let upperBound: Double?
    let adjustment: Int?

    init(lowerBound: Double? = nil, upperBound: Double? = nil, adjustment: Int? = nil) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.adjustment = adjustment
    }
}

struct ASGPolicy: Identifiable, Hashable, Sendable {
    let arn: String
    let name: String
    let groupName: String
    let policyType: String?
    let enabled: Bool?
    let adjustmentType: String?
    let scalingAdjustment: Int?
    let minAdjustmentMagnitude: Int?
    let cooldown: Int?
    let estimatedInstanceWarmup: Int?
    let metricAggregationType: String?
    let targetValue: Double?
    let targetMetricType: String?
    let usesCustomizedMetric: Bool?
    let disableScaleIn: Bool?
    let predictiveMode: String?
    let alarms: [ASGAlarm]
    let stepAdjustments: [ASGStepAdjustment]
    var id: String { arn }

    init(arn: String, name: String, groupName: String, policyType: String? = nil, enabled: Bool? = nil,
         adjustmentType: String? = nil, scalingAdjustment: Int? = nil, minAdjustmentMagnitude: Int? = nil,
         cooldown: Int? = nil, estimatedInstanceWarmup: Int? = nil, metricAggregationType: String? = nil,
         targetValue: Double? = nil, targetMetricType: String? = nil, usesCustomizedMetric: Bool? = nil,
         disableScaleIn: Bool? = nil, predictiveMode: String? = nil,
         alarms: [ASGAlarm] = [], stepAdjustments: [ASGStepAdjustment] = []) {
        self.arn = arn
        self.name = name
        self.groupName = groupName
        self.policyType = policyType
        self.enabled = enabled
        self.adjustmentType = adjustmentType
        self.scalingAdjustment = scalingAdjustment
        self.minAdjustmentMagnitude = minAdjustmentMagnitude
        self.cooldown = cooldown
        self.estimatedInstanceWarmup = estimatedInstanceWarmup
        self.metricAggregationType = metricAggregationType
        self.targetValue = targetValue
        self.targetMetricType = targetMetricType
        self.usesCustomizedMetric = usesCustomizedMetric
        self.disableScaleIn = disableScaleIn
        self.predictiveMode = predictiveMode
        self.alarms = alarms
        self.stepAdjustments = stepAdjustments
    }
}

struct ASGActivity: Identifiable, Hashable, Sendable {
    let activityID: String
    let groupName: String
    let groupARN: String?
    let groupState: String?
    let statusCode: String?
    let statusMessage: String?
    let description: String?
    let cause: String?
    let details: String?
    let progress: Int?
    let startedAt: Date?
    let endedAt: Date?
    var id: String { activityID }

    init(activityID: String, groupName: String, groupARN: String? = nil, groupState: String? = nil,
         statusCode: String? = nil, statusMessage: String? = nil, description: String? = nil,
         cause: String? = nil, details: String? = nil, progress: Int? = nil,
         startedAt: Date? = nil, endedAt: Date? = nil) {
        self.activityID = activityID
        self.groupName = groupName
        self.groupARN = groupARN
        self.groupState = groupState
        self.statusCode = statusCode
        self.statusMessage = statusMessage
        self.description = description
        self.cause = cause
        self.details = details
        self.progress = progress
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

enum AutoScalingError: LocalizedError, Equatable {
    case invalidScope, invalidResponse, incompletePagination

    var errorDescription: String? {
        switch self {
        case .invalidScope: return "Select and verify an AWS profile before loading Auto Scaling."
        case .invalidResponse: return "Auto Scaling returned incomplete or mismatched data. Refresh to try again."
        case .incompletePagination: return "Auto Scaling pagination could not be completed. Partial results were not displayed. Refresh to try again."
        }
    }
}
