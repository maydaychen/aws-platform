import Foundation
import SotoCore
import SotoCloudWatchLogs

struct AWSCloudWatchLogsBrowserService: Sendable {
    typealias GroupLoader = @Sendable (CloudWatchLogs.DescribeLogGroupsRequest) async throws -> CloudWatchLogs.DescribeLogGroupsResponse
    typealias StreamLoader = @Sendable (CloudWatchLogs.DescribeLogStreamsRequest) async throws -> CloudWatchLogs.DescribeLogStreamsResponse
    typealias EventLoader = @Sendable (CloudWatchLogs.FilterLogEventsRequest) async throws -> CloudWatchLogs.FilterLogEventsResponse

    private struct Operations: Sendable {
        let groups: GroupLoader
        let streams: StreamLoader
        let events: EventLoader
    }
    private let provider: AWSServiceProvider?
    private let injected: Operations?
    static let pageSize = 500

    init(provider: AWSServiceProvider) { self.provider = provider; injected = nil }
    init(groupLoader: @escaping GroupLoader, streamLoader: @escaping StreamLoader, eventLoader: @escaping EventLoader) {
        provider = nil
        injected = Operations(groups: groupLoader, streams: streamLoader, events: eventLoader)
    }

    func loadGroups(scope: MonitoringScope) async throws -> [CloudWatchLogGroup] {
        do {
            let operations = try await operations(scope: scope)
            let groups = try await Self.pages { token in
                let response = try await operations.groups(.init(includeLinkedAccounts: false, limit: 50, nextToken: token))
                let rows = try (response.logGroups ?? []).map { raw -> CloudWatchLogGroup in
                    guard let name = raw.logGroupName else { throw CloudWatchLogsBrowserError.invalidResponse }
                    let arn = raw.logGroupArn ?? raw.arn.map { $0.hasSuffix(":*") ? String($0.dropLast(2)) : $0 }
                    guard let arn else { throw CloudWatchLogsBrowserError.invalidResponse }
                    let group = CloudWatchLogGroup(arn: arn, name: name, createdAt: try Self.date(raw.creationTime),
                        retentionDays: raw.retentionInDays, storedBytes: raw.storedBytes,
                        logClass: raw.logGroupClass?.rawValue, kmsKeyID: raw.kmsKeyId)
                    guard CloudWatchLogsBrowserQuery.owns(group: group, scope: scope),
                          raw.arn == nil || raw.arn == arn || raw.arn == arn + ":*",
                          raw.storedBytes == nil || raw.storedBytes! >= 0,
                          raw.retentionInDays == nil || raw.retentionInDays! > 0 else {
                        throw CloudWatchLogsBrowserError.invalidResponse
                    }
                    return group
                }
                guard rows.count <= 50 else { throw CloudWatchLogsBrowserError.invalidResponse }
                return (rows, response.nextToken)
            }
            guard Set(groups.map(\.arn)).count == groups.count else { throw CloudWatchLogsBrowserError.invalidResponse }
            return groups.sorted { $0.name < $1.name }
        } catch { throw Self.sanitized(error) }
    }

    func loadStreams(scope: MonitoringScope, group: CloudWatchLogGroup) async throws -> [CloudWatchLogStream] {
        do {
            guard CloudWatchLogsBrowserQuery.owns(group: group, scope: scope) else { throw CloudWatchLogsBrowserError.invalidScope }
            let operations = try await operations(scope: scope)
            let streams = try await Self.pages { token in
                let response = try await operations.streams(.init(limit: 50, logGroupName: group.name, nextToken: token))
                let rows = try (response.logStreams ?? []).map { raw -> CloudWatchLogStream in
                    guard let name = raw.logStreamName, CloudWatchLogsBrowserQuery.validStream(name),
                          raw.arn == nil || raw.arn.map({ Data($0.utf8) }) == Data((group.arn + ":log-stream:" + name).utf8) else {
                        throw CloudWatchLogsBrowserError.invalidResponse
                    }
                    return CloudWatchLogStream(name: name, createdAt: try Self.date(raw.creationTime),
                        firstEventAt: try Self.date(raw.firstEventTimestamp), lastEventAt: try Self.date(raw.lastEventTimestamp))
                }
                guard rows.count <= 50 else { throw CloudWatchLogsBrowserError.invalidResponse }
                return (rows, response.nextToken)
            }
            guard Set(streams.map(\.id)).count == streams.count else { throw CloudWatchLogsBrowserError.invalidResponse }
            return streams.sorted { $0.id.lexicographicallyPrecedes($1.id) }
        } catch { throw Self.sanitized(error) }
    }

    func loadEvents(query: CloudWatchLogsBrowserQuery, cursor: CloudWatchLogsBrowserCursor?) async throws -> CloudWatchLogsBrowserPage {
        do {
            guard query.isValid else { throw CloudWatchLogsBrowserError.invalidScope }
            if let cursor {
                guard cursor.query == query, (1..<1_000).contains(cursor.pagesRead),
                      !cursor.nextToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      cursor.seenTokens.contains(cursor.nextToken), cursor.seenTokens.count == cursor.pagesRead else {
                    throw CloudWatchLogsBrowserError.invalidCursor
                }
            }
            let operations = try await operations(scope: query.scope)
            let response = try await operations.events(.init(endTime: query.endMilliseconds,
                filterPattern: query.filterPattern.isEmpty ? nil : query.filterPattern, limit: Self.pageSize,
                logGroupName: query.group.name, logStreamNames: query.streamName.map { [$0] },
                nextToken: cursor?.nextToken, startTime: query.startMilliseconds, unmask: false))
            try Task.checkCancellation()
            guard (response.events?.count ?? 0) <= Self.pageSize else { throw CloudWatchLogsBrowserError.invalidResponse }
            let events = try (response.events ?? []).map { raw -> LambdaLogEvent in
                guard let id = raw.eventId, !id.isEmpty, let timestamp = raw.timestamp,
                      timestamp >= query.startMilliseconds, timestamp <= query.endMilliseconds,
                      let name = raw.logStreamName, CloudWatchLogsBrowserQuery.validStream(name),
                      query.streamName == nil || query.streamName.map({ Data($0.utf8) }) == Data(name.utf8) else {
                    throw CloudWatchLogsBrowserError.invalidResponse
                }
                return LambdaLogEvent(id: id, timestamp: Date(timeIntervalSince1970: Double(timestamp) / 1_000),
                    ingestionTime: try Self.date(raw.ingestionTime), streamName: name, message: raw.message ?? "")
            }
            guard Set(events.map(\.id)).count == events.count else { throw CloudWatchLogsBrowserError.invalidResponse }
            var next: CloudWatchLogsBrowserCursor?
            if let token = response.nextToken {
                var seen = cursor?.seenTokens ?? []
                let pages = (cursor?.pagesRead ?? 0) + 1
                guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      seen.insert(token).inserted, pages < 1_000 else { throw CloudWatchLogsBrowserError.incompletePagination }
                next = .init(query: query, nextToken: token, seenTokens: seen, pagesRead: pages)
            }
            return .init(query: query, events: AWSLogsService.sorted(events), cursor: next)
        } catch { throw Self.sanitized(error) }
    }

    private func operations(scope: MonitoringScope) async throws -> Operations {
        try Task.checkCancellation()
        guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty else { throw CloudWatchLogsBrowserError.invalidScope }
        if let injected { return injected }
        guard let provider else { throw CloudWatchLogsBrowserError.invalidScope }
        let client = try await provider.cloudWatchLogsClient(scope: scope)
        try Task.checkCancellation()
        return .init(groups: { try await client.describeLogGroups($0) }, streams: { try await client.describeLogStreams($0) },
                     events: { try await client.filterLogEvents($0) })
    }

    private static func pages<T: Sendable>(_ loader: @Sendable (String?) async throws -> ([T], String?)) async throws -> [T] {
        var token: String?
        var seen: Set<String> = []
        var result: [T] = []
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            let (rows, next) = try await loader(token)
            try Task.checkCancellation()
            result += rows
            guard let next else { return result }
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(next).inserted else { throw CloudWatchLogsBrowserError.incompletePagination }
            token = next
        }
        throw CloudWatchLogsBrowserError.incompletePagination
    }

    private static func date(_ value: Int64?) throws -> Date? {
        guard let value else { return nil }
        guard value >= 0 else { throw CloudWatchLogsBrowserError.invalidResponse }
        return Date(timeIntervalSince1970: Double(value) / 1_000)
    }

    static func sanitized(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? CloudWatchLogsBrowserError { return error }
        if error is AWSServiceError { return CloudWatchLogsBrowserError.invalidScope }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedException", "ForbiddenException"].contains(code) {
            return CloudWatchLogsBrowserError.permission
        }
        return CloudWatchLogsBrowserError.failed
    }
}
