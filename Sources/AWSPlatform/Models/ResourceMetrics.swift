import Foundation

enum ResourceMetricTarget: Hashable, Sendable {
    case ec2(String)
    case lambda(String)

    var resourceID: String {
        switch self {
        case .ec2(let id), .lambda(let id): return id
        }
    }

    var isValid: Bool {
        guard !resourceID.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return false }
        let pattern: String
        switch self {
        case .ec2: pattern = "^i-(?:[0-9a-f]{8}|[0-9a-f]{17})$"
        case .lambda: pattern = "^[A-Za-z0-9_-]{1,64}$"
        }
        return resourceID.range(of: pattern, options: .regularExpression) != nil
    }
}

struct ResourceMetricPoint: Identifiable, Hashable, Sendable {
    let timestamp: Date
    let value: Double

    var id: Date { timestamp }
}

enum ResourceMetricStatus: String, Hashable, Sendable {
    case complete, partial, forbidden, missing, failed

    var isComplete: Bool { self == .complete }

    var title: String {
        switch self {
        case .complete: return "Complete"
        case .partial: return "Partial data"
        case .forbidden: return "Access denied"
        case .missing: return "No result"
        case .failed: return "Metric failed"
        }
    }
}

struct ResourceMetricSeries: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let unit: String
    let statistic: String
    let points: [ResourceMetricPoint]
    let status: ResourceMetricStatus
    let message: String?

    var isComplete: Bool { status.isComplete }

    init(
        id: String, title: String, unit: String, statistic: String,
        points: [ResourceMetricPoint], status: ResourceMetricStatus, message: String? = nil
    ) {
        self.id = id
        self.title = title
        self.unit = unit
        self.statistic = statistic
        self.points = points
        self.status = status
        self.message = message
    }
}

struct ResourceMetricsSnapshot: Hashable, Sendable {
    let target: ResourceMetricTarget
    let range: MonitoringTimeRange
    let start: Date
    let end: Date
    let period: Int
    let series: [ResourceMetricSeries]
    let fetchedAt: Date

    var isComplete: Bool { !series.isEmpty && series.allSatisfy(\.isComplete) }

    init(
        target: ResourceMetricTarget, range: MonitoringTimeRange, start: Date, end: Date,
        period: Int = 300, series: [ResourceMetricSeries], fetchedAt: Date
    ) {
        self.target = target
        self.range = range
        self.start = start
        self.end = end
        self.period = period
        self.series = series
        self.fetchedAt = fetchedAt
    }
}

enum ResourceMetricsError: LocalizedError {
    case invalidContext, invalidResponse, incompletePagination

    var errorDescription: String? {
        switch self {
        case .invalidContext:
            return "Select a verified profile, region and valid resource before loading metrics."
        case .invalidResponse:
            return "CloudWatch returned inconsistent metric data. Refresh to try again."
        case .incompletePagination:
            return "The complete metric response could not be retrieved. Refresh to start a new request."
        }
    }
}
