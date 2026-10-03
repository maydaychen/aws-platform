import Foundation
import SotoCore
import SotoHealth

struct AWSHealthService: Sendable {
    typealias EventLoader = @Sendable (Health.DescribeEventsRequest) async throws -> Health.DescribeEventsResponse
    typealias DetailLoader = @Sendable (Health.DescribeEventDetailsRequest) async throws -> Health.DescribeEventDetailsResponse
    typealias EntityLoader = @Sendable (Health.DescribeAffectedEntitiesRequest) async throws -> Health.DescribeAffectedEntitiesResponse

    private struct Operations: Sendable {
        let events: EventLoader
        let details: DetailLoader
        let entities: EntityLoader
    }

    private let provider: AWSServiceProvider?
    private let injected: Operations?
    private static let maximumPages = 100

    init(provider: AWSServiceProvider) {
        self.provider = provider
        injected = nil
    }

    init(eventLoader: @escaping EventLoader, detailLoader: @escaping DetailLoader, entityLoader: @escaping EntityLoader) {
        provider = nil
        injected = Operations(events: eventLoader, details: detailLoader, entities: entityLoader)
    }

    func loadEvents(scope: HealthScope) async throws -> [HealthEvent] {
        do {
            try Task.checkCancellation()
            let endpoint = try scope.endpoint()
            let operations = try await operations(scope: scope)
            var events: [HealthEvent] = []
            var eventIDs: Set<String> = []
            var token: String?
            var tokens: Set<String> = []
            for _ in 0..<Self.maximumPages {
                try Task.checkCancellation()
                // The account API also includes public events; it has no scope filter.
                let page = try await operations.events(.init(locale: "en", maxResults: 100, nextToken: token))
                try Task.checkCancellation()
                for raw in page.events ?? [] where raw.eventScopeCode == .accountSpecific {
                    let event = try Self.map(raw, scope: scope, partition: endpoint.partition)
                    guard eventIDs.insert(event.id).inserted else { throw HealthError.invalidResponse }
                    events.append(event)
                }
                guard let next = page.nextToken, !next.isEmpty else {
                    try Task.checkCancellation()
                    return events.sorted {
                        let first = $0.lastUpdatedTime ?? $0.startTime ?? .distantPast
                        let second = $1.lastUpdatedTime ?? $1.startTime ?? .distantPast
                        return first == second ? $0.arn < $1.arn : first > second
                    }
                }
                guard tokens.insert(next).inserted else { throw HealthError.incompletePagination }
                token = next
            }
            throw HealthError.incompletePagination
        } catch {
            throw Self.sanitized(error, operation: .events)
        }
    }

    func loadDetails(scope: HealthScope, event: HealthEvent) async throws -> HealthEventDetails {
        do {
            try Task.checkCancellation()
            let endpoint = try scope.endpoint()
            try Self.validate(event, scope: scope, partition: endpoint.partition)
            let operations = try await operations(scope: scope)
            try Task.checkCancellation()
            let response = try await operations.details(.init(eventArns: [event.arn], locale: "en"))
            try Task.checkCancellation()
            if let failures = response.failedSet, !failures.isEmpty {
                guard failures.count == 1, failures[0].eventArn == event.arn else { throw HealthError.invalidResponse }
                // Never surface errorMessage: Health can include request or account data.
                throw Self.sanitized(AWSResponseError(errorCode: failures[0].errorName ?? ""), operation: .details)
            }
            guard let successes = response.successfulSet, successes.count == 1,
                  let raw = successes[0].event, raw.arn == event.arn,
                  raw.eventScopeCode == .accountSpecific else { throw HealthError.invalidResponse }
            let mapped = try Self.map(raw, scope: scope, partition: endpoint.partition)
            try Task.checkCancellation()
            return HealthEventDetails(
                event: mapped, description: successes[0].eventDescription?.latestDescription,
                metadata: successes[0].eventMetadata ?? [:]
            )
        } catch {
            throw Self.sanitized(error, operation: .details)
        }
    }

    func loadEntities(scope: HealthScope, event: HealthEvent) async throws -> [HealthAffectedEntity] {
        do {
            try Task.checkCancellation()
            let endpoint = try scope.endpoint()
            try Self.validate(event, scope: scope, partition: endpoint.partition)
            let operations = try await operations(scope: scope)
            var entities: [HealthAffectedEntity] = []
            var entityIDs: Set<String> = []
            var token: String?
            var tokens: Set<String> = []
            for _ in 0..<Self.maximumPages {
                try Task.checkCancellation()
                let page = try await operations.entities(.init(
                    filter: .init(eventArns: [event.arn]), locale: "en", maxResults: 100, nextToken: token
                ))
                try Task.checkCancellation()
                for raw in page.entities ?? [] {
                    guard raw.eventArn == event.arn,
                          raw.awsAccountId == nil || raw.awsAccountId == "" || raw.awsAccountId == scope.accountID,
                          let id = raw.entityArn, !id.isEmpty,
                          entityIDs.insert(id).inserted else { throw HealthError.invalidResponse }
                    let parts = try Self.arnParts(id, scope: scope, partition: endpoint.partition)
                    guard parts[5].hasPrefix("entity/"), parts[5].count > "entity/".count else {
                        throw HealthError.invalidResponse
                    }
                    entities.append(HealthAffectedEntity(
                        id: id, value: raw.entityValue ?? "Unknown", status: raw.statusCode?.rawValue ?? "Unknown",
                        accountID: raw.awsAccountId.flatMap { $0.isEmpty ? nil : $0 }, lastUpdatedTime: raw.lastUpdatedTime
                    ))
                }
                guard let next = page.nextToken, !next.isEmpty else {
                    try Task.checkCancellation()
                    return entities.sorted { $0.value == $1.value ? $0.id < $1.id : $0.value < $1.value }
                }
                guard tokens.insert(next).inserted else { throw HealthError.incompletePagination }
                token = next
            }
            throw HealthError.incompletePagination
        } catch {
            throw Self.sanitized(error, operation: .entities)
        }
    }

    private func operations(scope: HealthScope) async throws -> Operations {
        try Task.checkCancellation()
        if let injected { return injected }
        guard let provider else { throw HealthError.invalidScope }
        let client = try await provider.healthClient(scope: scope)
        return Operations(
            events: { try await client.describeEvents($0) },
            details: { try await client.describeEventDetails($0) },
            entities: { try await client.describeAffectedEntities($0) }
        )
    }

    private static func arnParts(_ arn: String, scope: HealthScope, partition: String) throws -> [Substring] {
        let parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "arn", parts[1] == partition,
              parts[2] == "health",
              parts[4].isEmpty || parts[4] == scope.accountID else { throw HealthError.invalidResponse }
        return parts
    }

    private static func validate(_ event: HealthEvent, scope: HealthScope, partition: String) throws {
        let parts = try arnParts(event.arn, scope: scope, partition: partition)
        let resource = parts[5].split(separator: "/", omittingEmptySubsequences: false)
        guard resource.count == 4, resource[0] == "event", resource.allSatisfy({ !$0.isEmpty }),
              resource[1] == event.service, resource[2] == event.typeCode else { throw HealthError.invalidResponse }
    }

    private static func map(_ raw: Health.Event, scope: HealthScope, partition: String) throws -> HealthEvent {
        guard let arn = raw.arn, let service = raw.service, let code = raw.eventTypeCode else {
            throw HealthError.invalidResponse
        }
        let event = HealthEvent(
            arn: arn, service: service, typeCode: code, category: raw.eventTypeCategory?.rawValue ?? "Unknown",
            status: raw.statusCode?.rawValue ?? "Unknown", region: raw.region ?? "Unknown",
            availabilityZone: raw.availabilityZone, startTime: raw.startTime, endTime: raw.endTime,
            lastUpdatedTime: raw.lastUpdatedTime
        )
        try validate(event, scope: scope, partition: partition)
        return event
    }

    private enum Operation { case events, details, entities }

    private static func sanitized(_ error: Error, operation: Operation) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? HealthError { return error }
        if let error = error as? RequestError { return error }
        if error is AWSServiceError { return HealthError.invalidScope }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedException", "ForbiddenException"].contains(code) {
            switch operation {
            case .events: return RequestError.listPermission
            case .details: return RequestError.detailPermission
            case .entities: return RequestError.entitiesPermission
            }
        }
        if UserFacingError.requiresSSOLogin(error) { return RequestError.credentials }
        if error is URLError { return RequestError.network }
        switch code {
        case "SubscriptionRequiredException", "SubscriptionRequired": return RequestError.subscriptionRequired
        case "Throttling", "ThrottlingException", "TooManyRequestsException", "LimitExceededException": return RequestError.throttled
        case "InvalidPaginationToken", "InvalidNextToken", "InvalidNextTokenException": return HealthError.incompletePagination
        default: return RequestError.failed
        }
    }

    enum RequestError: LocalizedError, Equatable {
        case listPermission, detailPermission, entitiesPermission, subscriptionRequired, credentials, network, throttled, failed

        var errorDescription: String? {
            switch self {
            case .listPermission: return "Health event access was denied. Check health:DescribeEvents permission for the selected profile."
            case .detailPermission: return "Health event details could not be read. Check health:DescribeEventDetails permission for this event."
            case .entitiesPermission: return "Affected resources could not be read. Check health:DescribeAffectedEntities permission for this event."
            case .subscriptionRequired: return "AWS Health API access requires an eligible AWS Support plan for this account. You can still check events in the AWS Health console."
            case .credentials: return "AWS credentials expired or are unavailable. Sign in to the session, select the profile again, then reload Health events."
            case .network: return "Unable to reach AWS Health. Check your network or proxy, then refresh."
            case .throttled: return "AWS Health is limiting requests. Wait a moment, then refresh manually."
            case .failed: return "The AWS Health request failed. Check the selected profile and service availability, then refresh."
            }
        }
    }
}
