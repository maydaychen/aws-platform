import Foundation
import SotoCore
import SotoEC2

struct EC2InstanceHealthService: Sendable {
    typealias StatusLoader = @Sendable (EC2.DescribeInstanceStatusRequest) async throws -> EC2.DescribeInstanceStatusResult
    private let statuses: StatusLoader

    init(client: EC2) {
        statuses = { try await client.describeInstanceStatus($0) }
    }

    init(statuses: @escaping StatusLoader) { self.statuses = statuses }

    func load(instanceIds: [String]) async throws -> EC2InstanceHealthResult {
        try Task.checkCancellation()
        var seenIDs = Set<String>()
        let ids = instanceIds.filter { seenIDs.insert($0).inserted }
        guard !ids.isEmpty else { return .init(health: [:], errors: [:]) }
        let wanted = Set(ids)
        var health: [String: EC2InstanceHealth] = [:]
        var errors: [String: String] = [:]
        var tokens = Set<String>()
        var token: String?

        // The account/Region scan uses normal pagination; explicit IDs are reserved
        // for the single bounded recovery pass and never combined with MaxResults.
        do {
            for page in 0..<1_000 {
                try Task.checkCancellation()
                let response = try await statuses(.init(includeAllInstances: true, maxResults: 100, nextToken: token))
                try Task.checkCancellation()
                Self.merge(response, wanted: wanted, into: &health)
                guard let next = response.nextToken, !next.isEmpty else { break }
                guard page < 999, !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      tokens.insert(next).inserted else { throw HealthError.pagination }
                token = next
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            // Successful pages remain usable. Only unresolved IDs are retried below.
        }

        let missing = ids.filter { health[$0]?.hasStatusChecks != true }
        for start in stride(from: 0, to: missing.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(missing[start..<min(start + 100, missing.count)])
            do {
                let response = try await statuses(.init(includeAllInstances: true, instanceIds: batch))
                try Task.checkCancellation()
                Self.merge(response, wanted: Set(batch), into: &health)
                for id in batch where health[id]?.hasStatusChecks != true {
                    errors[id] = EC2InstanceHealthResult.notReturned
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                let message = Self.errorMessage(error)
                for id in batch { errors[id] = message }
            }
        }
        return .init(health: health, errors: errors)
    }

    func loadDetail(instanceId: String) async throws -> EC2InstanceHealth? {
        try Task.checkCancellation()
        do {
            let response = try await statuses(.init(includeAllInstances: true, instanceIds: [instanceId]))
            try Task.checkCancellation()
            return response.instanceStatuses?.first { $0.instanceId == instanceId }.map(Self.health)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw HealthError.request(Self.errorMessage(error))
        }
    }

    static func errorMessage(_ error: Error) -> String {
        if error is CancellationError { return UserFacingError.message(for: CancellationError()) }
        let code = (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedOperation", "UnauthorizedException", "Forbidden", "ForbiddenException"].contains(code) {
            return UserFacingError.message(for: AWSResponseError(errorCode: "AccessDenied"))
        }
        if UserFacingError.requiresSSOLogin(error) || ["MissingAuthenticationToken", "UnrecognizedClient", "RequestExpired", "SignatureDoesNotMatch", "InvalidSignature"].contains(code) {
            return UserFacingError.message(for: AWSResponseError(errorCode: "InvalidAccessKeyId"))
        }
        if ["Throttling", "ThrottlingException", "RequestLimitExceeded", "TooManyRequestsException"].contains(code) {
            return "AWS API rate limit reached. Wait a moment and retry."
        }
        if error is URLError {
            return "Unable to connect to AWS. Check your network, proxy and endpoint settings, then retry."
        }
        if let error = error as? HealthError { return error.localizedDescription }
        return "Unable to load EC2 status checks."
    }

    private static func merge(_ response: EC2.DescribeInstanceStatusResult, wanted: Set<String>,
                              into result: inout [String: EC2InstanceHealth]) {
        for status in response.instanceStatuses ?? [] {
            guard let id = status.instanceId, wanted.contains(id) else { continue }
            let value = health(status)
            if value.hasStatusChecks || result[id] == nil {
                result[id] = value
            } else if let previous = result[id] {
                let newEventIDs = Set(value.events.map(\.eventId))
                let events = previous.events.filter { !newEventIDs.contains($0.eventId) } + value.events
                result[id] = EC2InstanceHealth(systemStatus: value.systemStatus ?? previous.systemStatus,
                                               instanceStatus: value.instanceStatus ?? previous.instanceStatus,
                                               attachedEBSStatus: value.attachedEBSStatus ?? previous.attachedEBSStatus,
                                               events: events)
            }
        }
    }

    private static func health(_ status: EC2.InstanceStatus) -> EC2InstanceHealth {
        EC2InstanceHealth(systemStatus: status.systemStatus?.status?.rawValue,
                          instanceStatus: status.instanceStatus?.status?.rawValue,
                          attachedEBSStatus: status.attachedEbsStatus?.status?.rawValue,
                          events: (status.events ?? []).map { event in
            EC2ScheduledEvent(eventId: event.instanceEventId ?? [event.code?.rawValue, event.notBefore?.description].compactMap { $0 }.joined(separator: "-"),
                              code: event.code?.rawValue ?? "unknown", description: event.description,
                              notBefore: event.notBefore, notAfter: event.notAfter)
        })
    }

    private enum HealthError: LocalizedError {
        case pagination
        case request(String)

        var errorDescription: String? {
            switch self {
            case .pagination: return "Unable to load EC2 status checks."
            case .request(let message): return message
            }
        }
    }
}
