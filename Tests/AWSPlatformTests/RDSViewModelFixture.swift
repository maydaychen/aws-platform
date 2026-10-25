import Foundation
@testable import AWSPlatform

actor RDSStateProbe {
    private var calls: [RDSResourceKind: Int] = [:]
    private var completed: Set<String> = []
    private let gates: [String: TestGate]
    private let failures: Set<String>
    private let safeFailures: Set<String>
    private let cancellations: Set<String>
    private let rows: [String: [RDSDatabase]]

    init(gates: [String: TestGate] = [:], failures: Set<String> = [], safeFailures: Set<String> = [],
         cancellations: Set<String> = [], rows: [String: [RDSDatabase]] = [:]) {
        self.gates = gates
        self.failures = failures
        self.safeFailures = safeFailures
        self.cancellations = cancellations
        self.rows = rows
    }

    func counts() -> [Int] { [.instance, .cluster].map { calls[$0, default: 0] } }
    func finished(_ key: String) -> Bool { completed.contains(key) }

    func load(_ kind: RDSResourceKind, scope: MonitoringScope) async throws -> [RDSDatabase] {
        calls[kind, default: 0] += 1
        let key = "\(kind.rawValue)-\(calls[kind]!)"
        await gates[key]?.wait()
        completed.insert(key)
        if failures.contains(key) { throw NSError(domain: "secret-response-body", code: 1) }
        if safeFailures.contains(key) { throw RDSError.invalidResponse }
        if cancellations.contains(key) { throw CancellationError() }
        return rows[key] ?? [rdsStateDatabase("shared", kind: kind, scope: scope),
                             rdsStateDatabase("other-\(kind.rawValue)", kind: kind, scope: scope)]
    }
}

func rdsStateDatabase(_ name: String = "shared", kind: RDSResourceKind = .instance,
                      scope: MonitoringScope = rdsStateScope(), status: String = "available") -> RDSDatabase {
    let resource = kind == .instance ? "db" : "cluster"
    return RDSDatabase(arn: "arn:aws:rds:\(scope.region):\(scope.accountID):\(resource):\(name)",
                       identifier: name, kind: kind,
                       engine: kind == .instance ? "postgres" : "aurora-postgresql", status: status,
                       endpoint: "\(name).\(resource).example", readerEndpoint: kind == .cluster ? "reader.example" : nil)
}

func rdsStateScope(profile: String = "test", account: String = "111122223333", region: String = "us-east-1",
                   role: String = "ReadOnly", paths: AWSConfigurationPaths = AWSConfigurationPaths()) -> MonitoringScope {
    MonitoringScope(profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil,
                                        ssoAccountID: nil, ssoRoleName: nil),
                    identity: AWSIdentity(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/test", userID: "fixture"),
                    region: region, paths: paths)
}
