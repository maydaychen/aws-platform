import Foundation
import SotoCloudWatch
import XCTest
@testable import AWSPlatform

final class RDSMetricsTests: XCTestCase {
    func testRDSIdentifierValidationRejectsInvalidNamesAndUnsupportedClusters() {
        for engine in ["postgres", "aurora-postgresql", "mysql", "future-engine"] {
            XCTAssertTrue(ResourceMetricTarget.rdsInstance(identifier: "production-1", engine: engine).isValid)
        }
        XCTAssertTrue(ResourceMetricTarget.rdsCluster(identifier: "production", engine: "aurora-mysql").isValid)
        XCTAssertTrue(ResourceMetricTarget.rdsCluster(identifier: "production", engine: "aurora").isValid)
        for name in ["", "1production", "bad--name", "bad-", "bad:name", "bad\n", "bad name", String(repeating: "a", count: 64)] {
            XCTAssertFalse(ResourceMetricTarget.rdsInstance(identifier: name, engine: "postgres").isValid)
        }
        for engine in ["postgres", "mysql", "docdb", "neptune", "future-engine", nil] {
            XCTAssertFalse(ResourceMetricTarget.rdsCluster(identifier: "production", engine: engine).isValid)
        }
        XCTAssertFalse(ResourceMetricTarget.rdsInstance(identifier: "production", engine: "docdb").isValid)
        XCTAssertFalse(ResourceMetricTarget.rdsInstance(identifier: "production", engine: "neptune").isValid)
    }

    func testOrdinaryInstanceQueriesUseInstanceDimensionsAndStorageCapacity() async throws {
        let recorder = RDSMetricsRecorder()
        let target = ResourceMetricTarget.rdsInstance(identifier: "production", engine: "postgres")
        let snapshot = try await recorder.service.load(scope: rdsServiceScope(), target: target, range: .hour)
        let calls = await recorder.requests()
        let queries = try XCTUnwrap(calls.first?.metricDataQueries)
        XCTAssertEqual(queries.compactMap { $0.metricStat?.metric?.metricName },
                       ["CPUUtilization", "DatabaseConnections", "FreeableMemory", "ReadLatency", "WriteLatency", "FreeStorageSpace"])
        XCTAssertEqual(snapshot.series.map(\.unit), ["Percent", "Count", "Bytes", "Seconds", "Seconds", "Bytes"])
        try assertDimensions(queries, name: "DBInstanceIdentifier")
        XCTAssertTrue(queries.allSatisfy { $0.metricStat?.stat == "Average" })
    }

    func testAuroraInstancesDoNotMislabelLocalStorageAsDatabaseCapacity() async throws {
        let recorder = RDSMetricsRecorder()
        let target = ResourceMetricTarget.rdsInstance(identifier: "production", engine: "aurora-postgresql")
        let snapshot = try await recorder.service.load(scope: rdsServiceScope(), target: target, range: .day)
        let calls = await recorder.requests()
        let queries = try XCTUnwrap(calls.first?.metricDataQueries)
        let names = queries.compactMap { $0.metricStat?.metric?.metricName }
        XCTAssertEqual(names.count, 5)
        XCTAssertFalse(names.contains("FreeStorageSpace"))
        XCTAssertFalse(names.contains("FreeLocalStorage"))
        XCTAssertFalse(names.contains("VolumeBytesUsed"))
        XCTAssertEqual(snapshot.target, target)
        try assertDimensions(queries, name: "DBInstanceIdentifier")
    }

    func testAuroraClusterQueriesStorageMetricsWithoutInventingCPUOrMemoryAggregation() async throws {
        let recorder = RDSMetricsRecorder()
        let target = ResourceMetricTarget.rdsCluster(identifier: "production", engine: "aurora-mysql")
        let snapshot = try await recorder.service.load(scope: rdsServiceScope(), target: target, range: .sixHours)
        let calls = await recorder.requests()
        let queries = try XCTUnwrap(calls.first?.metricDataQueries)
        XCTAssertEqual(queries.compactMap { $0.metricStat?.metric?.metricName }, ["VolumeBytesUsed", "VolumeReadIOPs", "VolumeWriteIOPs"])
        XCTAssertEqual(queries.compactMap { $0.metricStat?.stat }, ["Average", "Sum", "Sum"])
        XCTAssertEqual(snapshot.series.map(\.unit), ["Bytes", "Count", "Count"])
        XCTAssertTrue(snapshot.series.allSatisfy { $0.points.isEmpty && $0.status == .missing })
        XCTAssertFalse(snapshot.isComplete)
        try assertDimensions(queries, name: "DBClusterIdentifier")
    }

    func testNonAuroraClustersAreRejectedBeforeAnyMetricRequest() async {
        let recorder = RDSMetricsRecorder()
        for engine in ["postgres", "mysql", nil] {
            do {
                _ = try await recorder.service.load(scope: rdsServiceScope(),
                    target: .rdsCluster(identifier: "production", engine: engine), range: .hour)
                XCTFail("Unsupported cluster metrics must not be queried")
            } catch { XCTAssertEqual((error as? ResourceMetricsError)?.localizedDescription, ResourceMetricsError.invalidContext.localizedDescription) }
        }
        let calls = await recorder.requests()
        XCTAssertTrue(calls.isEmpty)
    }

    func testDatabaseTargetRetainsKindAndEngineForScopeBoundSelection() {
        let instance = RDSInsightsFixture.database(engine: "aurora-postgresql")
        let cluster = RDSInsightsFixture.database(.cluster, engine: "aurora-postgresql")
        XCTAssertEqual(instance.metricTarget, .rdsInstance(identifier: "production", engine: "aurora-postgresql"))
        XCTAssertEqual(cluster.metricTarget, .rdsCluster(identifier: "production", engine: "aurora-postgresql"))
        XCTAssertNotEqual(instance.metricTarget, cluster.metricTarget)
    }

    private func assertDimensions(_ queries: [CloudWatch.MetricDataQuery], name: String) throws {
        XCTAssertFalse(queries.isEmpty)
        for query in queries {
            let metric = try XCTUnwrap(query.metricStat?.metric)
            XCTAssertEqual(metric.namespace, "AWS/RDS")
            XCTAssertEqual(query.accountId, "111122223333")
            XCTAssertEqual(query.metricStat?.period, 300)
            XCTAssertEqual(metric.dimensions?.count, 1)
            XCTAssertEqual(metric.dimensions?.first?.name, name)
            XCTAssertEqual(metric.dimensions?.first?.value, "production")
        }
    }
}

private actor RDSMetricsRecorder {
    private var recorded: [CloudWatch.GetMetricDataInput] = []
    func requests() -> [CloudWatch.GetMetricDataInput] { recorded }
    func load(_ input: CloudWatch.GetMetricDataInput) -> CloudWatch.GetMetricDataOutput {
        recorded.append(input)
        return .init()
    }
    nonisolated var service: AWSMetricsService {
        AWSMetricsService(pageLoader: { await self.load($0) }, now: { RDSInsightsFixture.now })
    }
}
