import Foundation
import SotoCore
import SotoCostExplorer

struct AWSCostService: Sendable {
    typealias CostLoader = @Sendable (CostExplorer.GetCostAndUsageRequest) async throws -> CostExplorer.GetCostAndUsageResponse
    typealias DimensionLoader = @Sendable (CostExplorer.GetDimensionValuesRequest) async throws -> CostExplorer.GetDimensionValuesResponse

    private let provider: AWSServiceProvider?
    private let costLoader: CostLoader?
    private let dimensionLoader: DimensionLoader?
    private let now: @Sendable () -> Date
    private static let metric = "UnblendedCost"
    private static let maximumPages = 100

    init(provider: AWSServiceProvider) {
        self.provider = provider
        costLoader = nil
        dimensionLoader = nil
        now = { Date() }
    }

    init(
        costLoader: @escaping CostLoader,
        dimensionLoader: @escaping DimensionLoader,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        provider = nil
        self.costLoader = costLoader
        self.dimensionLoader = dimensionLoader
        self.now = now
    }

    func load(scope: CostScope, query: CostQuery) async throws -> CostReport {
        try Task.checkCancellation()
        if let message = query.validationMessage { throw CostError.invalidQuery(message) }
        let partition = try Self.partition(for: scope)
        do {
            let costs: CostLoader
            let dimensions: DimensionLoader
            if let provider {
                let paths = AWSConfigurationPaths(environment: [
                    "AWS_CONFIG_FILE": scope.configPath,
                    "AWS_SHARED_CREDENTIALS_FILE": scope.credentialsPath
                ])
                let client = try await provider.costExplorerClient(profile: scope.profile, paths: paths, partition: partition)
                costs = { try await client.getCostAndUsage($0) }
                dimensions = { try await client.getDimensionValues($0) }
            } else if let costLoader, let dimensionLoader {
                costs = costLoader
                dimensions = dimensionLoader
            } else {
                throw CostError.invalidIdentity
            }

            var requestCount = 0
            var amounts = Amounts()
            let summary = try await Self.costPages(
                range: query.summaryRange, granularity: .monthly, grouped: false,
                filter: Self.filter(account: scope.accountID, region: query.region),
                loader: costs, requestCount: &requestCount
            )
            let monthly = try Self.monthlyAmounts(summary, query: query, amounts: &amounts)
            var daily: [CostDailyAmount] = []
            var services: [CostServiceAmount] = []
            var regions: [String] = []

            if !query.range.isEmpty {
                let selected = try await Self.costPages(
                    range: query.range, granularity: .daily, grouped: true,
                    filter: Self.filter(account: scope.accountID, region: query.region),
                    loader: costs, requestCount: &requestCount
                )
                (daily, services) = try Self.dailyAmounts(selected, range: query.range, amounts: &amounts)
                regions = try await Self.regionValues(
                    range: query.range, account: scope.accountID,
                    loader: dimensions, requestCount: &requestCount
                )
            }
            try Task.checkCancellation()
            return CostReport(
                query: query, currency: amounts.currency,
                thisMonth: monthly[CostDates.string(query.currentMonthStart)],
                lastMonth: monthly[query.summaryRange.startString],
                daily: daily, services: services, regions: regions,
                estimated: amounts.estimated, fetchedAt: now(), apiRequestCount: requestCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CostError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw Self.sanitized(error)
        }
    }

    static func partition(for scope: CostScope) throws -> AWSPartition {
        let parts = scope.principalARN.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard scope.accountID.range(of: "^[0-9]{12}$", options: .regularExpression) != nil,
              parts.count == 6, parts[0] == "arn", ["sts", "iam"].contains(String(parts[2])),
              parts[4] == scope.accountID, !parts[5].isEmpty else {
            throw CostError.invalidIdentity
        }
        switch parts[1] {
        case "aws": return .aws
        case "aws-cn": return .awscn
        default: throw CostError.unsupportedPartition
        }
    }

    private static func filter(account: String, region: String?) -> CostExplorer.Expression {
        let accountFilter = CostExplorer.Expression(dimensions: .init(key: .linkedAccount, values: [account]))
        guard let region else { return accountFilter }
        return .init(and: [accountFilter, .init(dimensions: .init(key: .region, values: [region]))])
    }

    private static func costPages(
        range: CostDateRange, granularity: CostExplorer.Granularity, grouped: Bool,
        filter: CostExplorer.Expression, loader: CostLoader, requestCount: inout Int
    ) async throws -> [CostExplorer.ResultByTime] {
        var results: [CostExplorer.ResultByTime] = []
        var token: String?
        var seenTokens: Set<String> = []
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let request = CostExplorer.GetCostAndUsageRequest(
                filter: filter, granularity: granularity,
                groupBy: grouped ? [.init(key: "SERVICE", type: .dimension)] : nil,
                metrics: [metric], nextPageToken: token,
                timePeriod: .init(end: range.endString, start: range.startString)
            )
            requestCount += 1
            let response = try await loader(request)
            try Task.checkCancellation()
            guard let page = response.resultsByTime else { throw CostError.invalidResponse }
            if let definitions = response.groupDefinitions, !definitions.isEmpty {
                guard grouped, definitions.count == 1,
                      definitions[0].key == "SERVICE", definitions[0].type == .dimension else {
                    throw CostError.invalidResponse
                }
            }
            results.append(contentsOf: page)
            guard let next = response.nextPageToken, !next.isEmpty else { return results }
            guard seenTokens.insert(next).inserted else { throw CostError.incompletePagination }
            token = next
        }
        throw CostError.incompletePagination
    }

    private static func regionValues(
        range: CostDateRange, account: String, loader: DimensionLoader, requestCount: inout Int
    ) async throws -> [String] {
        var values: Set<String> = []
        var token: String?
        var seenTokens: Set<String> = []
        var expectedCount: Int?
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let request = CostExplorer.GetDimensionValuesRequest(
                context: .costAndUsage, dimension: .region, filter: filter(account: account, region: nil),
                nextPageToken: token, timePeriod: .init(end: range.endString, start: range.startString)
            )
            requestCount += 1
            let response = try await loader(request)
            try Task.checkCancellation()
            guard response.returnSize == response.dimensionValues.count, response.totalSize >= 0,
                  expectedCount == nil || expectedCount == response.totalSize else {
                throw CostError.invalidResponse
            }
            expectedCount = response.totalSize
            for entry in response.dimensionValues {
                guard let value = entry.value, values.insert(value).inserted else {
                    throw CostError.invalidResponse
                }
            }
            guard values.count <= response.totalSize else { throw CostError.invalidResponse }
            guard let next = response.nextPageToken, !next.isEmpty else {
                guard values.count == response.totalSize else { throw CostError.incompletePagination }
                return values.sorted()
            }
            guard seenTokens.insert(next).inserted else { throw CostError.incompletePagination }
            token = next
        }
        throw CostError.incompletePagination
    }

    private static func monthlyAmounts(
        _ rows: [CostExplorer.ResultByTime], query: CostQuery, amounts: inout Amounts
    ) throws -> [String: Decimal] {
        guard !rows.isEmpty else { return [:] }
        var expected = [query.summaryRange.startString: CostDates.string(query.currentMonthStart)]
        if query.currentMonthStart < query.referenceDate {
            expected[CostDates.string(query.currentMonthStart)] = query.summaryRange.endString
        }
        var result: [String: Decimal] = [:]
        for row in rows {
            try Task.checkCancellation()
            guard let period = row.timePeriod, expected[period.start] == period.end,
                  result[period.start] == nil, row.groups?.isEmpty != false,
                  let estimated = row.estimated else { throw CostError.invalidResponse }
            result[period.start] = try amounts.read(row.total?[metric])
            amounts.estimated = amounts.estimated || estimated
        }
        guard Set(result.keys) == Set(expected.keys) else { throw CostError.invalidResponse }
        return result
    }

    private static func dailyAmounts(
        _ rows: [CostExplorer.ResultByTime], range: CostDateRange, amounts: inout Amounts
    ) throws -> ([CostDailyAmount], [CostServiceAmount]) {
        guard !rows.isEmpty else { return ([], []) }
        var days: [String: [String: Decimal]] = [:]
        var services: [String: Decimal] = [:]
        for row in rows {
            try Task.checkCancellation()
            guard let period = row.timePeriod, let date = CostDates.date(period.start),
                  date >= range.start, date < range.end,
                  let end = CostDates.calendar.date(byAdding: .day, value: 1, to: date),
                  period.end == CostDates.string(end), let groups = row.groups,
                  let estimated = row.estimated else { throw CostError.invalidResponse }
            amounts.estimated = amounts.estimated || estimated
            if days[period.start] == nil { days[period.start] = [:] }
            if let total = row.total?[metric] {
                let totalAmount = try amounts.read(total)
                guard !groups.isEmpty || totalAmount == 0 else { throw CostError.invalidResponse }
            }
            for group in groups {
                guard let keys = group.keys, keys.count == 1, !keys[0].isEmpty,
                      days[period.start]?[keys[0]] == nil else { throw CostError.invalidResponse }
                let amount = try amounts.read(group.metrics?[metric])
                days[period.start]?[keys[0]] = amount
                services[keys[0]] = try add(services[keys[0]] ?? 0, amount)
            }
        }
        let expectedDays = CostDates.calendar.dateComponents([.day], from: range.start, to: range.end).day
        guard days.count == expectedDays else { throw CostError.invalidResponse }
        let daily = try days.sorted { $0.key < $1.key }.map { date, groups in
            CostDailyAmount(date: date, amount: try groups.values.reduce(Decimal(0), add))
        }
        _ = try daily.reduce(Decimal(0)) { try add($0, $1.amount) }
        return (
            daily,
            services.map { CostServiceAmount(name: $0.key, amount: $0.value) }
                .sorted { $0.amount == $1.amount ? $0.name < $1.name : $0.amount > $1.amount }
        )
    }

    private static func add(_ lhs: Decimal, _ rhs: Decimal) throws -> Decimal {
        var lhs = lhs
        var rhs = rhs
        var result = Decimal()
        guard NSDecimalAdd(&result, &lhs, &rhs, .plain) == .noError else { throw CostError.invalidResponse }
        return result
    }

    private struct Amounts {
        var currency: String?
        var estimated = false

        mutating func read(_ metric: CostExplorer.MetricValue?) throws -> Decimal {
            guard let text = metric?.amount, let unit = metric?.unit, !unit.isEmpty,
                  unit == unit.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.range(of: "^[+-]?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil else {
                throw CostError.invalidResponse
            }
            let digits = text.filter { $0.isNumber }.drop(while: { $0 == "0" })
            let fractionalDigits = text.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
            guard digits.count <= 38, fractionalDigits <= 128,
                  let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN,
                  currency == nil || currency == unit else { throw CostError.invalidResponse }
            currency = unit
            return amount
        }
    }

    private static func sanitized(_ error: Error) -> RequestError {
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        switch code {
        case "AccessDenied", "AccessDeniedException", "UnauthorizedException", "ForbiddenException":
            return .permission
        case "DataUnavailableException": return .dataUnavailable
        case "OptInRequired", "CostExplorerNotEnabledException", "NotEnabledException": return .notEnabled
        case "LimitExceededException", "Throttling", "ThrottlingException", "TooManyRequestsException":
            return .throttled
        case "InvalidNextTokenException", "RequestChangedException": return .changedPages
        case "ServiceUnavailable", "ServiceUnavailableException", "InternalFailure", "InternalServerException":
            return .unavailable
        default:
            if UserFacingError.requiresSSOLogin(error) { return .credentials }
            if error is URLError { return .network }
            return .failed
        }
    }

    enum RequestError: LocalizedError, Equatable {
        case permission, dataUnavailable, notEnabled, throttled, changedPages, credentials, network, unavailable, failed

        var errorDescription: String? {
            switch self {
            case .permission:
                return "Cost access was denied. Check this account's billing access and the role's ce:GetCostAndUsage and ce:GetDimensionValues permissions."
            case .dataUnavailable:
                return "Cost data is not available for this account and date range yet. Check whether Cost Explorer is enabled and allow time for billing data to be prepared."
            case .notEnabled:
                return "Enable Cost Explorer for this account in the AWS console, allow time for billing data to be prepared, then refresh."
            case .throttled:
                return "Cost Explorer is limiting requests. Wait a moment, then refresh manually."
            case .changedPages:
                return "Cost data changed or pagination expired before the result was complete. Refresh to start a new query."
            case .credentials:
                return "AWS credentials expired or are unavailable. Sign in to the SSO session, select the profile again, then reload costs."
            case .network:
                return "Unable to reach Cost Explorer. Check your network or proxy, then refresh."
            case .unavailable:
                return "Cost Explorer is temporarily unavailable. Try refreshing later."
            case .failed:
                return "The cost request failed. Check Cost Explorer availability, billing access and your connection, then refresh."
            }
        }
    }
}
