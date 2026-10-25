import Foundation
import SotoCore
import SotoCloudWatchLogs

struct AWSLogsService: Sendable {
    typealias StreamLoader = @Sendable (CloudWatchLogs.DescribeLogStreamsRequest) async throws -> CloudWatchLogs.DescribeLogStreamsResponse
    typealias EventLoader = @Sendable (CloudWatchLogs.FilterLogEventsRequest) async throws -> CloudWatchLogs.FilterLogEventsResponse

    private struct Operations: Sendable {
        let streams: StreamLoader
        let events: EventLoader
    }

    private let provider: AWSServiceProvider?
    private let injected: Operations?
    static let pageSize = 500
    private static let maximumStreamPages = 100
    private static let maximumEventPages = 1_000
    private static let requestsPerLoad = 3

    init(provider: AWSServiceProvider) {
        self.provider = provider
        injected = nil
    }

    init(streamLoader: @escaping StreamLoader, eventLoader: @escaping EventLoader) {
        provider = nil
        injected = Operations(streams: streamLoader, events: eventLoader)
    }

    func load(query: LambdaLogQuery, cursor: LambdaLogCursor?) async throws -> LambdaLogPage {
        do {
            try Task.checkCancellation()
            guard query.isValid else { throw LambdaLogsError.invalidQuery }
            if let cursor { try Self.validate(cursor, query: query) }
            let operations = try await operations(scope: query.scope)
            let batches: [[String]]?
            if let cursor {
                batches = cursor.streamBatches
            } else if query.context.isCustomGroup {
                batches = try await streamBatches(query: query, loader: operations.streams)
            } else {
                batches = nil
            }
            if batches?.isEmpty == true { return LambdaLogPage(query: query, events: [], cursor: nil) }

            var index = cursor?.batchIndex ?? 0
            var token = cursor?.nextToken
            var seen = cursor?.seenTokens ?? []
            var pagesRead = cursor?.pagesRead ?? 0
            var result: [String: LambdaLogEvent] = [:]
            for _ in 0..<Self.requestsPerLoad {
                try Task.checkCancellation()
                guard pagesRead < Self.maximumEventPages else { throw LambdaLogsError.incompletePagination }
                let names = batches.map { $0[index] }
                let response: CloudWatchLogs.FilterLogEventsResponse
                do {
                    response = try await operations.events(.init(
                        endTime: query.endMilliseconds,
                        filterPattern: query.filterPattern.isEmpty ? nil : query.filterPattern,
                        limit: Self.pageSize, logGroupName: query.context.logGroup,
                        logStreamNames: names, nextToken: token,
                        startTime: query.startMilliseconds, unmask: false
                    ))
                } catch { throw Self.sanitized(error, readingStreams: false) }
                try Task.checkCancellation()
                pagesRead += 1
                guard (response.events?.count ?? 0) <= Self.pageSize else { throw LambdaLogsError.invalidResponse }
                for item in response.events ?? [] {
                    let event = try Self.event(item, query: query, permittedStreams: names)
                    result[event.id] = event
                }
                if let next = response.nextToken {
                    guard !next.isEmpty, seen.insert(next).inserted else { throw LambdaLogsError.incompletePagination }
                    token = next
                } else if let batches, index + 1 < batches.count {
                    index += 1
                    token = nil
                    seen = []
                } else {
                    return LambdaLogPage(query: query, events: Self.sorted(result.values), cursor: nil)
                }
                if !result.isEmpty { break }
            }
            return LambdaLogPage(
                query: query, events: Self.sorted(result.values),
                cursor: LambdaLogCursor(query: query, streamBatches: batches, batchIndex: index,
                                        nextToken: token, seenTokens: seen, pagesRead: pagesRead)
            )
        } catch { throw Self.sanitized(error, readingStreams: false) }
    }

    private func streamBatches(query: LambdaLogQuery, loader: StreamLoader) async throws -> [[String]] {
        var names: Set<String> = []
        var token: String?
        var seen: Set<String> = []
        do {
            for _ in 0..<Self.maximumStreamPages {
                try Task.checkCancellation()
                let response = try await loader(.init(limit: 50, logGroupName: query.context.logGroup, nextToken: token))
                try Task.checkCancellation()
                for stream in response.logStreams ?? [] {
                    guard let name = stream.logStreamName, !name.isEmpty, name.count <= 512 else {
                        throw LambdaLogsError.invalidResponse
                    }
                    if query.context.ownsCustomStream(name) { names.insert(name) }
                }
                guard let next = response.nextToken else {
                    let sorted = names.sorted()
                    return stride(from: 0, to: sorted.count, by: 100).map {
                        Array(sorted[$0..<min($0 + 100, sorted.count)])
                    }
                }
                guard !next.isEmpty, seen.insert(next).inserted else { throw LambdaLogsError.streamEnumerationLimit }
                token = next
            }
            throw LambdaLogsError.streamEnumerationLimit
        } catch { throw Self.sanitized(error, readingStreams: true) }
    }

    private func operations(scope: MonitoringScope) async throws -> Operations {
        try Task.checkCancellation()
        if let injected { return injected }
        guard let provider else { throw LambdaLogsError.invalidQuery }
        let client = try await provider.cloudWatchLogsClient(profile: scope.profile, paths: scope.paths, region: scope.region)
        return Operations(streams: { try await client.describeLogStreams($0) }, events: { try await client.filterLogEvents($0) })
    }

    private static func validate(_ cursor: LambdaLogCursor, query: LambdaLogQuery) throws {
        guard cursor.query == query, cursor.pagesRead > 0, cursor.pagesRead <= maximumEventPages,
              cursor.nextToken == nil || (cursor.nextToken?.isEmpty == false && cursor.seenTokens.contains(cursor.nextToken!)),
              cursor.seenTokens.count <= cursor.pagesRead else { throw LambdaLogsError.invalidCursor }
        if query.context.isCustomGroup {
            guard let batches = cursor.streamBatches, !batches.isEmpty,
                  batches.indices.contains(cursor.batchIndex),
                  batches.allSatisfy({ !$0.isEmpty && $0.count <= 100 && $0.allSatisfy(query.context.ownsCustomStream) })
            else { throw LambdaLogsError.invalidCursor }
        } else {
            guard cursor.streamBatches == nil, cursor.batchIndex == 0, cursor.nextToken != nil else {
                throw LambdaLogsError.invalidCursor
            }
        }
    }

    private static func event(_ item: CloudWatchLogs.FilteredLogEvent, query: LambdaLogQuery, permittedStreams: [String]?) throws -> LambdaLogEvent {
        guard let id = item.eventId, !id.isEmpty, let timestamp = item.timestamp,
              timestamp >= query.startMilliseconds, timestamp <= query.endMilliseconds,
              let stream = item.logStreamName, !stream.isEmpty,
              permittedStreams == nil || (permittedStreams!.contains(stream) && query.context.ownsCustomStream(stream)),
              item.ingestionTime == nil || item.ingestionTime! >= 0 else { throw LambdaLogsError.invalidResponse }
        return LambdaLogEvent(id: id, timestamp: Date(timeIntervalSince1970: Double(timestamp) / 1_000),
                              ingestionTime: item.ingestionTime.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
                              streamName: stream, message: item.message ?? "")
    }

    static func sorted(_ events: some Sequence<LambdaLogEvent>) -> [LambdaLogEvent] {
        events.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            if $0.ingestionTime != $1.ingestionTime { return ($0.ingestionTime ?? .distantPast) > ($1.ingestionTime ?? .distantPast) }
            return $0.id < $1.id
        }
    }

    static func sanitized(_ error: Error, readingStreams: Bool = false) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? LambdaLogsError { return error }
        if error is AWSServiceError { return LambdaLogsError.invalidQuery }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedException", "ForbiddenException"].contains(code) {
            return readingStreams ? LambdaLogsError.streamPermission : LambdaLogsError.filterPermission
        }
        if UserFacingError.requiresSSOLogin(error) { return LambdaLogsError.credentials }
        if error is URLError { return LambdaLogsError.network }
        switch code {
        case "Throttling", "ThrottlingException", "TooManyRequestsException": return LambdaLogsError.throttled
        case "InvalidNextToken", "InvalidNextTokenException": return LambdaLogsError.invalidCursor
        case "ResourceNotFound", "ResourceNotFoundException": return LambdaLogsError.notFound
        case "InvalidParameterException": return LambdaLogsError.invalidPattern
        default: return LambdaLogsError.failed
        }
    }
}
