import Darwin
import Foundation
import SotoCore
import SotoElasticLoadBalancingV2

struct AWSELBService: Sendable {
    typealias LoadBalancerLoader = @Sendable (ElasticLoadBalancingV2.DescribeLoadBalancersInput) async throws -> ElasticLoadBalancingV2.DescribeLoadBalancersOutput
    typealias TargetGroupLoader = @Sendable (ElasticLoadBalancingV2.DescribeTargetGroupsInput) async throws -> ElasticLoadBalancingV2.DescribeTargetGroupsOutput
    typealias ListenerLoader = @Sendable (ElasticLoadBalancingV2.DescribeListenersInput) async throws -> ElasticLoadBalancingV2.DescribeListenersOutput
    typealias RuleLoader = @Sendable (ElasticLoadBalancingV2.DescribeRulesInput) async throws -> ElasticLoadBalancingV2.DescribeRulesOutput
    typealias HealthLoader = @Sendable (ElasticLoadBalancingV2.DescribeTargetHealthInput) async throws -> ElasticLoadBalancingV2.DescribeTargetHealthOutput
    private typealias SDK = ElasticLoadBalancingV2

    private struct Operations: Sendable {
        let loadBalancers: LoadBalancerLoader
        let targetGroups: TargetGroupLoader
        let listeners: ListenerLoader
        let rules: RuleLoader
        let health: HealthLoader
    }

    private let provider: AWSServiceProvider?
    private let injected: Operations?

    init(provider: AWSServiceProvider) {
        self.provider = provider
        injected = nil
    }

    init(loadBalancerLoader: @escaping LoadBalancerLoader, targetGroupLoader: @escaping TargetGroupLoader,
         listenerLoader: @escaping ListenerLoader, ruleLoader: @escaping RuleLoader, healthLoader: @escaping HealthLoader) {
        provider = nil
        injected = Operations(loadBalancers: loadBalancerLoader, targetGroups: targetGroupLoader,
                              listeners: listenerLoader, rules: ruleLoader, health: healthLoader)
    }

    func loadLoadBalancers(scope: MonitoringScope) async throws -> [ELBLoadBalancer] {
        do {
            let operations = try await operations(scope: scope)
            let values = try await Self.pages { marker in
                let response = try await operations.loadBalancers(.init(marker: marker, pageSize: 400))
                try Task.checkCancellation()
                return (try (response.loadBalancers ?? []).map { try Self.map($0, scope: scope) }, response.nextMarker)
            }
            return values.sorted { $0.name == $1.name ? $0.arn < $1.arn : $0.name < $1.name }
        } catch { throw Self.sanitized(error, operation: .loadBalancers) }
    }

    func loadTargetGroups(scope: MonitoringScope, loadBalancerARN: String? = nil) async throws -> [ELBTargetGroup] {
        do {
            try Self.validate(scope)
            if let loadBalancerARN, !ELBARN.isLoadBalancer(loadBalancerARN, scope: scope) { throw ELBError.invalidResponse }
            let operations = try await operations(scope: scope)
            let values = try await Self.pages { marker in
                let response = try await operations.targetGroups(.init(loadBalancerArn: loadBalancerARN, marker: marker, pageSize: 400))
                try Task.checkCancellation()
                let groups = try (response.targetGroups ?? []).map { try Self.map($0, scope: scope) }
                if let loadBalancerARN, groups.contains(where: { !$0.loadBalancerARNs.contains(loadBalancerARN) }) { throw ELBError.invalidResponse }
                return (groups, response.nextMarker)
            }
            return values.sorted { $0.name == $1.name ? $0.arn < $1.arn : $0.name < $1.name }
        } catch { throw Self.sanitized(error, operation: .targetGroups) }
    }

    func loadListeners(scope: MonitoringScope, loadBalancer: ELBLoadBalancer) async throws -> [ELBListener] {
        do {
            try Self.validate(scope)
            guard ELBARN.isLoadBalancer(loadBalancer.arn, scope: scope) else { throw ELBError.invalidResponse }
            let operations = try await operations(scope: scope)
            return try await Self.pages { marker in
                let response = try await operations.listeners(.init(loadBalancerArn: loadBalancer.arn, marker: marker, pageSize: 400))
                try Task.checkCancellation()
                return (try (response.listeners ?? []).map { try Self.map($0, parent: loadBalancer.arn, scope: scope) }, response.nextMarker)
            }
        } catch { throw Self.sanitized(error, operation: .listeners) }
    }

    func loadRules(scope: MonitoringScope, listener: ELBListener) async throws -> [ELBRule] {
        do {
            try Self.validate(scope)
            try Self.validateListener(listener.arn, parent: listener.loadBalancerARN, scope: scope)
            guard listener.supportsRules else { throw ELBError.invalidResponse }
            let operations = try await operations(scope: scope)
            let rules = try await Self.pages { marker in
                let response = try await operations.rules(.init(listenerArn: listener.arn, marker: marker, pageSize: 400))
                try Task.checkCancellation()
                return (try (response.rules ?? []).map { try Self.map($0, parent: listener.arn, scope: scope) }, response.nextMarker)
            }
            return rules.sorted {
                if $0.isDefault != $1.isDefault { return !$0.isDefault }
                let first = Int($0.priority) ?? Int.max
                let second = Int($1.priority) ?? Int.max
                return first == second ? $0.arn < $1.arn : first < second
            }
        } catch { throw Self.sanitized(error, operation: .rules) }
    }

    func loadTargetHealth(scope: MonitoringScope, group: ELBTargetGroup) async throws -> [ELBTargetHealth] {
        do {
            try Self.validate(scope)
            guard ELBARN.isTargetGroup(group.arn, scope: scope), ["instance", "ip", "lambda", "alb"].contains(group.targetType) else {
                throw ELBError.invalidResponse
            }
            let operations = try await operations(scope: scope)
            try Task.checkCancellation()
            let response = try await operations.health(.init(include: [.all], targetGroupArn: group.arn))
            try Task.checkCancellation()
            var ids: Set<ELBTargetHealth.ID> = []
            let targets = try (response.targetHealthDescriptions ?? []).map { raw in
                let target = try Self.map(raw, group: group, scope: scope)
                guard ids.insert(target.id).inserted else { throw ELBError.invalidResponse }
                return target
            }
            try Task.checkCancellation()
            return targets
        } catch { throw Self.sanitized(error, operation: .health) }
    }

    private struct MembershipCheck: Sendable {
        let group: ELBTargetGroup
        let targets: [ELBTargetHealth]
        let failure: String?
    }

    func loadInstanceMembership(scope: MonitoringScope, instanceID: String) async throws -> ELBMembershipResult {
        try Self.validate(scope)
        guard Self.isInstanceID(instanceID) else { throw ELBError.invalidResponse }
        let groups = try await loadTargetGroups(scope: scope).filter { $0.targetType == "instance" }
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: MembershipCheck.self) { tasks in
            var next = 0
            func add(_ group: ELBTargetGroup) {
                tasks.addTask {
                    do {
                        let targets = try await loadTargetHealth(scope: scope, group: group)
                        return MembershipCheck(group: group, targets: targets.filter {
                            $0.targetID == instanceID && $0.reason != "Target.NotRegistered"
                        }, failure: nil)
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        return MembershipCheck(group: group, targets: [], failure: Self.sanitized(error, operation: .health).localizedDescription)
                    }
                }
            }
            while next < min(4, groups.count) { add(groups[next]); next += 1 }
            var matches: [ELBMembership] = []
            var failures: [ELBField] = []
            var checked = 0
            while let result = try await tasks.next() {
                try Task.checkCancellation()
                if let failure = result.failure { failures.append(.init(name: result.group.name, value: failure)) }
                else {
                    checked += 1
                    if !result.targets.isEmpty { matches.append(.init(group: result.group, targets: result.targets)) }
                }
                if next < groups.count { add(groups[next]); next += 1 }
            }
            try Task.checkCancellation()
            return ELBMembershipResult(matches: matches.sorted { $0.group.arn < $1.group.arn }, checkedGroupCount: checked,
                                       totalGroupCount: groups.count, failures: failures.sorted { $0.name < $1.name })
        }
    }

    private func operations(scope: MonitoringScope) async throws -> Operations {
        try Self.validate(scope)
        if let injected { return injected }
        guard let provider else { throw ELBError.invalidScope }
        let client = try await provider.elbClient(scope: scope)
        return Operations(loadBalancers: { try await client.describeLoadBalancers($0) },
                          targetGroups: { try await client.describeTargetGroups($0) }, listeners: { try await client.describeListeners($0) },
                          rules: { try await client.describeRules($0) }, health: { try await client.describeTargetHealth($0) })
    }

    private static func validate(_ scope: MonitoringScope) throws {
        try Task.checkCancellation()
        guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty else { throw ELBError.invalidScope }
    }

    private static func pages<Item: Identifiable & Sendable>(
        _ loader: @Sendable (String?) async throws -> ([Item], String?)
    ) async throws -> [Item] {
        var items: [Item] = []
        var ids: Set<Item.ID> = []
        var marker: String?
        var markers: Set<String> = []
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            let (page, next) = try await loader(marker)
            try Task.checkCancellation()
            for item in page {
                guard ids.insert(item.id).inserted else { throw ELBError.invalidResponse }
                items.append(item)
            }
            guard let next, !next.isEmpty else { return items }
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  markers.insert(next).inserted else { throw ELBError.incompletePagination }
            marker = next
        }
        throw ELBError.incompletePagination
    }

    private static func validateListener(_ arn: String, parent: String, scope: MonitoringScope) throws {
        guard ELBARN.isLoadBalancer(parent, scope: scope), let resource = ELBARN.resource(arn, scope: scope),
              let parentResource = ELBARN.resource(parent, scope: scope) else { throw ELBError.invalidResponse }
        let prefix = "listener/" + parentResource.dropFirst("loadbalancer/".count) + "/"
        guard resource.hasPrefix(prefix), resource.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).count == 1,
              resource.count > prefix.count else { throw ELBError.invalidResponse }
    }

    private static func map(_ raw: SDK.LoadBalancer, scope: MonitoringScope) throws -> ELBLoadBalancer {
        guard let arn = raw.loadBalancerArn, ELBARN.isLoadBalancer(arn, scope: scope), let name = raw.loadBalancerName,
              !name.isEmpty, let type = raw.type, let resource = ELBARN.resource(arn, scope: scope) else { throw ELBError.invalidResponse }
        let parts = resource.split(separator: "/")
        let kinds = ["app": "application", "net": "network", "gwy": "gateway"]
        guard parts[2] == name, kinds[String(parts[1])] == type.rawValue else { throw ELBError.invalidResponse }
        var fields = fields([
            ("VPC", raw.vpcId), ("IP address type", raw.ipAddressType?.rawValue), ("Canonical hosted zone", raw.canonicalHostedZoneId),
            ("Created (UTC)", raw.createdTime.map { ISO8601DateFormatter().string(from: $0) }), ("State reason", raw.state?.reason),
            ("Security groups", raw.securityGroups?.joined(separator: ", ")), ("Customer-owned IPv4 pool", raw.customerOwnedIpv4Pool),
            ("IPv4 IPAM pool", raw.ipamPools?.ipv4IpamPoolId), ("IPv6 source NAT prefix", raw.enablePrefixForIpv6SourceNat?.rawValue),
            ("PrivateLink inbound security rules", raw.enforceSecurityGroupInboundRulesOnPrivateLinkTraffic)
        ])
        for (index, zone) in (raw.availabilityZones ?? []).enumerated() {
            let label = "Zone \(index + 1)"
            fields += self.fields([(label, zone.zoneName), ("\(label) subnet", zone.subnetId), ("\(label) Outpost", zone.outpostId),
                                   ("\(label) source NAT IPv6 prefixes", zone.sourceNatIpv6Prefixes?.joined(separator: ", "))])
            for (addressIndex, address) in (zone.loadBalancerAddresses ?? []).enumerated() {
                let prefix = "\(label) address \(addressIndex + 1)"
                fields += self.fields([("\(prefix) IPv4", address.ipAddress), ("\(prefix) IPv6", address.iPv6Address),
                                       ("\(prefix) private IPv4", address.privateIPv4Address), ("\(prefix) allocation", address.allocationId)])
            }
        }
        return ELBLoadBalancer(arn: arn, name: name, kind: type.rawValue, dnsName: raw.dnsName, scheme: raw.scheme?.rawValue,
                               state: raw.state?.code?.rawValue, fields: fields)
    }

    private static func map(_ raw: SDK.TargetGroup, scope: MonitoringScope) throws -> ELBTargetGroup {
        guard let arn = raw.targetGroupArn, ELBARN.isTargetGroup(arn, scope: scope), let name = raw.targetGroupName, !name.isEmpty,
              let type = raw.targetType, ELBARN.resource(arn, scope: scope)?.split(separator: "/")[1] == Substring(name),
              (raw.loadBalancerArns ?? []).allSatisfy({ ELBARN.isLoadBalancer($0, scope: scope) }) else { throw ELBError.invalidResponse }
        return ELBTargetGroup(arn: arn, name: name, targetType: type.rawValue, protocolName: raw.protocol?.rawValue, port: raw.port,
            loadBalancerARNs: Array(Set(raw.loadBalancerArns ?? [])).sorted(), fields: fields([
                ("VPC", raw.vpcId), ("Protocol version", raw.protocolVersion), ("IP address type", raw.ipAddressType?.rawValue),
                ("Target control port", raw.targetControlPort.map(String.init)), ("Health checks enabled", raw.healthCheckEnabled.map { $0 ? "Yes" : "No" }),
                ("Health check protocol", raw.healthCheckProtocol?.rawValue), ("Health check port", raw.healthCheckPort),
                ("Health check path", raw.healthCheckPath), ("Health check interval (seconds)", raw.healthCheckIntervalSeconds.map(String.init)),
                ("Health check timeout (seconds)", raw.healthCheckTimeoutSeconds.map(String.init)), ("Healthy threshold", raw.healthyThresholdCount.map(String.init)),
                ("Unhealthy threshold", raw.unhealthyThresholdCount.map(String.init)), ("HTTP success codes", raw.matcher?.httpCode), ("gRPC success codes", raw.matcher?.grpcCode)
            ]))
    }

    private static func map(_ raw: SDK.Listener, parent: String, scope: MonitoringScope) throws -> ELBListener {
        guard let arn = raw.listenerArn, raw.loadBalancerArn == parent else { throw ELBError.invalidResponse }
        try validateListener(arn, parent: parent, scope: scope)
        var fields = fields([("SSL policy", raw.sslPolicy), ("ALPN policy", raw.alpnPolicy?.joined(separator: ", ")),
            ("Mutual TLS mode", raw.mutualAuthentication?.mode), ("Trust store", raw.mutualAuthentication?.trustStoreArn),
            ("Trust store association", raw.mutualAuthentication?.trustStoreAssociationStatus?.rawValue),
            ("Advertise trust store CA names", raw.mutualAuthentication?.advertiseTrustStoreCaNames?.rawValue),
            ("Ignore client certificate expiry", raw.mutualAuthentication?.ignoreClientCertificateExpiry.map { $0 ? "Yes" : "No" })])
        for (index, certificate) in (raw.certificates ?? []).enumerated() {
            fields += self.fields([("Certificate \(index + 1)", certificate.certificateArn),
                                   ("Certificate \(index + 1) default", certificate.isDefault.map { $0 ? "Yes" : "No" })])
        }
        return ELBListener(arn: arn, loadBalancerARN: parent, protocolName: raw.protocol?.rawValue ?? "Unknown", port: raw.port,
                           actions: try actions(raw.defaultActions ?? [], scope: scope), fields: fields)
    }

    private static func map(_ raw: SDK.Rule, parent: String, scope: MonitoringScope) throws -> ELBRule {
        guard let arn = raw.ruleArn, let resource = ELBARN.resource(arn, scope: scope), let listener = ELBARN.resource(parent, scope: scope),
              let priority = raw.priority, !priority.isEmpty, let isDefault = raw.isDefault else { throw ELBError.invalidResponse }
        let prefix = "listener-rule/" + listener.dropFirst("listener/".count) + "/"
        guard resource.hasPrefix(prefix), resource.count > prefix.count,
              resource.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).count == 1 else { throw ELBError.invalidResponse }
        var conditions: [ELBField] = []
        for (index, condition) in (raw.conditions ?? []).enumerated() {
            let prefix = "\(index + 1). \(condition.field ?? "Unknown")"
            conditions += fields([("\(prefix) values", condition.values?.joined(separator: " | ")), ("\(prefix) regex", condition.regexValues?.joined(separator: " | ")),
                ("\(prefix) host values", condition.hostHeaderConfig?.values?.joined(separator: " | ")), ("\(prefix) host regex", condition.hostHeaderConfig?.regexValues?.joined(separator: " | ")),
                ("\(prefix) paths", condition.pathPatternConfig?.values?.joined(separator: " | ")), ("\(prefix) path regex", condition.pathPatternConfig?.regexValues?.joined(separator: " | ")),
                ("\(prefix) header", condition.httpHeaderConfig?.httpHeaderName), ("\(prefix) header values", condition.httpHeaderConfig?.values?.joined(separator: " | ")),
                ("\(prefix) header regex", condition.httpHeaderConfig?.regexValues?.joined(separator: " | ")), ("\(prefix) methods", condition.httpRequestMethodConfig?.values?.joined(separator: " | ")),
                ("\(prefix) source IPs", condition.sourceIpConfig?.values?.joined(separator: " | "))])
            for (queryIndex, query) in (condition.queryStringConfig?.values ?? []).enumerated() {
                conditions += fields([("\(prefix) query \(queryIndex + 1) key", query.key), ("\(prefix) query \(queryIndex + 1) value", query.value)])
            }
        }
        var transforms: [ELBField] = []
        for (index, transform) in (raw.transforms ?? []).enumerated() {
            let prefix = "\(index + 1). \(transform.type?.rawValue ?? "Unknown")"
            for (kind, rewrites) in [("host", transform.hostHeaderRewriteConfig?.rewrites), ("URL", transform.urlRewriteConfig?.rewrites)] {
                for (rewriteIndex, rewrite) in (rewrites ?? []).enumerated() {
                    transforms += fields([("\(prefix) \(kind) \(rewriteIndex + 1) regex", rewrite.regex),
                                          ("\(prefix) \(kind) \(rewriteIndex + 1) replacement", rewrite.replace)])
                }
            }
        }
        return ELBRule(arn: arn, priority: priority, isDefault: isDefault, conditions: conditions,
                       actions: try actions(raw.actions ?? [], scope: scope), transforms: transforms)
    }

    private static func actions(_ raw: [SDK.Action], scope: MonitoringScope) throws -> [ELBAction] {
        var orders: Set<Int> = []
        return try raw.enumerated().sorted { ($0.element.order ?? $0.offset) < ($1.element.order ?? $1.offset) }.map { _, action in
            guard let type = action.type else { throw ELBError.invalidResponse }
            if let order = action.order, order < 1 || !orders.insert(order).inserted { throw ELBError.invalidResponse }
            var forwards: [ELBForward] = []
            for target in action.forwardConfig?.targetGroups ?? [] {
                guard let arn = target.targetGroupArn, ELBARN.isTargetGroup(arn, scope: scope),
                      target.weight.map({ (0...999).contains($0) }) ?? true else { throw ELBError.invalidResponse }
                if let existing = forwards.first(where: { $0.targetGroupARN == arn }) {
                    guard existing.weight == target.weight else { throw ELBError.invalidResponse }
                } else { forwards.append(ELBForward(targetGroupARN: arn, weight: target.weight)) }
            }
            if let arn = action.targetGroupArn {
                guard ELBARN.isTargetGroup(arn, scope: scope) else { throw ELBError.invalidResponse }
                if !forwards.contains(where: { $0.targetGroupARN == arn }) { forwards.insert(.init(targetGroupARN: arn), at: 0) }
            }
            var fields = fields([
                ("Stickiness enabled", action.forwardConfig?.targetGroupStickinessConfig?.enabled.map { $0 ? "Yes" : "No" }),
                ("Stickiness duration (seconds)", action.forwardConfig?.targetGroupStickinessConfig?.durationSeconds.map(String.init)),
                ("Redirect protocol", action.redirectConfig?.protocol), ("Redirect host", action.redirectConfig?.host), ("Redirect port", action.redirectConfig?.port),
                ("Redirect path", action.redirectConfig?.path), ("Redirect query", action.redirectConfig?.query), ("Redirect status", action.redirectConfig?.statusCode?.rawValue),
                ("Response status", action.fixedResponseConfig?.statusCode), ("Response content type", action.fixedResponseConfig?.contentType), ("Response body", action.fixedResponseConfig?.messageBody)
            ])
            // Keep authentication summaries explicitly allowlisted. Never serialize SDK authentication configurations.
            if let oidc = action.authenticateOidcConfig {
                fields += self.fields([("OIDC issuer", oidc.issuer), ("OIDC client ID", oidc.clientId), ("OIDC scope", oidc.scope),
                                       ("Unauthenticated request", oidc.onUnauthenticatedRequest?.rawValue), ("Session timeout (seconds)", oidc.sessionTimeout.map(String.init))])
            }
            if let cognito = action.authenticateCognitoConfig {
                fields += self.fields([("Cognito user pool", cognito.userPoolArn), ("Cognito client ID", cognito.userPoolClientId),
                                       ("Cognito domain", cognito.userPoolDomain), ("Cognito scope", cognito.scope),
                                       ("Unauthenticated request", cognito.onUnauthenticatedRequest?.rawValue), ("Session timeout (seconds)", cognito.sessionTimeout.map(String.init))])
            }
            if let jwt = action.jwtValidationConfig {
                fields += self.fields([("JWT issuer", jwt.issuer), ("JWT additional claim count", jwt.additionalClaims.map { String($0.count) })])
            }
            return ELBAction(type: type.rawValue, order: action.order, forwards: forwards, fields: fields)
        }
    }

    private static func map(_ raw: SDK.TargetHealthDescription, group: ELBTargetGroup, scope: MonitoringScope) throws -> ELBTargetHealth {
        guard let target = raw.target, let id = target.id, !id.isEmpty,
              target.port.map({ (1...65535).contains($0) }) ?? true else { throw ELBError.invalidResponse }
        switch group.targetType {
        case "instance": guard isInstanceID(id) else { throw ELBError.invalidResponse }
        case "ip":
            var ipv4 = in_addr()
            var ipv6 = in6_addr()
            guard inet_pton(AF_INET, id, &ipv4) == 1 || inet_pton(AF_INET6, id, &ipv6) == 1 else { throw ELBError.invalidResponse }
        case "lambda": guard ELBResourceReference(scope: scope, service: .lambda, resourceID: id, name: id) != nil else { throw ELBError.invalidResponse }
        case "alb": guard ELBARN.isLoadBalancer(id, scope: scope), ELBARN.resource(id, scope: scope)?.hasPrefix("loadbalancer/app/") == true else { throw ELBError.invalidResponse }
        default: throw ELBError.invalidResponse
        }
        return ELBTargetHealth(targetID: id, port: target.port, availabilityZone: target.availabilityZone,
            state: raw.targetHealth?.state?.rawValue ?? "Unknown", reason: raw.targetHealth?.reason?.rawValue, description: raw.targetHealth?.description,
            fields: fields([("Health check port", raw.healthCheckPort), ("QUIC server ID", target.quicServerId),
                ("Administrative override", raw.administrativeOverride?.state?.rawValue), ("Override reason", raw.administrativeOverride?.reason?.rawValue),
                ("Override description", raw.administrativeOverride?.description), ("Anomaly result", raw.anomalyDetection?.result?.rawValue),
                ("Anomaly mitigation", raw.anomalyDetection?.mitigationInEffect?.rawValue)]))
    }

    private static func isInstanceID(_ id: String) -> Bool {
        id.range(of: "^i-(?:[0-9a-f]{8}|[0-9a-f]{17})\\z", options: .regularExpression) != nil
    }

    private static func fields(_ values: [(String, String?)]) -> [ELBField] {
        values.compactMap { name, value in value.map { ELBField(name: name, value: $0) } }
    }

    private enum Operation { case loadBalancers, targetGroups, listeners, rules, health }

    private static func sanitized(_ error: Error, operation: Operation) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? ELBError { return error }
        if let error = error as? RequestError { return error }
        if error is AWSServiceError { return ELBError.invalidScope }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedOperation", "UnauthorizedException", "ForbiddenException"].contains(code) {
            switch operation {
            case .loadBalancers: return RequestError.loadBalancersPermission
            case .targetGroups: return RequestError.targetGroupsPermission
            case .listeners: return RequestError.listenersPermission
            case .rules: return RequestError.rulesPermission
            case .health: return RequestError.targetHealthPermission
            }
        }
        if UserFacingError.requiresSSOLogin(error) { return RequestError.credentials }
        if error is URLError { return RequestError.network }
        switch code {
        case "Throttling", "ThrottlingException", "TooManyRequestsException": return RequestError.throttled
        case "LoadBalancerNotFound", "TargetGroupNotFound", "ListenerNotFound", "RuleNotFound": return RequestError.notFound
        case "InvalidNextToken", "InvalidPaginationToken": return ELBError.incompletePagination
        default: return RequestError.failed
        }
    }

    enum RequestError: LocalizedError, Equatable {
        case loadBalancersPermission, targetGroupsPermission, listenersPermission, rulesPermission, targetHealthPermission
        case credentials, network, throttled, notFound, failed

        var errorDescription: String? {
            switch self {
            case .loadBalancersPermission: return "Load balancer access was denied. Check elasticloadbalancing:DescribeLoadBalancers permission."
            case .targetGroupsPermission: return "Target group access was denied. Check elasticloadbalancing:DescribeTargetGroups permission."
            case .listenersPermission: return "Listener access was denied. Check elasticloadbalancing:DescribeListeners permission."
            case .rulesPermission: return "Listener rule access was denied. Check elasticloadbalancing:DescribeRules permission."
            case .targetHealthPermission: return "Target health access was denied. Check elasticloadbalancing:DescribeTargetHealth permission."
            case .credentials: return "AWS credentials expired or are unavailable. Sign in to the session, select the profile again, then reload load balancing resources."
            case .network: return "Unable to reach Elastic Load Balancing. Check your network or proxy, then refresh."
            case .throttled: return "Elastic Load Balancing is limiting requests. Wait a moment, then refresh manually."
            case .notFound: return "The load balancing resource is no longer available in this account and region. Refresh the resource list."
            case .failed: return "The load balancing request failed. Check the selected profile, region and service availability, then refresh."
            }
        }
    }
}
