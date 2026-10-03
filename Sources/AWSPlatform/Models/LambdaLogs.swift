import Foundation

struct LambdaLogContext: Hashable, Sendable {
    let functionName: String
    let configuredLogGroup: String?

    var logGroup: String { configuredLogGroup ?? "/aws/lambda/\(functionName)" }
    var isCustomGroup: Bool { logGroup != "/aws/lambda/\(functionName)" }
    var isValid: Bool {
        functionName.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil &&
            !functionName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
            (1...512).contains(logGroup.count) &&
            logGroup.range(of: "^[.\\-_/#A-Za-z0-9]+$", options: .regularExpression) != nil &&
            !logGroup.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    func ownsCustomStream(_ name: String) -> Bool {
        guard isValid, name.count <= 512,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: functionName)
        return name.range(
            of: "^[0-9]{4}/[0-9]{2}/[0-9]{2}/\(escaped)\\[[A-Za-z0-9_$-]+\\]\\[[A-Za-z0-9-]+\\]$",
            options: .regularExpression
        ) != nil
    }
}

struct LambdaLogQuery: Hashable, Sendable {
    let scope: MonitoringScope
    let context: LambdaLogContext
    let startTime: Date
    let endTime: Date
    let filterPattern: String

    var isValid: Bool {
        let start = startTime.timeIntervalSince1970
        let end = endTime.timeIntervalSince1970
        return scope.isValid && context.isValid && start.isFinite && end.isFinite &&
            start >= 0 && end > start && end - start <= 86_400 &&
            end < Double(Int64.max / 1_000) && filterPattern.count <= 1_024 &&
            !filterPattern.contains("\0")
    }

    var startMilliseconds: Int64 { Int64((startTime.timeIntervalSince1970 * 1_000).rounded(.down)) }
    var endMilliseconds: Int64 { Int64((endTime.timeIntervalSince1970 * 1_000).rounded(.down)) }
}

struct LambdaLogEvent: Identifiable, Hashable, Sendable {
    let id: String
    let timestamp: Date
    let ingestionTime: Date?
    let streamName: String
    let message: String
}

struct LambdaLogCursor: Hashable, Sendable {
    let query: LambdaLogQuery
    let streamBatches: [[String]]?
    let batchIndex: Int
    let nextToken: String?
    let seenTokens: Set<String>
    let pagesRead: Int
}

struct LambdaLogPage: Sendable {
    let query: LambdaLogQuery
    let events: [LambdaLogEvent]
    let cursor: LambdaLogCursor?
}

enum LambdaLogsError: LocalizedError, Equatable {
    case invalidQuery, invalidCursor, invalidResponse, incompletePagination, streamEnumerationLimit
    case streamPermission, filterPermission, credentials, network, throttled, notFound, invalidPattern, failed

    var errorDescription: String? {
        switch self {
        case .invalidQuery: return "Select a valid profile and function, and use a filter pattern of at most 1,024 characters."
        case .invalidCursor: return "The previous log search can no longer continue. Run a new search."
        case .invalidResponse: return "CloudWatch Logs returned an unexpected response. Run a new search."
        case .incompletePagination: return "The log search could not finish within its pagination limit. Narrow the time range or filter and search again."
        case .streamEnumerationLimit: return "Stream enumeration is incomplete or this shared log group is too large to enumerate safely. No shared-group events were read. Use a dedicated log group or inspect the shared group in CloudWatch Logs."
        case .streamPermission: return "Cannot isolate this function in its shared log group. Check logs:DescribeLogStreams permission; no shared-group events were read."
        case .filterPermission: return "Log access was denied. Check logs:FilterLogEvents permission for this log group."
        case .credentials: return "AWS credentials expired or are unavailable. Sign in to the session and select the profile again."
        case .network: return "Unable to reach CloudWatch Logs. Check your network, then retry."
        case .throttled: return "CloudWatch Logs is limiting requests. Wait a moment, then retry manually."
        case .notFound: return "The log group or stream was not found. The function may not have written logs yet."
        case .invalidPattern: return "CloudWatch Logs rejected this filter pattern. Check its filter-pattern syntax and search again."
        case .failed: return "Unable to read CloudWatch Logs. Check the selected profile, region and permissions, then retry."
        }
    }
}
