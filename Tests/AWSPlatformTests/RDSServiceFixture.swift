import Foundation
import SotoCore
import SotoRDS
@testable import AWSPlatform

struct RDSFixtureError: AWSErrorType {
    let errorCode: String
    var context: AWSErrorContext? { nil }
    var description: String { "\(errorCode): private-rds-token" }

    init(_ code: String) { errorCode = code }
    init?(errorCode: String, context: AWSErrorContext) { self.errorCode = errorCode }
}

func rdsServiceScope(account: String = "111122223333", region: String = "eu-west-1",
                     profile: String = "work", partition: String = "aws") -> MonitoringScope {
    MonitoringScope(
        profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
        identity: AWSIdentity(account: account, arn: "arn:\(partition):sts::\(account):assumed-role/Test/session", userID: "fixture"),
        region: region,
        paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/config", "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials"])
    )
}

func rdsInstance(_ identifier: String = "example", engine: String? = "postgres",
                 arn: String? = nil, tags: [RDS.Tag]? = nil) -> RDS.DBInstance {
    .init(dbInstanceArn: arn ?? "arn:aws:rds:eu-west-1:111122223333:db:\(identifier)",
          dbInstanceIdentifier: identifier, engine: engine, tagList: tags)
}

func rdsCluster(_ identifier: String = "example", engine: String? = "aurora-postgresql",
                arn: String? = nil, tags: [RDS.Tag]? = nil) -> RDS.DBCluster {
    .init(dbClusterArn: arn ?? "arn:aws:rds:eu-west-1:111122223333:cluster:\(identifier)",
          dbClusterIdentifier: identifier, engine: engine, tagList: tags)
}

actor RDSServiceFixture {
    enum Operation: Sendable { case instances, clusters }
    struct Requests: Sendable {
        var instances: [RDS.DescribeDBInstancesMessage] = []
        var clusters: [RDS.DescribeDBClustersMessage] = []
        var total: Int { instances.count + clusters.count }
    }

    private var calls = Requests()
    private let instancePages: [RDS.DBInstanceMessage]
    private let clusterPages: [RDS.DBClusterMessage]
    private let failOperation: Operation?
    private let failAt: Int
    private let failure: Error
    private let gate: RDSServiceRequestGate?

    init(instancePages: [RDS.DBInstanceMessage] = [.init()], clusterPages: [RDS.DBClusterMessage] = [.init()],
         failOperation: Operation? = nil, failAt: Int = 0,
         failure: Error = RDSFixtureError("AccessDeniedException"), gate: RDSServiceRequestGate? = nil) {
        self.instancePages = instancePages
        self.clusterPages = clusterPages
        self.failOperation = failOperation
        self.failAt = failAt
        self.failure = failure
        self.gate = gate
    }

    func requests() -> Requests { calls }

    func instances(_ input: RDS.DescribeDBInstancesMessage) async throws -> RDS.DBInstanceMessage {
        let index = calls.instances.count
        calls.instances.append(input)
        try await check(.instances, index: index)
        return index < instancePages.count ? instancePages[index] : .init()
    }

    func clusters(_ input: RDS.DescribeDBClustersMessage) async throws -> RDS.DBClusterMessage {
        let index = calls.clusters.count
        calls.clusters.append(input)
        try await check(.clusters, index: index)
        return index < clusterPages.count ? clusterPages[index] : .init()
    }

    private func check(_ operation: Operation, index: Int) async throws {
        if let gate { await gate.enter() }
        if failOperation == operation, failAt == index { throw failure }
    }

    nonisolated var service: AWSRDSService {
        AWSRDSService(instanceLoader: { try await self.instances($0) }, clusterLoader: { try await self.clusters($0) })
    }
}

actor RDSServiceRequestGate {
    private var entered = false
    private var opened = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiting: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if !opened { await withCheckedContinuation { waiting = $0 } }
    }

    func waitForEntry() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }
}
