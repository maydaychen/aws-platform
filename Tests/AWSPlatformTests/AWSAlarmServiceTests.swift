import Foundation
import SotoCore
import SotoCloudWatch
import XCTest
@testable import AWSPlatform

final class AWSAlarmServiceTests: XCTestCase {
    func testBothAlarmTypesAreRequestedAndAllPagesAreMapped() async throws {
        let updated = Date(timeIntervalSince1970: 1_780_000_000)
        let metric = CloudWatch.MetricAlarm(
            actionsEnabled: false, alarmActions: ["arn:aws:automate:us-east-1:ec2:stop"],
            alarmArn: arn("CPU"), alarmConfigurationUpdatedTimestamp: updated, alarmDescription: "CPU alarm",
            alarmName: "CPU", comparisonOperator: .greaterThanThreshold, datapointsToAlarm: 2,
            dimensions: [.init(name: "InstanceId", value: "i-example")],
            evaluateLowSampleCountPercentile: "ignore", evaluationPeriods: 3, evaluationState: .partialData,
            extendedStatistic: "p99", insufficientDataActions: ["arn:aws:sns:us-east-1:111122223333:no-data"],
            metricName: "CPUUtilization", namespace: "AWS/EC2",
            okActions: ["arn:aws:sns:us-east-1:111122223333:recovery"], period: 60, stateReason: "Threshold crossed",
            stateReasonData: "{\"version\":\"1.0\"}", stateTransitionedTimestamp: updated,
            stateUpdatedTimestamp: updated, stateValue: .alarm, threshold: 80, treatMissingData: "notBreaching", unit: .percent
        )
        let composite = CloudWatch.CompositeAlarm(
            actionsEnabled: true, actionsSuppressedBy: .waitPeriod, actionsSuppressedReason: "Waiting",
            actionsSuppressor: arn("Maintenance"), actionsSuppressorExtensionPeriod: 120, actionsSuppressorWaitPeriod: 60,
            alarmActions: ["arn:aws:sns:us-east-1:111122223333:operations"],
            alarmArn: arn("Composite"), alarmConfigurationUpdatedTimestamp: updated, alarmName: "Composite",
            alarmRule: "ALARM(\"CPU\") AND NOT ALARM(\"Maintenance\")",
            stateReason: "Child alarm changed", stateUpdatedTimestamp: updated, stateValue: .ok
        )
        let stub = AlarmStub(alarmPages: [
            .init(metricAlarms: [metric], nextToken: "page-2"), .init(compositeAlarms: [composite])
        ])
        let alarms = try await service(stub).loadAlarms(scope: scope())

        XCTAssertEqual(alarms.map(\.name), ["CPU", "Composite"])
        let cpu = try XCTUnwrap(alarms.first)
        XCTAssertEqual(cpu.kind, .metric)
        XCTAssertEqual(cpu.state, "ALARM")
        XCTAssertEqual(cpu.description, "CPU alarm")
        XCTAssertEqual(cpu.reason, "Threshold crossed")
        XCTAssertEqual(cpu.reasonData, "{\"version\":\"1.0\"}")
        XCTAssertEqual(cpu.stateUpdatedAt, updated)
        XCTAssertEqual(cpu.stateTransitionedAt, updated)
        XCTAssertEqual(cpu.configurationUpdatedAt, updated)
        XCTAssertEqual(cpu.actionsEnabled, false)
        XCTAssertEqual(cpu.alarmActions, ["arn:aws:automate:us-east-1:ec2:stop"])
        XCTAssertEqual(cpu.okActions.count, 1)
        XCTAssertEqual(cpu.insufficientDataActions.count, 1)
        XCTAssertEqual(cpu.metrics.first?.metricName, "CPUUtilization")
        XCTAssertEqual(cpu.metrics.first?.namespace, "AWS/EC2")
        XCTAssertEqual(cpu.metrics.first?.dimensions, [.init(label: "InstanceId", value: "i-example")])
        XCTAssertEqual(cpu.metrics.first?.statistic, "p99")
        XCTAssertEqual(cpu.metrics.first?.period, 60)
        XCTAssertEqual(cpu.metrics.first?.unit, "Percent")
        let configuration = Dictionary(uniqueKeysWithValues: cpu.configuration.map { ($0.label, $0.value) })
        XCTAssertEqual(configuration["Comparison"], "GreaterThanThreshold")
        XCTAssertEqual(configuration["Threshold"], "80.0")
        XCTAssertEqual(configuration["Datapoints to alarm"], "2")
        XCTAssertEqual(configuration["Evaluation periods"], "3")
        XCTAssertEqual(configuration["Treat missing data"], "notBreaching")
        XCTAssertEqual(configuration["Evaluation state"], "PARTIAL_DATA")

        let combined = try XCTUnwrap(alarms.last)
        XCTAssertEqual(combined.kind, .composite)
        XCTAssertEqual(combined.rule, "ALARM(\"CPU\") AND NOT ALARM(\"Maintenance\")")
        XCTAssertEqual(combined.configuration.first { $0.label == "Actions suppressor" }?.value, arn("Maintenance"))
        XCTAssertEqual(combined.configuration.first { $0.label == "Suppression wait (seconds)" }?.value, "60")
        XCTAssertEqual(combined.configuration.first { $0.label == "Suppression extension (seconds)" }?.value, "120")
        XCTAssertEqual(combined.configuration.first { $0.label == "Actions suppressed by" }?.value, "WaitPeriod")

        let requests = await stub.requests()
        XCTAssertEqual(requests.alarms.map(\.nextToken), [nil, "page-2"])
        for request in requests.alarms {
            XCTAssertEqual(request.alarmTypes, [.metricAlarm, .compositeAlarm])
            XCTAssertEqual(request.maxRecords, 100)
            XCTAssertNil(request.alarmNames)
            XCTAssertNil(request.alarmNamePrefix)
            XCTAssertNil(request.stateValue)
        }
        XCTAssertTrue(requests.tags.isEmpty)
        XCTAssertTrue(requests.history.isEmpty)
    }

    func testMetricMathAndInsightsQueriesPreserveDimensionsAndExpressions() async throws {
        let metric = CloudWatch.MetricAlarm(
            alarmArn: arn("Math"), alarmName: "Math", metrics: [
                .init(accountId: "444455556666", id: "m1", label: "Source metric",
                      metricStat: .init(metric: .init(dimensions: [.init(name: "FunctionName", value: "worker")],
                                                      metricName: "Errors", namespace: "AWS/Lambda"),
                                        period: 60, stat: "Sum", unit: .count),
                      returnData: false),
                .init(expression: "SUM([m1])", id: "e1", label: "Error sum", period: 60, returnData: true),
                .init(expression: "SELECT MAX(CPUUtilization) FROM SCHEMA(\"AWS/EC2\", InstanceId)", id: "q1", returnData: false)
            ], thresholdMetricId: "e1"
        )
        let stub = AlarmStub(alarmPages: [.init(metricAlarms: [metric])])
        let alarms = try await service(stub).loadAlarms(scope: scope())
        let queries = try XCTUnwrap(alarms.first).metrics

        XCTAssertEqual(queries.map(\.id), ["m1", "e1", "q1"])
        XCTAssertEqual(queries[0].accountID, "444455556666")
        XCTAssertEqual(queries[0].label, "Source metric")
        XCTAssertEqual(queries[0].namespace, "AWS/Lambda")
        XCTAssertEqual(queries[0].metricName, "Errors")
        XCTAssertEqual(queries[0].statistic, "Sum")
        XCTAssertEqual(queries[0].dimensions, [.init(label: "FunctionName", value: "worker")])
        XCTAssertEqual(queries[0].returnData, false)
        XCTAssertEqual(queries[1].expression, "SUM([m1])")
        XCTAssertEqual(queries[1].returnData, true)
        XCTAssertEqual(queries[1].period, 60)
        XCTAssertTrue(queries[2].expression?.contains("SELECT MAX") == true)
        XCTAssertEqual(alarms[0].configuration.first { $0.label == "Threshold metric ID" }?.value, "e1")
    }

    func testMissingOptionalFieldsRemainUnknownAndColonInAlarmNameIsValid() async throws {
        let stub = AlarmStub(alarmPages: [.init(metricAlarms: [.init(alarmArn: arn("db:cpu"), alarmName: "db:cpu")])])
        let alarms = try await service(stub).loadAlarms(scope: scope())

        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms[0].name, "db:cpu")
        XCTAssertEqual(alarms[0].state, "Unknown")
        XCTAssertNil(alarms[0].actionsEnabled)
        XCTAssertNil(alarms[0].reason)
        XCTAssertNil(alarms[0].stateUpdatedAt)
        XCTAssertTrue(alarms[0].configuration.isEmpty)
        XCTAssertTrue(alarms[0].metrics.isEmpty)
    }

    func testRejectsWrongAccountRegionPartitionAndNameWithoutFollowingResponseARN() async {
        let invalidARNs = [
            "arn:aws:cloudwatch:us-east-1:999988887777:alarm:CPU",
            "arn:aws:cloudwatch:eu-west-1:111122223333:alarm:CPU",
            "arn:aws-cn:cloudwatch:us-east-1:111122223333:alarm:CPU",
            arn("CPU") + ":different", "not-an-arn"
        ]
        for invalid in invalidARNs {
            let stub = AlarmStub(alarmPages: [.init(metricAlarms: [.init(alarmArn: invalid, alarmName: "CPU")])])
            await assertAlarmError(.invalidResponse) { _ = try await self.service(stub).loadAlarms(scope: self.scope()) }
            let requests = await stub.requests()
            XCTAssertEqual(requests.alarms.count, 1)
            XCTAssertTrue(requests.tags.isEmpty)
            XCTAssertTrue(requests.history.isEmpty)
        }
        for metric in [CloudWatch.MetricAlarm(alarmName: "CPU"), .init(alarmArn: arn("CPU")), .init(alarmArn: arn(""), alarmName: "")] {
            let stub = AlarmStub(alarmPages: [.init(metricAlarms: [metric])])
            await assertAlarmError(.invalidResponse) { _ = try await self.service(stub).loadAlarms(scope: self.scope()) }
        }
    }

    func testDuplicateARNOrMalformedMetricQueriesRejectWholeList() async {
        let duplicate = CloudWatch.MetricAlarm(alarmArn: arn("CPU"), alarmName: "CPU")
        let pages: [[CloudWatch.DescribeAlarmsOutput]] = [
            [.init(metricAlarms: [duplicate], nextToken: "next"), .init(metricAlarms: [duplicate])],
            [CloudWatch.DescribeAlarmsOutput(metricAlarms: [
                .init(alarmArn: arn("CPU"), alarmName: "CPU", metrics: [.init(expression: "1")])
            ])],
            [.init(metricAlarms: [
                .init(alarmArn: arn("CPU"), alarmName: "CPU",
                      metrics: [.init(expression: "1", id: "e1"), .init(expression: "2", id: "e1")])
            ])]
        ]
        for responses in pages {
            let stub = AlarmStub(alarmPages: responses)
            await assertAlarmError(.invalidResponse) { _ = try await self.service(stub).loadAlarms(scope: self.scope()) }
        }
    }

    func testListPaginationCycleAndLimitDoNotReturnPartialLists() async {
        let cases: [[CloudWatch.DescribeAlarmsOutput]] = [
            [.init(nextToken: "again"), .init(nextToken: "again")],
            (1...100).map { .init(nextToken: "page-\($0)") }
        ]
        for pages in cases {
            let stub = AlarmStub(alarmPages: pages)
            await assertAlarmError(.incompletePagination) { _ = try await self.service(stub).loadAlarms(scope: self.scope()) }
            let requests = await stub.requests()
            XCTAssertEqual(requests.alarms.count, pages.count)
        }
    }

    func testTagsQueryOnlySelectedARNAndPreserveEmptyValues() async throws {
        let stub = AlarmStub(tagResponse: .init(tags: [.init(key: "Owner", value: "team"), .init(key: "Empty", value: "")]))
        let tags = try await service(stub).loadTags(scope: scope(), alarm: alarm("db:cpu"))

        XCTAssertEqual(tags, ["Owner": "team", "Empty": ""])
        let requests = await stub.requests()
        XCTAssertEqual(requests.tags.map(\.resourceARN), [arn("db:cpu")])
        XCTAssertTrue(requests.alarms.isEmpty)
        XCTAssertTrue(requests.history.isEmpty)
    }

    func testTagsRejectMalformedAndDuplicateEntries() async {
        for tags in [
            [CloudWatch.Tag(key: nil, value: "value")],
            [.init(key: "Owner", value: nil)],
            [.init(key: "Owner", value: "first"), .init(key: "Owner", value: "second")]
        ] {
            let stub = AlarmStub(tagResponse: .init(tags: tags))
            await assertAlarmError(.invalidResponse) { _ = try await self.service(stub).loadTags(scope: self.scope(), alarm: self.alarm()) }
        }
    }

    func testHistoryUsesThirtyDayDescendingWindowAndKeepsIdenticalRecords() async throws {
        let end = Date(timeIntervalSince1970: 1_780_000_000)
        let older = end.addingTimeInterval(-200)
        let newer = end.addingTimeInterval(-50)
        let duplicate = CloudWatch.AlarmHistoryItem(
            alarmContributorId: "contributor-1", alarmName: "CPU", alarmType: .metricAlarm,
            historyData: "{\"state\":\"ALARM\"}", historyItemType: .stateUpdate,
            historySummary: "State changed", timestamp: newer
        )
        let stub = AlarmStub(historyPages: [
            .init(alarmHistoryItems: [
                .init(alarmName: "CPU", alarmType: .metricAlarm, historyItemType: .configurationUpdate,
                      historySummary: "Configured", timestamp: older), duplicate
            ], nextToken: "next"),
            .init(alarmHistoryItems: [duplicate, .init(alarmName: "CPU")])
        ])
        let history = try await service(stub, now: end).loadHistory(scope: scope(), alarm: alarm())

        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(Set(history.map(\.id)).count, 4)
        XCTAssertEqual(history.map(\.timestamp), [newer, newer, older, nil])
        XCTAssertEqual(history[0].type, "StateUpdate")
        XCTAssertEqual(history[0].summary, "State changed")
        XCTAssertEqual(history[0].data, "{\"state\":\"ALARM\"}")
        XCTAssertEqual(history[0].contributorID, "contributor-1")
        XCTAssertEqual(history.last?.type, "Unknown")
        let requests = await stub.requests()
        XCTAssertEqual(requests.history.map(\.nextToken), [nil, "next"])
        for request in requests.history {
            XCTAssertEqual(request.alarmName, "CPU")
            XCTAssertEqual(request.alarmTypes, [.metricAlarm])
            XCTAssertEqual(request.scanBy, .timestampDescending)
            XCTAssertEqual(request.startDate, end.addingTimeInterval(-30 * 24 * 60 * 60))
            XCTAssertEqual(request.endDate, end)
            XCTAssertEqual(request.maxRecords, 100)
            XCTAssertNil(request.historyItemType)
            XCTAssertNil(request.alarmContributorId)
        }
        XCTAssertTrue(requests.tags.isEmpty)
        XCTAssertTrue(requests.alarms.isEmpty)
    }

    func testCompositeHistoryIsExplicitAndRejectsWrongAlarmOrOutsideWindow() async throws {
        let end = Date(timeIntervalSince1970: 1_780_000_000)
        let emptyStub = AlarmStub(historyPages: [.init(alarmHistoryItems: [])])
        let composite = CloudWatchAlarm(arn: arn("Combined"), name: "Combined", kind: .composite, state: "OK")
        _ = try await service(emptyStub, now: end).loadHistory(scope: scope(), alarm: composite)
        let emptyRequests = await emptyStub.requests()
        XCTAssertEqual(emptyRequests.history.first?.alarmTypes, [.compositeAlarm])

        let invalid: [CloudWatch.AlarmHistoryItem] = [
            .init(alarmName: "different"), .init(alarmName: "Combined", alarmType: .metricAlarm),
            .init(alarmName: "Combined", timestamp: end.addingTimeInterval(1)),
            .init(alarmName: "Combined", timestamp: end.addingTimeInterval(-31 * 24 * 60 * 60))
        ]
        for item in invalid {
            let stub = AlarmStub(historyPages: [.init(alarmHistoryItems: [item])])
            await assertAlarmError(.invalidResponse) { _ = try await self.service(stub, now: end).loadHistory(scope: self.scope(), alarm: composite) }
        }
    }

    func testHistoryPaginationCycleAndPageLimitRejectIncompleteHistory() async {
        let cases: [[CloudWatch.DescribeAlarmHistoryOutput]] = [
            [.init(nextToken: "again"), .init(nextToken: "again")],
            (1...100).map { .init(nextToken: "page-\($0)") }
        ]
        for pages in cases {
            let stub = AlarmStub(historyPages: pages)
            await assertAlarmError(.incompletePagination) { _ = try await self.service(stub).loadHistory(scope: self.scope(), alarm: self.alarm()) }
            let requests = await stub.requests()
            XCTAssertEqual(requests.history.count, pages.count)
        }
    }

    func testInvalidScopeAndSelectedAlarmNeverIssueRequests() async {
        let stub = AlarmStub()
        let service = service(stub)
        for invalid in [
            scope(account: "-"), scope(region: ""), scope(partition: "aws-cn"), scope(region: "cn-north-1", partition: "aws--cn"),
            scope(account: "111122223333", principal: "arn:aws:sts::999988887777:assumed-role/Test/session")
        ] {
            await assertAlarmError(.invalidScope) { _ = try await service.loadAlarms(scope: invalid) }
        }
        let selected = CloudWatchAlarm(arn: arn("CPU", region: "eu-west-1"), name: "CPU", kind: .metric, state: "OK")
        await assertAlarmError(.invalidResponse) { _ = try await service.loadTags(scope: self.scope(), alarm: selected) }
        await assertAlarmError(.invalidResponse) { _ = try await service.loadHistory(scope: self.scope(), alarm: selected) }
        let requests = await stub.requests()
        XCTAssertTrue(requests.alarms.isEmpty)
        XCTAssertTrue(requests.tags.isEmpty)
        XCTAssertTrue(requests.history.isEmpty)
    }

    func testChinaAndGovCloudAlarmARNsMatchTheirSelectedRegionPartition() async throws {
        for (partition, region) in [("aws-cn", "cn-north-1"), ("aws-us-gov", "us-gov-west-1")] {
            let alarmARN = "arn:\(partition):cloudwatch:\(region):111122223333:alarm:CPU"
            let stub = AlarmStub(alarmPages: [.init(metricAlarms: [.init(alarmArn: alarmARN, alarmName: "CPU")])])
            let results = try await service(stub).loadAlarms(scope: scope(region: region, partition: partition))
            XCTAssertEqual(results.map(\.arn), [alarmARN])
        }
    }

    func testCancellationAfterEachOperationDoesNotPublishResponse() async {
        for operation in ["list", "tags", "history"] {
            let gate = TestGate()
            let service = AWSAlarmService(
                alarmLoader: { _ in await gate.wait(); return .init() },
                tagLoader: { _ in await gate.wait(); return .init() },
                historyLoader: { _ in await gate.wait(); return .init() }
            )
            let scope = scope()
            let alarm = alarm()
            let task = Task {
                switch operation {
                case "list": _ = try await service.loadAlarms(scope: scope)
                case "tags": _ = try await service.loadTags(scope: scope, alarm: alarm)
                default: _ = try await service.loadHistory(scope: scope, alarm: alarm)
                }
            }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do {
                try await task.value
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testOperationSpecificPermissionErrorsDoNotDowngradeAlarmTypes() async {
        let stub = AlarmStub(failure: AWSResponseError(errorCode: "AccessDenied"))
        let service = service(stub)
        await assertRequestError(.listPermission) { _ = try await service.loadAlarms(scope: self.scope()) }
        await assertRequestError(.tagsPermission) { _ = try await service.loadTags(scope: self.scope(), alarm: self.alarm()) }
        await assertRequestError(.historyPermission) { _ = try await service.loadHistory(scope: self.scope(), alarm: self.alarm()) }

        let requests = await stub.requests()
        XCTAssertEqual(requests.alarms.count, 1, "Access denied must not silently retry metric-only")
        XCTAssertEqual(requests.alarms.first?.alarmTypes, [.metricAlarm, .compositeAlarm])
        XCTAssertTrue(AWSAlarmService.RequestError.listPermission.localizedDescription.contains("cloudwatch:DescribeAlarms"))
        XCTAssertTrue(AWSAlarmService.RequestError.tagsPermission.localizedDescription.contains("cloudwatch:ListTagsForResource"))
        XCTAssertTrue(AWSAlarmService.RequestError.historyPermission.localizedDescription.contains("cloudwatch:DescribeAlarmHistory"))
        XCTAssertTrue(AWSAlarmService.RequestError.listPermission.localizedDescription.contains("Resource: *"))
    }

    func testNetworkCredentialThrottleAndUnknownErrorsAreSanitized() async {
        let cases: [(Error, AWSAlarmService.RequestError)] = [
            (URLError(.notConnectedToInternet), .network),
            (AWSResponseError(errorCode: "ExpiredToken"), .credentials),
            (AWSResponseError(errorCode: "ThrottlingException"), .throttled),
            (NSError(domain: "private-credential-output", code: 1), .failed),
            (AWSResponseError(errorCode: "ValidationError"), .failed)
        ]
        for (failure, expected) in cases {
            let stub = AlarmStub(failure: failure)
            await assertRequestError(expected) { _ = try await self.service(stub).loadAlarms(scope: self.scope()) }
        }
    }

    private func service(_ stub: AlarmStub, now: Date = Date(timeIntervalSince1970: 1_780_000_000)) -> AWSAlarmService {
        AWSAlarmService(
            alarmLoader: { try await stub.alarms($0) }, tagLoader: { try await stub.tags($0) },
            historyLoader: { try await stub.history($0) }, now: { now }
        )
    }

    private func arn(_ name: String, region: String = "us-east-1") -> String {
        "arn:aws:cloudwatch:\(region):111122223333:alarm:\(name)"
    }

    private func alarm(_ name: String = "CPU") -> CloudWatchAlarm {
        CloudWatchAlarm(arn: arn(name), name: name, kind: .metric, state: "ALARM")
    }

    private func scope(
        account: String = "111122223333", region: String = "us-east-1", partition: String = "aws", principal: String? = nil
    ) -> AlarmScope {
        AlarmScope(
            profile: AWSProfile(name: "work", region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
            identity: AWSIdentity(account: account, arn: principal ?? "arn:\(partition):sts::\(account):assumed-role/Test/session", userID: "example"),
            region: region,
            paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/config", "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials"])
        )
    }

    private func assertAlarmError(
        _ expected: AlarmError, file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected AlarmError", file: file, line: line)
        } catch {
            guard let actual = error as? AlarmError else { return XCTFail("Unexpected error: \(error)", file: file, line: line) }
            switch (actual, expected) {
            case (.invalidScope, .invalidScope), (.invalidResponse, .invalidResponse), (.incompletePagination, .incompletePagination): break
            default: XCTFail("Wrong alarm error: \(actual)", file: file, line: line)
            }
        }
    }

    private func assertRequestError(
        _ expected: AWSAlarmService.RequestError, file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected request error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AWSAlarmService.RequestError, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("private-credential-output"), file: file, line: line)
        }
    }
}

private actor AlarmStub {
    private var alarmPages: [CloudWatch.DescribeAlarmsOutput]
    private var tagResponse: CloudWatch.ListTagsForResourceOutput
    private var historyPages: [CloudWatch.DescribeAlarmHistoryOutput]
    private var failure: Error?
    private var alarmRequests: [CloudWatch.DescribeAlarmsInput] = []
    private var tagRequests: [CloudWatch.ListTagsForResourceInput] = []
    private var historyRequests: [CloudWatch.DescribeAlarmHistoryInput] = []

    init(
        alarmPages: [CloudWatch.DescribeAlarmsOutput] = [],
        tagResponse: CloudWatch.ListTagsForResourceOutput = .init(),
        historyPages: [CloudWatch.DescribeAlarmHistoryOutput] = [], failure: Error? = nil
    ) {
        self.alarmPages = alarmPages
        self.tagResponse = tagResponse
        self.historyPages = historyPages
        self.failure = failure
    }

    func alarms(_ request: CloudWatch.DescribeAlarmsInput) throws -> CloudWatch.DescribeAlarmsOutput {
        alarmRequests.append(request)
        if let failure { throw failure }
        guard !alarmPages.isEmpty else { throw AlarmError.invalidResponse }
        return alarmPages.removeFirst()
    }

    func tags(_ request: CloudWatch.ListTagsForResourceInput) throws -> CloudWatch.ListTagsForResourceOutput {
        tagRequests.append(request)
        if let failure { throw failure }
        return tagResponse
    }

    func history(_ request: CloudWatch.DescribeAlarmHistoryInput) throws -> CloudWatch.DescribeAlarmHistoryOutput {
        historyRequests.append(request)
        if let failure { throw failure }
        guard !historyPages.isEmpty else { throw AlarmError.invalidResponse }
        return historyPages.removeFirst()
    }

    func requests() -> (
        alarms: [CloudWatch.DescribeAlarmsInput], tags: [CloudWatch.ListTagsForResourceInput],
        history: [CloudWatch.DescribeAlarmHistoryInput]
    ) {
        (alarmRequests, tagRequests, historyRequests)
    }
}
