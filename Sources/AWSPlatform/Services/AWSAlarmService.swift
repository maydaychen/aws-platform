import Foundation
import SotoCore
import SotoCloudWatch

struct AWSAlarmService: Sendable {
    typealias AlarmLoader = @Sendable (CloudWatch.DescribeAlarmsInput) async throws -> CloudWatch.DescribeAlarmsOutput
    typealias TagLoader = @Sendable (CloudWatch.ListTagsForResourceInput) async throws -> CloudWatch.ListTagsForResourceOutput
    typealias HistoryLoader = @Sendable (CloudWatch.DescribeAlarmHistoryInput) async throws -> CloudWatch.DescribeAlarmHistoryOutput

    private struct Operations: Sendable {
        let alarms: AlarmLoader
        let tags: TagLoader
        let history: HistoryLoader
    }

    private let provider: AWSServiceProvider?
    private let injected: Operations?
    private let now: @Sendable () -> Date
    private static let maximumPages = 100

    init(provider: AWSServiceProvider) {
        self.provider = provider
        injected = nil
        now = { Date() }
    }

    init(
        alarmLoader: @escaping AlarmLoader, tagLoader: @escaping TagLoader,
        historyLoader: @escaping HistoryLoader, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        provider = nil
        injected = Operations(alarms: alarmLoader, tags: tagLoader, history: historyLoader)
        self.now = now
    }

    func loadAlarms(scope: AlarmScope) async throws -> [CloudWatchAlarm] {
        do {
            let partition = try Self.validateScope(scope)
            let operations = try await operations(scope: scope)
            var result: [CloudWatchAlarm] = []
            var seenARNs: Set<String> = []
            var token: String?
            var seenTokens: Set<String> = []
            for _ in 0..<Self.maximumPages {
                try Task.checkCancellation()
                let response = try await operations.alarms(.init(
                    alarmTypes: [.metricAlarm, .compositeAlarm], maxRecords: 100, nextToken: token
                ))
                try Task.checkCancellation()
                for metric in response.metricAlarms ?? [] {
                    let alarm = try Self.map(metric)
                    try Self.validateAlarm(alarm, scope: scope, partition: partition)
                    guard seenARNs.insert(alarm.arn).inserted else { throw AlarmError.invalidResponse }
                    result.append(alarm)
                }
                for composite in response.compositeAlarms ?? [] {
                    let alarm = try Self.map(composite)
                    try Self.validateAlarm(alarm, scope: scope, partition: partition)
                    guard seenARNs.insert(alarm.arn).inserted else { throw AlarmError.invalidResponse }
                    result.append(alarm)
                }
                guard let next = response.nextToken, !next.isEmpty else {
                    try Task.checkCancellation()
                    return result.sorted { $0.name == $1.name ? $0.arn < $1.arn : $0.name < $1.name }
                }
                guard seenTokens.insert(next).inserted else { throw AlarmError.incompletePagination }
                token = next
            }
            throw AlarmError.incompletePagination
        } catch {
            throw Self.sanitized(error, operation: .list)
        }
    }

    func loadTags(scope: AlarmScope, alarm: CloudWatchAlarm) async throws -> [String: String] {
        do {
            let partition = try Self.validateScope(scope)
            try Self.validateAlarm(alarm, scope: scope, partition: partition)
            let operations = try await operations(scope: scope)
            try Task.checkCancellation()
            let response = try await operations.tags(.init(resourceARN: alarm.arn))
            try Task.checkCancellation()
            var result: [String: String] = [:]
            for tag in response.tags ?? [] {
                guard let key = tag.key, !key.isEmpty, let value = tag.value, result[key] == nil else {
                    throw AlarmError.invalidResponse
                }
                result[key] = value
            }
            try Task.checkCancellation()
            return result
        } catch {
            throw Self.sanitized(error, operation: .tags)
        }
    }

    func loadHistory(scope: AlarmScope, alarm: CloudWatchAlarm) async throws -> [AlarmHistoryEntry] {
        do {
            let partition = try Self.validateScope(scope)
            try Self.validateAlarm(alarm, scope: scope, partition: partition)
            let operations = try await operations(scope: scope)
            let end = now()
            let start = end.addingTimeInterval(-30 * 24 * 60 * 60)
            let kind: CloudWatch.AlarmType = alarm.kind == .metric ? .metricAlarm : .compositeAlarm
            var result: [AlarmHistoryEntry] = []
            var token: String?
            var seenTokens: Set<String> = []
            for _ in 0..<Self.maximumPages {
                try Task.checkCancellation()
                let response = try await operations.history(.init(
                    alarmName: alarm.name, alarmTypes: [kind], endDate: end,
                    maxRecords: 100, nextToken: token, scanBy: .timestampDescending, startDate: start
                ))
                try Task.checkCancellation()
                for item in response.alarmHistoryItems ?? [] {
                    guard item.alarmName == nil || item.alarmName == alarm.name,
                          item.alarmType == nil || item.alarmType == kind else { throw AlarmError.invalidResponse }
                    if let timestamp = item.timestamp {
                        guard timestamp >= start, timestamp <= end else { throw AlarmError.invalidResponse }
                    }
                    result.append(AlarmHistoryEntry(
                        id: "\(alarm.arn)#history-\(result.count)", timestamp: item.timestamp,
                        type: item.historyItemType?.rawValue ?? "Unknown", summary: item.historySummary ?? "No summary",
                        data: item.historyData, contributorID: item.alarmContributorId
                    ))
                }
                guard let next = response.nextToken, !next.isEmpty else {
                    try Task.checkCancellation()
                    return result.enumerated().sorted {
                        let first = $0.element.timestamp ?? .distantPast
                        let second = $1.element.timestamp ?? .distantPast
                        return first == second ? $0.offset < $1.offset : first > second
                    }.map(\.element)
                }
                guard seenTokens.insert(next).inserted else { throw AlarmError.incompletePagination }
                token = next
            }
            throw AlarmError.incompletePagination
        } catch {
            throw Self.sanitized(error, operation: .history)
        }
    }

    private func operations(scope: AlarmScope) async throws -> Operations {
        try Task.checkCancellation()
        if let injected { return injected }
        guard let provider else { throw AlarmError.invalidScope }
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": scope.configPath, "AWS_SHARED_CREDENTIALS_FILE": scope.credentialsPath
        ])
        let client = try await provider.cloudWatchClient(profile: scope.profile, paths: paths, region: scope.region)
        return Operations(
            alarms: { try await client.describeAlarms($0) },
            tags: { try await client.listTagsForResource($0) },
            history: { try await client.describeAlarmHistory($0) }
        )
    }

    private static func validateScope(_ scope: AlarmScope) throws -> String {
        try Task.checkCancellation()
        let parts = scope.principalARN.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        let partitions: [String: AWSPartition] = [
            "aws": .aws, "aws-cn": .awscn, "aws-us-gov": .awsusgov,
            "aws-iso": .awsiso, "aws-iso-b": .awsisob, "aws-iso-e": .awsisoe,
            "aws-iso-f": .awsisof, "aws-eusc": .awseusc
        ]
        guard !scope.profileName.isEmpty,
              scope.accountID.range(of: "^[0-9]{12}$", options: .regularExpression) != nil,
              scope.region.range(of: "^[a-z]{2,4}(?:-[a-z0-9]+)+-[0-9]+$", options: .regularExpression) != nil,
              parts.count == 6, parts[0] == "arn", ["sts", "iam"].contains(String(parts[2])),
              parts[4] == scope.accountID, !parts[5].isEmpty,
              let partition = partitions[String(parts[1])],
              partition == Region(rawValue: scope.region).partition else { throw AlarmError.invalidScope }
        return String(parts[1])
    }

    private static func validateAlarm(_ alarm: CloudWatchAlarm, scope: AlarmScope, partition: String) throws {
        try Task.checkCancellation()
        guard !alarm.name.isEmpty,
              alarm.arn == "arn:\(partition):cloudwatch:\(scope.region):\(scope.accountID):alarm:\(alarm.name)" else {
            throw AlarmError.invalidResponse
        }
    }

    private static func map(_ alarm: CloudWatch.MetricAlarm) throws -> CloudWatchAlarm {
        guard let arn = alarm.alarmArn, let name = alarm.alarmName else { throw AlarmError.invalidResponse }
        if let threshold = alarm.threshold, !threshold.isFinite { throw AlarmError.invalidResponse }
        let configuration: [(String, String?)] = [
            ("Namespace", alarm.namespace), ("Metric", alarm.metricName),
            ("Statistic", alarm.statistic?.rawValue), ("Extended statistic", alarm.extendedStatistic),
            ("Period (seconds)", alarm.period.map(String.init)), ("Unit", alarm.unit?.rawValue),
            ("Threshold", alarm.threshold.map { String($0) }), ("Comparison", alarm.comparisonOperator?.rawValue),
            ("Evaluation periods", alarm.evaluationPeriods.map(String.init)),
            ("Datapoints to alarm", alarm.datapointsToAlarm.map(String.init)),
            ("Treat missing data", alarm.treatMissingData),
            ("Low sample count", alarm.evaluateLowSampleCountPercentile),
            ("Evaluation state", alarm.evaluationState?.rawValue), ("Threshold metric ID", alarm.thresholdMetricId)
        ]
        var queries: [AlarmMetricQuery] = []
        var queryIDs: Set<String> = []
        for query in alarm.metrics ?? [] {
            guard let id = query.id, !id.isEmpty, queryIDs.insert(id).inserted else { throw AlarmError.invalidResponse }
            queries.append(AlarmMetricQuery(
                id: id, label: query.label, expression: query.expression, accountID: query.accountId,
                returnData: query.returnData, namespace: query.metricStat?.metric?.namespace,
                metricName: query.metricStat?.metric?.metricName,
                dimensions: try properties(query.metricStat?.metric?.dimensions ?? []),
                statistic: query.metricStat?.stat, period: query.period ?? query.metricStat?.period,
                unit: query.metricStat?.unit?.rawValue
            ))
        }
        if queries.isEmpty, alarm.metricName != nil || alarm.namespace != nil || alarm.dimensions?.isEmpty == false {
            queries = [AlarmMetricQuery(
                id: "single-metric", namespace: alarm.namespace, metricName: alarm.metricName,
                dimensions: try properties(alarm.dimensions ?? []),
                statistic: alarm.statistic?.rawValue ?? alarm.extendedStatistic, period: alarm.period, unit: alarm.unit?.rawValue
            )]
        }
        return CloudWatchAlarm(
            arn: arn, name: name, kind: .metric, state: alarm.stateValue?.rawValue ?? "Unknown",
            description: alarm.alarmDescription, reason: alarm.stateReason, reasonData: alarm.stateReasonData,
            stateUpdatedAt: alarm.stateUpdatedTimestamp, stateTransitionedAt: alarm.stateTransitionedTimestamp,
            configurationUpdatedAt: alarm.alarmConfigurationUpdatedTimestamp, actionsEnabled: alarm.actionsEnabled,
            alarmActions: alarm.alarmActions ?? [], okActions: alarm.okActions ?? [],
            insufficientDataActions: alarm.insufficientDataActions ?? [],
            configuration: configuration.compactMap { label, value in value.map { AlarmProperty(label: label, value: $0) } },
            metrics: queries
        )
    }

    private static func map(_ alarm: CloudWatch.CompositeAlarm) throws -> CloudWatchAlarm {
        guard let arn = alarm.alarmArn, let name = alarm.alarmName else { throw AlarmError.invalidResponse }
        let configuration: [(String, String?)] = [
            ("Actions suppressor", alarm.actionsSuppressor),
            ("Suppression wait (seconds)", alarm.actionsSuppressorWaitPeriod.map(String.init)),
            ("Suppression extension (seconds)", alarm.actionsSuppressorExtensionPeriod.map(String.init)),
            ("Actions suppressed by", alarm.actionsSuppressedBy?.rawValue),
            ("Suppression reason", alarm.actionsSuppressedReason)
        ]
        return CloudWatchAlarm(
            arn: arn, name: name, kind: .composite, state: alarm.stateValue?.rawValue ?? "Unknown",
            description: alarm.alarmDescription, reason: alarm.stateReason, reasonData: alarm.stateReasonData,
            stateUpdatedAt: alarm.stateUpdatedTimestamp, stateTransitionedAt: alarm.stateTransitionedTimestamp,
            configurationUpdatedAt: alarm.alarmConfigurationUpdatedTimestamp, actionsEnabled: alarm.actionsEnabled,
            alarmActions: alarm.alarmActions ?? [], okActions: alarm.okActions ?? [],
            insufficientDataActions: alarm.insufficientDataActions ?? [],
            configuration: configuration.compactMap { label, value in value.map { AlarmProperty(label: label, value: $0) } },
            rule: alarm.alarmRule
        )
    }

    private static func properties(_ dimensions: [CloudWatch.Dimension]) throws -> [AlarmProperty] {
        var names: Set<String> = []
        return try dimensions.map { dimension in
            guard let name = dimension.name, !name.isEmpty, let value = dimension.value,
                  names.insert(name).inserted else { throw AlarmError.invalidResponse }
            return AlarmProperty(label: name, value: value)
        }.sorted { $0.label < $1.label }
    }

    private enum Operation { case list, tags, history }

    private static func sanitized(_ error: Error, operation: Operation) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? AlarmError { return error }
        if error is AWSServiceError { return AlarmError.invalidScope }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedException", "ForbiddenException"].contains(code) {
            switch operation {
            case .list: return RequestError.listPermission
            case .tags: return RequestError.tagsPermission
            case .history: return RequestError.historyPermission
            }
        }
        if UserFacingError.requiresSSOLogin(error) { return RequestError.credentials }
        if error is URLError { return RequestError.network }
        switch code {
        case "Throttling", "ThrottlingException", "TooManyRequestsException", "LimitExceededException":
            return RequestError.throttled
        case "InvalidNextToken", "InvalidNextTokenException":
            return AlarmError.incompletePagination
        default: return RequestError.failed
        }
    }

    enum RequestError: LocalizedError, Equatable {
        case listPermission, tagsPermission, historyPermission, credentials, network, throttled, failed

        var errorDescription: String? {
            switch self {
            case .listPermission:
                return "CloudWatch alarm access was denied. Check cloudwatch:DescribeAlarms. Reading composite alarms requires this action with Resource: *."
            case .tagsPermission:
                return "Alarm tags could not be read. Check cloudwatch:ListTagsForResource permission for this alarm ARN."
            case .historyPermission:
                return "Alarm history could not be read. Check cloudwatch:DescribeAlarmHistory. Reading composite alarm history requires this action with Resource: *."
            case .credentials:
                return "AWS credentials expired or are unavailable. Sign in to the session, select the profile again, then reload alarms."
            case .network:
                return "Unable to reach CloudWatch. Check your network or proxy, then refresh."
            case .throttled:
                return "CloudWatch is limiting requests. Wait a moment, then refresh manually."
            case .failed:
                return "The CloudWatch request failed. Check the selected profile, region and service availability, then refresh."
            }
        }
    }
}
