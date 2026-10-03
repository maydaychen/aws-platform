import Foundation

enum AlarmKind: String, CaseIterable, Identifiable, Sendable {
    case metric, composite

    var id: Self { self }
    var title: String { self == .metric ? "Metric" : "Composite" }
}

struct AlarmScope: Hashable, Sendable {
    let profile: AWSProfile
    let accountID: String
    let principalARN: String
    let region: String
    let configPath: String
    let credentialsPath: String

    var profileName: String { profile.name }

    init(
        profile: AWSProfile, identity: AWSIdentity, region: String,
        paths: AWSConfigurationPaths = AWSConfigurationPaths()
    ) {
        self.profile = profile
        accountID = identity.account
        principalARN = identity.arn
        self.region = region
        configPath = paths.config
        credentialsPath = paths.credentials
    }
}

struct AlarmProperty: Hashable, Sendable, Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

struct AlarmMetricQuery: Hashable, Sendable, Identifiable {
    let id: String
    let label: String?
    let expression: String?
    let accountID: String?
    let returnData: Bool?
    let namespace: String?
    let metricName: String?
    let dimensions: [AlarmProperty]
    let statistic: String?
    let period: Int?
    let unit: String?

    init(
        id: String, label: String? = nil, expression: String? = nil, accountID: String? = nil,
        returnData: Bool? = nil, namespace: String? = nil, metricName: String? = nil,
        dimensions: [AlarmProperty] = [], statistic: String? = nil, period: Int? = nil, unit: String? = nil
    ) {
        self.id = id
        self.label = label
        self.expression = expression
        self.accountID = accountID
        self.returnData = returnData
        self.namespace = namespace
        self.metricName = metricName
        self.dimensions = dimensions
        self.statistic = statistic
        self.period = period
        self.unit = unit
    }
}

struct CloudWatchAlarm: Hashable, Sendable, Identifiable {
    let arn: String
    let name: String
    let kind: AlarmKind
    let state: String
    let description: String?
    let reason: String?
    let reasonData: String?
    let stateUpdatedAt: Date?
    let stateTransitionedAt: Date?
    let configurationUpdatedAt: Date?
    let actionsEnabled: Bool?
    let alarmActions: [String]
    let okActions: [String]
    let insufficientDataActions: [String]
    let configuration: [AlarmProperty]
    let metrics: [AlarmMetricQuery]
    let rule: String?

    var id: String { arn }

    init(
        arn: String, name: String, kind: AlarmKind, state: String,
        description: String? = nil, reason: String? = nil, reasonData: String? = nil,
        stateUpdatedAt: Date? = nil, stateTransitionedAt: Date? = nil, configurationUpdatedAt: Date? = nil,
        actionsEnabled: Bool? = nil, alarmActions: [String] = [], okActions: [String] = [],
        insufficientDataActions: [String] = [], configuration: [AlarmProperty] = [],
        metrics: [AlarmMetricQuery] = [], rule: String? = nil
    ) {
        self.arn = arn
        self.name = name
        self.kind = kind
        self.state = state
        self.description = description
        self.reason = reason
        self.reasonData = reasonData
        self.stateUpdatedAt = stateUpdatedAt
        self.stateTransitionedAt = stateTransitionedAt
        self.configurationUpdatedAt = configurationUpdatedAt
        self.actionsEnabled = actionsEnabled
        self.alarmActions = alarmActions
        self.okActions = okActions
        self.insufficientDataActions = insufficientDataActions
        self.configuration = configuration
        self.metrics = metrics
        self.rule = rule
    }
}

struct AlarmHistoryEntry: Hashable, Sendable, Identifiable {
    let id: String
    let timestamp: Date?
    let type: String
    let summary: String
    let data: String?
    let contributorID: String?

    init(
        id: String, timestamp: Date? = nil, type: String, summary: String,
        data: String? = nil, contributorID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.summary = summary
        self.data = data
        self.contributorID = contributorID
    }
}

enum AlarmError: LocalizedError {
    case invalidScope, invalidResponse, incompletePagination

    var errorDescription: String? {
        switch self {
        case .invalidScope:
            return "Verify the selected profile and region before loading CloudWatch alarms."
        case .invalidResponse:
            return "AWS returned incomplete or inconsistent alarm data. Refresh to try again."
        case .incompletePagination:
            return "The complete alarm result could not be retrieved. Refresh to start a new request."
        }
    }
}
