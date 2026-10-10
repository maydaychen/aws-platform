import Foundation
import SotoCore
import SotoHealth

extension AWSHealthService {
    struct OrganizationOperations: Sendable {
        var events: @Sendable (Health.DescribeEventsForOrganizationRequest) async throws -> Health.DescribeEventsForOrganizationResponse
        var accounts: @Sendable (Health.DescribeAffectedAccountsForOrganizationRequest) async throws -> Health.DescribeAffectedAccountsForOrganizationResponse
        var details: @Sendable (Health.DescribeEventDetailsForOrganizationRequest) async throws -> Health.DescribeEventDetailsForOrganizationResponse
        var entities: @Sendable (Health.DescribeAffectedEntitiesForOrganizationRequest) async throws -> Health.DescribeAffectedEntitiesForOrganizationResponse
    }

    func loadOrganizationEvents(scope: HealthScope) async throws -> [HealthEvent] {
        do {
            let endpoint = try scope.endpoint()
            let operations = try await organizationOperations(scope: scope)
            var values: [HealthEvent] = []
            var ids: Set<String> = []
            var token: String?
            var tokens: Set<String> = []
            for _ in 0..<100 {
                try Task.checkCancellation()
                let page = try await operations.events(.init(
                    filter: scope.organizationAccountFilter.map { .init(awsAccountIds: [$0]) },
                    locale: "en", maxResults: 100, nextToken: token
                ))
                try Task.checkCancellation()
                for raw in page.events ?? [] where raw.eventScopeCode == .accountSpecific {
                    let event = try Self.map(.init(
                        arn: raw.arn, endTime: raw.endTime, eventScopeCode: raw.eventScopeCode,
                        eventTypeCategory: raw.eventTypeCategory, eventTypeCode: raw.eventTypeCode,
                        lastUpdatedTime: raw.lastUpdatedTime, region: raw.region, service: raw.service,
                        startTime: raw.startTime, statusCode: raw.statusCode
                    ), scope: scope, partition: endpoint.partition)
                    guard ids.insert(event.id).inserted else { throw HealthError.invalidResponse }
                    values.append(event)
                }
                guard let next = page.nextToken, !next.isEmpty else {
                    return values.sorted {
                        let first = $0.lastUpdatedTime ?? $0.startTime ?? .distantPast
                        let second = $1.lastUpdatedTime ?? $1.startTime ?? .distantPast
                        return first == second ? $0.arn < $1.arn : first > second
                    }
                }
                guard tokens.insert(next).inserted else { throw HealthError.incompletePagination }
                token = next
            }
            throw HealthError.incompletePagination
        } catch { throw Self.sanitized(error, operation: .organizationEvents) }
    }

    func loadAffectedAccounts(scope: HealthScope, event: HealthEvent) async throws -> [String] {
        do {
            let endpoint = try scope.endpoint()
            try Self.validate(event, scope: scope, partition: endpoint.partition)
            let operations = try await organizationOperations(scope: scope)
            var accounts: Set<String> = []
            var token: String?
            var tokens: Set<String> = []
            for _ in 0..<100 {
                try Task.checkCancellation()
                let page = try await operations.accounts(.init(eventArn: event.arn, maxResults: 100, nextToken: token))
                try Task.checkCancellation()
                guard page.eventScopeCode == .accountSpecific else { throw HealthError.invalidResponse }
                for account in page.affectedAccounts ?? [] {
                    guard HealthScope.isAccountID(account) else { throw HealthError.invalidResponse }
                    accounts.insert(account)
                }
                guard let next = page.nextToken, !next.isEmpty else { return accounts.sorted() }
                guard tokens.insert(next).inserted else { throw HealthError.incompletePagination }
                token = next
            }
            throw HealthError.incompletePagination
        } catch { throw Self.sanitized(error, operation: .organizationAccounts) }
    }

    func loadOrganizationDetails(scope: HealthScope, event: HealthEvent) async throws -> HealthEventDetails {
        do {
            let account = try Self.detailAccount(scope: scope, event: event)
            let operations = try await organizationOperations(scope: scope)
            let response = try await operations.details(.init(
                locale: "en", organizationEventDetailFilters: [.init(awsAccountId: account, eventArn: event.arn)]
            ))
            try Task.checkCancellation()
            if let failures = response.failedSet, !failures.isEmpty {
                guard failures.count == 1, failures[0].eventArn == event.arn,
                      failures[0].awsAccountId == account else { throw HealthError.invalidResponse }
                throw Self.sanitized(AWSResponseError(errorCode: failures[0].errorName ?? ""), operation: .organizationDetails)
            }
            guard let successes = response.successfulSet, successes.count == 1,
                  successes[0].awsAccountId == account, let raw = successes[0].event,
                  raw.arn == event.arn, raw.eventScopeCode == .accountSpecific else { throw HealthError.invalidResponse }
            var mapped = try Self.map(raw, scope: scope, partition: scope.endpoint().partition)
            mapped.affectedAccountID = account
            return HealthEventDetails(event: mapped, description: successes[0].eventDescription?.latestDescription,
                                      metadata: successes[0].eventMetadata ?? [:])
        } catch { throw Self.sanitized(error, operation: .organizationDetails) }
    }

    func loadOrganizationEntities(scope: HealthScope, event: HealthEvent) async throws -> [HealthAffectedEntity] {
        do {
            let account = try Self.detailAccount(scope: scope, event: event)
            let endpoint = try scope.endpoint()
            let operations = try await organizationOperations(scope: scope)
            var values: [HealthAffectedEntity] = []
            var ids: Set<String> = []
            var token: String?
            var tokens: Set<String> = []
            for _ in 0..<100 {
                try Task.checkCancellation()
                let page = try await operations.entities(.init(
                    locale: "en", maxResults: 100, nextToken: token,
                    organizationEntityAccountFilters: [.init(awsAccountId: account, eventArn: event.arn)]
                ))
                try Task.checkCancellation()
                if let failures = page.failedSet, !failures.isEmpty {
                    guard failures.count == 1, failures[0].eventArn == event.arn,
                          failures[0].awsAccountId == account else { throw HealthError.invalidResponse }
                    throw Self.sanitized(AWSResponseError(errorCode: failures[0].errorName ?? ""), operation: .organizationEntities)
                }
                for raw in page.entities ?? [] {
                    guard raw.eventArn == event.arn, raw.awsAccountId == account,
                          let id = raw.entityArn, ids.insert(id).inserted else { throw HealthError.invalidResponse }
                    let parts = try Self.arnParts(id, scope: scope, partition: endpoint.partition)
                    guard parts[4].isEmpty || parts[4] == account,
                          parts[5].hasPrefix("entity/"), parts[5].count > "entity/".count else { throw HealthError.invalidResponse }
                    values.append(HealthAffectedEntity(id: id, value: raw.entityValue ?? "Unknown",
                                                      status: raw.statusCode?.rawValue ?? "Unknown",
                                                      accountID: account, lastUpdatedTime: raw.lastUpdatedTime))
                }
                guard let next = page.nextToken, !next.isEmpty else {
                    return values.sorted { $0.value == $1.value ? $0.id < $1.id : $0.value < $1.value }
                }
                guard tokens.insert(next).inserted else { throw HealthError.incompletePagination }
                token = next
            }
            throw HealthError.incompletePagination
        } catch { throw Self.sanitized(error, operation: .organizationEntities) }
    }

    private static func detailAccount(scope: HealthScope, event: HealthEvent) throws -> String {
        let endpoint = try scope.endpoint()
        guard scope.queryMode == .organization, let account = event.affectedAccountID,
              HealthScope.isAccountID(account) else { throw HealthError.invalidScope }
        try validate(event, scope: scope, partition: endpoint.partition)
        return account
    }
}
