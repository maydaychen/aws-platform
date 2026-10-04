import Foundation

struct ELBField: Hashable, Sendable {
    let name: String
    let value: String
}

struct ELBLoadBalancer: Identifiable, Hashable, Sendable {
    let arn: String
    let name: String
    let kind: String
    var dnsName: String? = nil
    var canonicalHostedZoneID: String? = nil
    var securityGroupIDs: [String] = []
    var scheme: String? = nil
    var state: String? = nil
    var fields: [ELBField] = []
    var id: String { arn }
}

struct ELBTargetGroup: Identifiable, Hashable, Sendable {
    let arn: String
    let name: String
    let targetType: String
    var protocolName: String? = nil
    var port: Int? = nil
    var loadBalancerARNs: [String] = []
    var fields: [ELBField] = []
    var id: String { arn }
}

struct ELBForward: Hashable, Sendable {
    let targetGroupARN: String
    var weight: Int? = nil
}

struct ELBAction: Hashable, Sendable {
    let type: String
    var order: Int? = nil
    var forwards: [ELBForward] = []
    var fields: [ELBField] = []
}

struct ELBListener: Identifiable, Hashable, Sendable {
    let arn: String
    let loadBalancerARN: String
    let protocolName: String
    var port: Int? = nil
    var actions: [ELBAction] = []
    var fields: [ELBField] = []
    var id: String { arn }
    var supportsRules: Bool { arn.contains(":listener/app/") }
}

struct ELBRule: Identifiable, Hashable, Sendable {
    let arn: String
    let priority: String
    let isDefault: Bool
    var conditions: [ELBField] = []
    var actions: [ELBAction] = []
    var transforms: [ELBField] = []
    var id: String { arn }
}

struct ELBTargetHealth: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let targetID: String
        let port: Int?
        let availabilityZone: String?
    }
    let targetID: String
    var port: Int? = nil
    var availabilityZone: String? = nil
    let state: String
    var reason: String? = nil
    var description: String? = nil
    var fields: [ELBField] = []
    var id: ID { ID(targetID: targetID, port: port, availabilityZone: availabilityZone) }
}

struct ELBMembership: Identifiable, Hashable, Sendable {
    let group: ELBTargetGroup
    let targets: [ELBTargetHealth]
    var id: String { group.arn }
}

struct ELBMembershipResult: Equatable, Sendable {
    var matches: [ELBMembership] = []
    let checkedGroupCount: Int
    let totalGroupCount: Int
    var failures: [ELBField] = []
    var isComplete: Bool { failures.isEmpty && checkedGroupCount == totalGroupCount }
}

enum ELBError: LocalizedError, Equatable {
    case invalidScope, invalidResponse, incompletePagination
    var errorDescription: String? {
        switch self {
        case .invalidScope: return "Select and verify a profile in this account and region before loading load balancing resources."
        case .invalidResponse: return "Load balancing returned incomplete or mismatched data. Refresh to try again."
        case .incompletePagination: return "Load balancing pagination could not be completed. Partial results were not displayed. Refresh to try again."
        }
    }
}

enum ELBARN {
    static func resource(_ arn: String, scope: MonitoringScope) -> String? {
        guard scope.isValid else { return nil }
        let parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
        guard parts.count == 6, parts[0] == "arn", parts[1] == partition,
              parts[2] == "elasticloadbalancing", parts[3] == scope.region, parts[4] == scope.accountID,
              !parts[5].isEmpty, !arn.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(parts[5])
    }

    static func isLoadBalancer(_ arn: String, scope: MonitoringScope) -> Bool {
        guard let resource = resource(arn, scope: scope) else { return false }
        let parts = resource.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "loadbalancer" && ["app", "net", "gwy"].contains(parts[1])
            && parts.allSatisfy { !$0.isEmpty }
    }

    static func isTargetGroup(_ arn: String, scope: MonitoringScope) -> Bool {
        guard let resource = resource(arn, scope: scope) else { return false }
        let parts = resource.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "targetgroup" && parts.allSatisfy { !$0.isEmpty }
    }
}

struct ELBResourceReference: Hashable, Sendable {
    let scope: MonitoringScope
    let service: AWSService
    let resourceID: String
    let name: String
    let qualifier: String?

    init?(scope: MonitoringScope, service: AWSService, resourceID: String, name: String) {
        guard scope.isValid else { return nil }
        var qualifier: String?
        switch service {
        case .loadBalancers:
            guard ELBARN.isLoadBalancer(resourceID, scope: scope) else { return nil }
        case .targetGroups:
            guard ELBARN.isTargetGroup(resourceID, scope: scope) else { return nil }
        case .ec2:
            guard !resourceID.contains(where: { $0.isWhitespace || $0.isNewline }),
                  resourceID.range(of: "^i-(?:[0-9a-f]{8}|[0-9a-f]{17})$", options: .regularExpression) != nil else { return nil }
        case .lambda:
            let parts = resourceID.split(separator: ":", omittingEmptySubsequences: false)
            let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
            guard (parts.count == 7 || parts.count == 8), parts[0] == "arn", parts[1] == partition,
                  parts[2] == "lambda", parts[3] == scope.region, parts[4] == scope.accountID,
                  parts[5] == "function", !parts[6].isEmpty,
                  !resourceID.contains(where: { $0.isWhitespace || $0.isNewline }),
                  parts.count == 7 || !parts[7].isEmpty else { return nil }
            qualifier = parts.count == 8 ? String(parts[7]) : nil
        default: return nil
        }
        self.scope = scope
        self.service = service
        self.resourceID = resourceID
        self.name = name
        self.qualifier = qualifier
    }

    func isValid(in currentScope: MonitoringScope?) -> Bool {
        scope == currentScope && ELBResourceReference(scope: scope, service: service, resourceID: resourceID, name: name) == self
    }

    static func target(_ target: ELBTargetHealth, group: ELBTargetGroup, scope: MonitoringScope) -> Self? {
        guard ELBARN.isTargetGroup(group.arn, scope: scope), target.reason != "Target.NotRegistered" else { return nil }
        let service: AWSService
        switch group.targetType {
        case "instance": service = .ec2
        case "lambda": service = .lambda
        case "alb": service = .loadBalancers
        default: return nil
        }
        return Self(scope: scope, service: service, resourceID: target.targetID, name: target.targetID)
    }
}
