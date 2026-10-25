import Foundation
import SotoCore
import SotoCostExplorer
import XCTest
@testable import AWSPlatform

final class AWSCostServiceTests: XCTestCase {
    func testPaginatesExactCostsAndEnforcesAccountOnEveryRequest() async throws {
        let stub = CostStub(
            monthly: [
                .init(nextPageToken: "monthly-2", resultsByTime: [monthly("2026-05-01", "2026-06-01", "100.25")]),
                .init(resultsByTime: [monthly("2026-06-01", "2026-06-03", "7.5000000001", estimated: true)])
            ],
            daily: [
                .init(nextPageToken: "daily-2", resultsByTime: [
                    daily("2026-06-01", [("EC2", "10")]), daily("2026-06-02", [("EC2", "0")])
                ]),
                .init(resultsByTime: [
                    daily("2026-06-01", [("Refund", "-2.5")]),
                    daily("2026-06-02", [("S3", "0.0000000001")], estimated: true)
                ])
            ],
            dimensions: [
                .init(dimensionValues: [.init(value: "")], nextPageToken: "region-2", returnSize: 1, totalSize: 2),
                .init(dimensionValues: [.init(value: "eu-west-1")], returnSize: 1, totalSize: 2)
            ]
        )
        let fetched = date("2026-06-03").addingTimeInterval(60)
        let service = service(stub, fetched: fetched)
        let report = try await service.load(scope: scope(), query: query(region: "eu-west-1"))

        XCTAssertEqual(report.currency, "USD")
        XCTAssertEqual(report.lastMonth, Decimal(string: "100.25"))
        XCTAssertEqual(report.thisMonth, Decimal(string: "7.5000000001"))
        XCTAssertEqual(report.selectedTotal, Decimal(string: "7.5000000001"))
        XCTAssertEqual(report.daily.map(\.date), ["2026-06-01", "2026-06-02"])
        XCTAssertEqual(report.services.map(\.name), ["EC2", "S3", "Refund"])
        XCTAssertEqual(report.services.last?.amount, Decimal(string: "-2.5"))
        XCTAssertEqual(report.regions, ["", "eu-west-1"])
        XCTAssertTrue(report.estimated)
        XCTAssertEqual(report.fetchedAt, fetched)
        XCTAssertEqual(report.apiRequestCount, 6)

        let (costRequests, dimensionRequests) = await stub.requests()
        XCTAssertEqual(costRequests.map(\.nextPageToken), [nil, "monthly-2", nil, "daily-2"])
        for request in costRequests {
            XCTAssertEqual(request.metrics, ["UnblendedCost"])
            XCTAssertNil(request.billingViewArn)
            assertFilter(request.filter, region: "eu-west-1")
            if request.granularity == .monthly {
                XCTAssertEqual(request.timePeriod.start, "2026-05-01")
                XCTAssertEqual(request.timePeriod.end, "2026-06-03")
                XCTAssertNil(request.groupBy)
            } else {
                XCTAssertEqual(request.timePeriod.start, "2026-06-01")
                XCTAssertEqual(request.timePeriod.end, "2026-06-03")
                XCTAssertEqual(request.groupBy?.first?.key, "SERVICE")
                XCTAssertEqual(request.groupBy?.first?.type, .dimension)
            }
        }
        for request in dimensionRequests {
            assertFilter(request.filter, region: nil)
            XCTAssertEqual(request.dimension, .region)
            XCTAssertEqual(request.context, .costAndUsage)
            XCTAssertEqual(request.timePeriod.start, "2026-06-01")
            XCTAssertEqual(request.timePeriod.end, "2026-06-03")
        }
    }

    func testAllRegionsOmitsRegionFilterAndEmptyRawRegionIsNotRenamed() async throws {
        let regions: [String?] = [nil, ""]
        for region in regions {
            let stub = CostStub(monthly: [.init(resultsByTime: [])], daily: [.init(resultsByTime: [])])
            let report = try await service(stub).load(scope: scope(), query: query(region: region))
            let (requests, _) = await stub.requests()
            for request in requests { assertFilter(request.filter, region: region) }
            XCTAssertNil(report.currency)
            XCTAssertNil(report.thisMonth)
            XCTAssertNil(report.lastMonth)
            XCTAssertTrue(report.daily.isEmpty)
            XCTAssertTrue(report.services.isEmpty)
        }
    }

    func testFirstDayOfMonthSkipsEmptyDailyAndRegionQueries() async throws {
        let now = date("2026-06-01")
        let stub = CostStub(monthly: [.init(resultsByTime: [monthly("2026-05-01", "2026-06-01", "0", unit: "CNY")])])
        let report = try await service(stub).load(
            scope: scope(partition: "aws-cn"),
            query: CostQuery(range: CostPeriod.thisMonth.range(now: now), region: nil, referenceDate: now)
        )
        XCTAssertNil(report.thisMonth)
        XCTAssertEqual(report.lastMonth, 0)
        XCTAssertEqual(report.currency, "CNY")
        XCTAssertTrue(report.daily.isEmpty)
        XCTAssertTrue(report.regions.isEmpty)
        XCTAssertEqual(report.apiRequestCount, 1)
        let (requests, dimensions) = await stub.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(dimensions.isEmpty)
    }

    func testEmptyGroupsPreserveZeroDaysWithoutInventingCurrency() async throws {
        let stub = CostStub(
            monthly: [.init(resultsByTime: [])],
            daily: [.init(resultsByTime: [daily("2026-06-01", []), daily("2026-06-02", [])])]
        )
        let report = try await service(stub).load(scope: scope(), query: query())
        XCTAssertEqual(report.daily.map(\.amount), [0, 0])
        XCTAssertEqual(report.selectedTotal, 0)
        XCTAssertNil(report.currency)
        XCTAssertTrue(report.services.isEmpty)
    }

    func testRejectsMalformedAmountsMissingMetricsAndMixedCurrencies() async throws {
        let metrics: [CostExplorer.MetricValue?] = [
            nil, .init(amount: "NaN", unit: "USD"), .init(amount: "1oops", unit: "USD"),
            .init(amount: " 1", unit: "USD"), .init(amount: "1e999", unit: "USD"),
            .init(amount: String(repeating: "9", count: 39), unit: "USD"),
            .init(amount: "0." + String(repeating: "0", count: 128) + "1", unit: "USD"),
            .init(amount: "1", unit: ""), .init(amount: "1", unit: "CNY")
        ]
        for metric in metrics {
            let stub = CostStub(
                monthly: [.init(resultsByTime: summary())],
                daily: [.init(resultsByTime: [
                    .init(estimated: false, groups: [.init(keys: ["EC2"], metrics: metric.map { ["UnblendedCost": $0] })],
                          timePeriod: .init(end: "2026-06-02", start: "2026-06-01")),
                    daily("2026-06-02", [])
                ])]
            )
            await assertCostError(.invalidResponse) { try await self.service(stub).load(scope: self.scope(), query: self.query()) }
        }
    }

    func testRejectsMissingDateCoverageAndDuplicateServiceRows() async {
        let cases: [[CostExplorer.ResultByTime]] = [
            [daily("2026-06-01", [("EC2", "1")])],
            [daily("2026-05-31", []), daily("2026-06-02", [])],
            [daily("2026-06-01", [("EC2", "1"), ("EC2", "2")]), daily("2026-06-02", [])],
            [.init(estimated: false, groups: nil, timePeriod: .init(end: "2026-06-02", start: "2026-06-01")),
             daily("2026-06-02", [])]
        ]
        for rows in cases {
            let stub = CostStub(monthly: [.init(resultsByTime: summary())], daily: [.init(resultsByTime: rows)])
            await assertCostError(.invalidResponse) { try await self.service(stub).load(scope: self.scope(), query: self.query()) }
        }
    }

    func testRejectsIncompleteMonthlyRowsAndMissingResultsContainer() async {
        for response in [
            CostExplorer.GetCostAndUsageResponse(),
            .init(resultsByTime: [monthly("2026-05-01", "2026-06-01", "1")]),
            .init(resultsByTime: summary() + [monthly("2026-05-01", "2026-06-01", "1")])
        ] {
            let stub = CostStub(monthly: [response])
            await assertCostError(.invalidResponse) { try await self.service(stub).load(scope: self.scope(), query: self.query()) }
        }
    }

    func testPaginationCycleAndPageLimitNeverPublishPartialTotals() async {
        let cases: [[CostExplorer.GetCostAndUsageResponse]] = [
            [.init(nextPageToken: "again", resultsByTime: []), .init(nextPageToken: "again", resultsByTime: [])],
            (1...100).map { .init(nextPageToken: "page-\($0)", resultsByTime: []) }
        ]
        for pages in cases {
            let stub = CostStub(monthly: pages)
            await assertCostError(.incompletePagination) { try await self.service(stub).load(scope: self.scope(), query: self.query()) }
            let (requests, dimensions) = await stub.requests()
            XCTAssertEqual(requests.count, pages.count)
            XCTAssertTrue(dimensions.isEmpty)
            XCTAssertTrue(requests.allSatisfy { $0.filter?.dimensions?.values == ["111122223333"] })
        }
    }

    func testDimensionPaginationValidatesTotalsAndRejectsCycles() async {
        let cases: [[CostExplorer.GetDimensionValuesResponse]] = [
            [.init(dimensionValues: [.init(value: "us-east-1")], returnSize: 1, totalSize: 2)],
            [.init(dimensionValues: [], nextPageToken: "again", returnSize: 0, totalSize: 0),
             .init(dimensionValues: [], nextPageToken: "again", returnSize: 0, totalSize: 0)]
        ]
        for pages in cases {
            let stub = CostStub(monthly: [.init(resultsByTime: summary())], daily: [.init(resultsByTime: [])], dimensions: pages)
            await assertCostError(.incompletePagination) { try await self.service(stub).load(scope: self.scope(), query: self.query()) }
        }
    }

    func testCancellationAfterResponseDoesNotContinueToOtherOperations() async {
        let gate = TestGate()
        let rows = summary()
        let service = AWSCostService(costLoader: { _ in
            await gate.wait()
            return .init(resultsByTime: rows)
        }, dimensionLoader: { _ in
            XCTFail("Cancelled load must not request region values")
            return .init(dimensionValues: [], returnSize: 0, totalSize: 0)
        })
        let scope = scope()
        let query = query()
        let task = Task { try await service.load(scope: scope, query: query) }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testExplicitPartitionAndIdentityValidationHappenBeforeAnyRequest() async throws {
        XCTAssertEqual(try AWSCostService.partition(for: scope()), .aws)
        XCTAssertEqual(try AWSCostService.partition(for: scope(partition: "aws-cn")), .awscn)
        let service = AWSCostService(costLoader: { _ in
            XCTFail("Invalid identity must not query AWS")
            return .init(resultsByTime: [])
        }, dimensionLoader: { _ in
            XCTFail("Invalid identity must not query AWS")
            return .init(dimensionValues: [], returnSize: 0, totalSize: 0)
        })
        await assertCostError(.unsupportedPartition) { try await service.load(scope: self.scope(partition: "aws-us-gov"), query: self.query()) }
        await assertCostError(.invalidIdentity) { try await service.load(scope: self.scope(account: "-"), query: self.query()) }
        let mismatch = CostScope(profile: scope().profile, identity: .init(
            account: "111122223333", arn: "arn:aws:sts::999988887777:assumed-role/Test/session", userID: "example"
        ))
        await assertCostError(.invalidIdentity) { try await service.load(scope: mismatch, query: self.query()) }
    }

    func testInvalidDateRangeIsRejectedBeforeAnyRequest() async {
        let stub = CostStub(monthly: [])
        let invalid = CostQuery(
            range: .init(start: date("2026-06-04"), end: date("2026-06-02")), region: nil,
            referenceDate: date("2026-06-03")
        )
        await assertCostError(.invalidQuery("")) { try await self.service(stub).load(scope: self.scope(), query: invalid) }
        let (requests, _) = await stub.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testErrorMessagesAreSanitizedWithoutGuessingNotEnabledOrLogin() async {
        let cases: [(Error, AWSCostService.RequestError)] = [
            (AWSResponseError(errorCode: "AccessDeniedException"), .permission),
            (CostExplorerErrorType.dataUnavailableException, .dataUnavailable),
            (AWSResponseError(errorCode: "CostExplorerNotEnabledException"), .notEnabled),
            (CostExplorerErrorType.limitExceededException, .throttled),
            (CostExplorerErrorType.requestChangedException, .changedPages),
            (AWSResponseError(errorCode: "ValidationException"), .failed),
            (NSError(domain: "private-account-or-token-output", code: 1), .failed),
            (URLError(.notConnectedToInternet), .network)
        ]
        for (failure, expected) in cases {
            let service = AWSCostService(costLoader: { _ in throw failure }, dimensionLoader: { _ in
                XCTFail("Failure must not trigger more billable queries")
                return .init(dimensionValues: [], returnSize: 0, totalSize: 0)
            })
            do {
                _ = try await service.load(scope: scope(), query: query())
                XCTFail("Expected sanitized failure")
            } catch {
                XCTAssertEqual(error as? AWSCostService.RequestError, expected)
                XCTAssertFalse(error.localizedDescription.contains("private-account-or-token-output"))
                if expected == .failed || expected == .permission {
                    XCTAssertFalse(error.localizedDescription.contains("expired"))
                    XCTAssertFalse(error.localizedDescription.contains("not enabled"))
                }
            }
        }
    }

    private func service(_ stub: CostStub, fetched: Date = Date(timeIntervalSince1970: 0)) -> AWSCostService {
        AWSCostService(costLoader: { try await stub.cost($0) }, dimensionLoader: { try await stub.dimensions($0) }, now: { fetched })
    }

    private func scope(partition: String = "aws", account: String = "111122223333") -> CostScope {
        CostScope(
            profile: AWSProfile(name: "work", region: "eu-west-1", ssoStartURL: nil, ssoRegion: nil,
                                ssoAccountID: nil, ssoRoleName: nil),
            identity: AWSIdentity(account: account, arn: "arn:\(partition):sts::\(account):assumed-role/Test/session", userID: "example"),
            paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/config", "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials"])
        )
    }

    private func query(region: String? = nil) -> CostQuery {
        CostQuery(range: .init(start: date("2026-06-01"), end: date("2026-06-03")), region: region, referenceDate: date("2026-06-03"))
    }

    private func date(_ value: String) -> Date { CostDates.date(value)! }

    private func summary() -> [CostExplorer.ResultByTime] {
        [monthly("2026-05-01", "2026-06-01", "10"), monthly("2026-06-01", "2026-06-03", "0")]
    }

    private func monthly(_ start: String, _ end: String, _ amount: String, unit: String = "USD", estimated: Bool = false) -> CostExplorer.ResultByTime {
        .init(estimated: estimated, timePeriod: .init(end: end, start: start), total: ["UnblendedCost": .init(amount: amount, unit: unit)])
    }

    private func daily(_ date: String, _ groups: [(String, String)], unit: String = "USD", estimated: Bool = false) -> CostExplorer.ResultByTime {
        .init(
            estimated: estimated, groups: groups.map { .init(keys: [$0.0], metrics: ["UnblendedCost": .init(amount: $0.1, unit: unit)]) },
            timePeriod: .init(end: CostDates.string(CostDates.calendar.date(byAdding: .day, value: 1, to: self.date(date))!), start: date)
        )
    }

    private func assertFilter(_ filter: CostExplorer.Expression?, region: String?, file: StaticString = #filePath, line: UInt = #line) {
        let account: CostExplorer.Expression?
        if let region {
            XCTAssertEqual(filter?.and?.count, 2, file: file, line: line)
            account = filter?.and?.first
            XCTAssertEqual(filter?.and?.last?.dimensions?.key, .region, file: file, line: line)
            XCTAssertEqual(filter?.and?.last?.dimensions?.values, [region], file: file, line: line)
        } else {
            account = filter
            XCTAssertNil(filter?.and, file: file, line: line)
        }
        XCTAssertEqual(account?.dimensions?.key, .linkedAccount, file: file, line: line)
        XCTAssertEqual(account?.dimensions?.values, ["111122223333"], file: file, line: line)
    }

    private func assertCostError(
        _ expected: CostError, file: StaticString = #filePath, line: UInt = #line,
        operation: () async throws -> CostReport
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected CostError", file: file, line: line)
        } catch {
            guard let actual = error as? CostError else { return XCTFail("Unexpected error: \(error)", file: file, line: line) }
            switch (actual, expected) {
            case (.invalidResponse, .invalidResponse), (.invalidIdentity, .invalidIdentity),
                 (.unsupportedPartition, .unsupportedPartition), (.incompletePagination, .incompletePagination),
                 (.invalidQuery, .invalidQuery): break
            default: XCTFail("Wrong cost error: \(actual)", file: file, line: line)
            }
        }
    }
}

private actor CostStub {
    private var monthlyPages: [CostExplorer.GetCostAndUsageResponse]
    private var dailyPages: [CostExplorer.GetCostAndUsageResponse]
    private var dimensionPages: [CostExplorer.GetDimensionValuesResponse]
    private var costRequests: [CostExplorer.GetCostAndUsageRequest] = []
    private var dimensionRequests: [CostExplorer.GetDimensionValuesRequest] = []

    init(
        monthly: [CostExplorer.GetCostAndUsageResponse],
        daily: [CostExplorer.GetCostAndUsageResponse] = [],
        dimensions: [CostExplorer.GetDimensionValuesResponse] = [.init(dimensionValues: [], returnSize: 0, totalSize: 0)]
    ) {
        monthlyPages = monthly
        dailyPages = daily
        dimensionPages = dimensions
    }

    func cost(_ request: CostExplorer.GetCostAndUsageRequest) throws -> CostExplorer.GetCostAndUsageResponse {
        costRequests.append(request)
        if request.granularity == .monthly {
            guard !monthlyPages.isEmpty else { throw CostError.invalidResponse }
            return monthlyPages.removeFirst()
        }
        guard !dailyPages.isEmpty else { throw CostError.invalidResponse }
        return dailyPages.removeFirst()
    }

    func dimensions(_ request: CostExplorer.GetDimensionValuesRequest) throws -> CostExplorer.GetDimensionValuesResponse {
        dimensionRequests.append(request)
        guard !dimensionPages.isEmpty else { throw CostError.invalidResponse }
        return dimensionPages.removeFirst()
    }

    func requests() -> ([CostExplorer.GetCostAndUsageRequest], [CostExplorer.GetDimensionValuesRequest]) {
        (costRequests, dimensionRequests)
    }
}
