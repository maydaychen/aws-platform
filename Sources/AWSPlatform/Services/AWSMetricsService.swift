import Foundation
import SotoCore
import SotoCloudWatch

struct AWSMetricsService: Sendable {
    typealias PageLoader = @Sendable (CloudWatch.GetMetricDataInput) async throws -> CloudWatch.GetMetricDataOutput

    private let provider: AWSServiceProvider?
    private let pageLoader: PageLoader?
    private let now: @Sendable () -> Date
    private static let period = 300
    private static let maximumPages = 100

    init(provider: AWSServiceProvider) {
        self.provider = provider
        pageLoader = nil
        now = { Date() }
    }

    init(pageLoader: @escaping PageLoader, now: @escaping @Sendable () -> Date = { Date() }) {
        provider = nil
        self.pageLoader = pageLoader
        self.now = now
    }

    func load(
        scope: MonitoringScope, target: ResourceMetricTarget, range: MonitoringTimeRange
    ) async throws -> ResourceMetricsSnapshot {
        do {
            try Task.checkCancellation()
            guard scope.isValid, target.isValid else { throw ResourceMetricsError.invalidContext }
            let capturedNow = now().timeIntervalSince1970
            guard capturedNow.isFinite else { throw ResourceMetricsError.invalidContext }
            let end = Date(timeIntervalSince1970: floor(capturedNow / Double(Self.period)) * Double(Self.period))
            let start = end.addingTimeInterval(-range.duration)
            let loader: PageLoader
            if let pageLoader {
                loader = pageLoader
            } else if let provider {
                let client = try await provider.cloudWatchClient(profile: scope.profile, paths: scope.paths, region: scope.region)
                loader = { try await client.getMetricData($0) }
            } else {
                throw ResourceMetricsError.invalidContext
            }
            let definitions = Self.definitions(for: target)
            let queries = definitions.map { definition in
                CloudWatch.MetricDataQuery(
                    accountId: scope.accountID, id: definition.id,
                    metricStat: .init(
                        metric: .init(dimensions: [.init(name: definition.dimension, value: target.resourceID)],
                                      metricName: definition.metric, namespace: definition.namespace),
                        period: Self.period, stat: definition.statistic
                    ), returnData: true
                )
            }
            var results = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, Accumulator()) })
            var token: String?
            var seenTokens: Set<String> = []
            var hasGlobalWarning = false

            for _ in 0..<Self.maximumPages {
                try Task.checkCancellation()
                let response = try await loader(.init(
                    endTime: end, maxDatapoints: 100_800, metricDataQueries: queries,
                    nextToken: token, scanBy: .timestampAscending, startTime: start
                ))
                try Task.checkCancellation()
                hasGlobalWarning = hasGlobalWarning || response.messages?.isEmpty == false
                var pageIDs: Set<String> = []
                for result in response.metricDataResults ?? [] {
                    guard let id = result.id, results[id] != nil, pageIDs.insert(id).inserted else {
                        throw ResourceMetricsError.invalidResponse
                    }
                    try results[id]?.merge(result, start: start, end: end)
                }
                guard let next = response.nextToken, !next.isEmpty else {
                    let series = definitions.map { definition in
                        let result = results[definition.id] ?? Accumulator()
                        let status = result.finalStatus(globalWarning: hasGlobalWarning)
                        let points = result.points.sorted { $0.key < $1.key }
                            .map { ResourceMetricPoint(timestamp: $0.key, value: $0.value) }
                        return ResourceMetricSeries(
                            id: definition.id, title: definition.title, unit: definition.unit.rawValue,
                            statistic: definition.statistic, points: points, status: status,
                            message: Self.message(status: status, empty: points.isEmpty)
                        )
                    }
                    try Task.checkCancellation()
                    return ResourceMetricsSnapshot(
                        target: target, range: range, start: start, end: end, period: Self.period,
                        series: series, fetchedAt: now()
                    )
                }
                guard seenTokens.insert(next).inserted else { throw ResourceMetricsError.incompletePagination }
                token = next
            }
            throw ResourceMetricsError.incompletePagination
        } catch {
            throw Self.sanitized(error)
        }
    }

    static func userMessage(for error: Error) -> String {
        sanitized(error).localizedDescription
    }

    private struct Definition {
        let id: String
        let title: String
        let namespace: String
        let metric: String
        let dimension: String
        let statistic: String
        let unit: CloudWatch.StandardUnit
    }

    private static func definitions(for target: ResourceMetricTarget) -> [Definition] {
        switch target {
        case .ec2:
            return [
                .init(id: "cpu", title: "CPU utilization", namespace: "AWS/EC2", metric: "CPUUtilization",
                      dimension: "InstanceId", statistic: "Average", unit: .percent),
                .init(id: "network_in", title: "Network in", namespace: "AWS/EC2", metric: "NetworkIn",
                      dimension: "InstanceId", statistic: "Sum", unit: .bytes),
                .init(id: "network_out", title: "Network out", namespace: "AWS/EC2", metric: "NetworkOut",
                      dimension: "InstanceId", statistic: "Sum", unit: .bytes),
                .init(id: "status_failed", title: "Failed status checks", namespace: "AWS/EC2", metric: "StatusCheckFailed",
                      dimension: "InstanceId", statistic: "Maximum", unit: .count)
            ]
        case .lambda:
            return [
                .init(id: "invocations", title: "Invocations", namespace: "AWS/Lambda", metric: "Invocations",
                      dimension: "FunctionName", statistic: "Sum", unit: .count),
                .init(id: "errors", title: "Errors", namespace: "AWS/Lambda", metric: "Errors",
                      dimension: "FunctionName", statistic: "Sum", unit: .count),
                .init(id: "throttles", title: "Throttles", namespace: "AWS/Lambda", metric: "Throttles",
                      dimension: "FunctionName", statistic: "Sum", unit: .count),
                .init(id: "duration", title: "Average duration", namespace: "AWS/Lambda", metric: "Duration",
                      dimension: "FunctionName", statistic: "Average", unit: .milliseconds)
            ]
        }
    }

    private struct Accumulator {
        var points: [Date: Double] = [:]
        var status: ResourceMetricStatus?
        var hasWarning = false
        var hasUnknownStatus = false
        var wasReturned = false

        mutating func merge(_ result: CloudWatch.MetricDataResult, start: Date, end: Date) throws {
            wasReturned = true
            hasWarning = hasWarning || result.messages?.isEmpty == false
            switch result.statusCode {
            case .forbidden: status = .forbidden
            case .internalError:
                if status != .forbidden { status = .failed }
            case .partialData:
                if status != .forbidden && status != .failed { status = .partial }
            case .complete:
                if status != .forbidden && status != .failed { status = .complete }
            case nil: hasUnknownStatus = true
            }
            let timestamps = result.timestamps ?? []
            let values = result.values ?? []
            guard timestamps.count == values.count else { throw ResourceMetricsError.invalidResponse }
            for (timestamp, value) in zip(timestamps, values) {
                try Task.checkCancellation()
                guard timestamp.timeIntervalSince1970.isFinite, timestamp >= start, timestamp < end,
                      value.isFinite else { throw ResourceMetricsError.invalidResponse }
                if let existing = points[timestamp], existing != value { throw ResourceMetricsError.invalidResponse }
                points[timestamp] = value
            }
        }

        func finalStatus(globalWarning: Bool) -> ResourceMetricStatus {
            guard wasReturned else { return .missing }
            if status == .forbidden || status == .failed { return status ?? .failed }
            if hasUnknownStatus || hasWarning || globalWarning { return .partial }
            return status ?? .partial
        }
    }

    private static func message(status: ResourceMetricStatus, empty: Bool) -> String? {
        switch status {
        case .complete:
            return empty ? "No datapoints were returned. Missing samples are not treated as zero." : nil
        case .partial:
            return "CloudWatch returned partial data or a warning. The result may be incomplete; refresh to retry."
        case .forbidden:
            return "CloudWatch did not authorize this metric. Check cloudwatch:GetMetricData and the selected account."
        case .missing:
            return "CloudWatch did not return a result for this metric."
        case .failed:
            return "CloudWatch reported a metric error. The result is incomplete; refresh to retry."
        }
    }

    private static func sanitized(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? ResourceMetricsError { return error }
        if let error = error as? RequestError { return error }
        if error is AWSServiceError { return ResourceMetricsError.invalidContext }
        if let error = error as? AlarmError, case .invalidScope = error {
            return ResourceMetricsError.invalidContext
        }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedException", "ForbiddenException"].contains(code) {
            return RequestError.permission
        }
        if UserFacingError.requiresSSOLogin(error) { return RequestError.credentials }
        if error is URLError { return RequestError.network }
        switch code {
        case "Throttling", "ThrottlingException", "TooManyRequestsException", "LimitExceededException":
            return RequestError.throttled
        case "InvalidNextToken", "InvalidNextTokenException":
            return ResourceMetricsError.incompletePagination
        default: return RequestError.failed
        }
    }

    enum RequestError: LocalizedError, Equatable {
        case permission, credentials, network, throttled, failed

        var errorDescription: String? {
            switch self {
            case .permission: return "Metric access was denied. Check cloudwatch:GetMetricData for the selected account and region."
            case .credentials: return "AWS credentials expired or are unavailable. Sign in, select the profile again, then reload metrics."
            case .network: return "Unable to reach CloudWatch. Check your network or proxy, then refresh metrics."
            case .throttled: return "CloudWatch is limiting metric requests. Wait a moment, then refresh manually."
            case .failed: return "The metric request failed. Check the selected resource, region and CloudWatch availability, then refresh."
            }
        }
    }
}
