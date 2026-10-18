import Foundation

struct CloudWatchLogGroup: Identifiable, Hashable, Sendable {
    let arn: String
    let name: String
    let createdAt: Date?
    let retentionDays: Int?
    let storedBytes: Int64?
    let logClass: String?
    let kmsKeyID: String?
    var id: String { arn }
}

struct CloudWatchLogStream: Identifiable, Hashable, Sendable {
    let name: String
    let createdAt: Date?
    let firstEventAt: Date?
    let lastEventAt: Date?
    var id: Data { Data(name.utf8) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.createdAt == rhs.createdAt && lhs.firstEventAt == rhs.firstEventAt && lhs.lastEventAt == rhs.lastEventAt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(createdAt); hasher.combine(firstEventAt); hasher.combine(lastEventAt)
    }
}

struct CloudWatchLogsBrowserQuery: Hashable, Sendable {
    let scope: MonitoringScope
    let group: CloudWatchLogGroup
    let streamName: String?
    let startTime: Date
    let endTime: Date
    let filterPattern: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.group == rhs.group && lhs.startTime == rhs.startTime && lhs.endTime == rhs.endTime &&
            lhs.streamName.map { Data($0.utf8) } == rhs.streamName.map { Data($0.utf8) } &&
            Data(lhs.filterPattern.utf8) == Data(rhs.filterPattern.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(scope); hasher.combine(group); hasher.combine(startTime); hasher.combine(endTime)
        hasher.combine(streamName.map { Data($0.utf8) }); hasher.combine(Data(filterPattern.utf8))
    }

    var isValid: Bool {
        let start = startTime.timeIntervalSince1970
        let end = endTime.timeIntervalSince1970
        return scope.isValid && Self.owns(group: group, scope: scope) &&
            start.isFinite && end.isFinite && start >= 0 && end > start && end - start <= 86_400 &&
            end < Double(Int64.max / 1_000) && filterPattern.count <= 1_024 && !filterPattern.contains("\0") &&
            (streamName == nil || Self.validStream(streamName!))
    }

    var startMilliseconds: Int64 { Int64((startTime.timeIntervalSince1970 * 1_000).rounded(.down)) }
    var endMilliseconds: Int64 { Int64((endTime.timeIntervalSince1970 * 1_000).rounded(.down)) }

    static func owns(group: CloudWatchLogGroup, scope: MonitoringScope) -> Bool {
        guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty,
              (1...512).contains(group.name.count),
              group.name.range(of: "^[.\\-_/#A-Za-z0-9]+$", options: .regularExpression) != nil else { return false }
        let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
        return group.arn == "arn:\(partition):logs:\(scope.region):\(scope.accountID):log-group:\(group.name)"
    }

    static func validStream(_ name: String) -> Bool {
        (1...512).contains(name.count) && !name.contains(":") && !name.contains("*")
    }
}

struct CloudWatchLogsBrowserCursor: Hashable, Sendable {
    let query: CloudWatchLogsBrowserQuery
    let nextToken: String
    let seenTokens: Set<String>
    let pagesRead: Int
}

struct CloudWatchLogsBrowserPage: Sendable {
    let query: CloudWatchLogsBrowserQuery
    let events: [LambdaLogEvent]
    let cursor: CloudWatchLogsBrowserCursor?
}

enum CloudWatchLogsBrowserError: LocalizedError, Equatable {
    case invalidScope, invalidResponse, invalidCursor, incompletePagination, permission, failed

    var errorDescription: String? {
        switch self {
        case .invalidScope: return "Select a verified profile and a log group in the current account and region."
        case .invalidResponse: return "CloudWatch Logs returned incomplete or mismatched data. Reload to try again."
        case .invalidCursor: return "This log page no longer matches the search. Run a new search."
        case .incompletePagination: return "The log pagination limit was reached. Narrow the search and reload."
        case .permission: return "Log access was denied. Check logs:DescribeLogGroups, logs:DescribeLogStreams and logs:FilterLogEvents permissions."
        case .failed: return "Unable to read CloudWatch Logs. Check the profile, region, network and permissions, then retry."
        }
    }
}
