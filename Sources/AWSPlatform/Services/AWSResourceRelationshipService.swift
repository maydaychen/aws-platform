import Foundation

struct AWSResourceRelationshipService: Sendable {
    typealias LoadBalancers = @Sendable (MonitoringScope) async throws -> [ELBLoadBalancer]
    typealias LoadTargetGroups = @Sendable (MonitoringScope) async throws -> [ELBTargetGroup]
    typealias LoadTargetHealth = @Sendable (MonitoringScope, ELBTargetGroup) async throws -> [ELBTargetHealth]
    typealias LoadMembership = @Sendable (MonitoringScope, String) async throws -> ELBMembershipResult
    typealias LoadGroups = @Sendable (MonitoringScope) async throws -> [SecurityGroupModel]
    typealias LoadInstance = @Sendable (MonitoringScope, String) async throws -> RelationInstance?
    typealias LoadInstancesUsingGroup = @Sendable (MonitoringScope, String) async throws -> [RelationInstance]
    typealias LoadZones = @Sendable (Route53Scope) async throws -> [Route53HostedZone]
    typealias LoadRecords = @Sendable (Route53Scope, Route53HostedZone) async throws -> [Route53Record]

    private let loadBalancers: LoadBalancers
    private let loadTargetGroups: LoadTargetGroups
    private let loadTargetHealth: LoadTargetHealth
    private let loadMembership: LoadMembership
    private let loadGroups: LoadGroups
    private let loadInstance: LoadInstance
    private let loadInstancesUsingGroup: LoadInstancesUsingGroup
    private let loadZones: LoadZones
    private let loadRecords: LoadRecords

    init(loadBalancers: @escaping LoadBalancers, loadTargetGroups: @escaping LoadTargetGroups,
         loadTargetHealth: @escaping LoadTargetHealth, loadMembership: @escaping LoadMembership,
         loadGroups: @escaping LoadGroups, loadInstance: @escaping LoadInstance,
         loadInstancesUsingGroup: @escaping LoadInstancesUsingGroup, loadZones: @escaping LoadZones,
         loadRecords: @escaping LoadRecords) {
        self.loadBalancers = loadBalancers
        self.loadTargetGroups = loadTargetGroups
        self.loadTargetHealth = loadTargetHealth
        self.loadMembership = loadMembership
        self.loadGroups = loadGroups
        self.loadInstance = loadInstance
        self.loadInstancesUsingGroup = loadInstancesUsingGroup
        self.loadZones = loadZones
        self.loadRecords = loadRecords
    }

    func load(reference: ResourceRelationReference, includeReverse: Bool) async throws -> ResourceRelationResult {
        do {
            try Task.checkCancellation()
            guard reference.scope.isValid, !reference.scope.configPath.isEmpty,
                  !reference.scope.credentialsPath.isEmpty else { throw ResourceRelationError.invalidScope }
            guard reference.isValid, reference.canExplore else { throw ResourceRelationError.invalidResource }
            let sections: [ResourceRelationSection]
            switch reference.service {
            case .loadBalancers: sections = try await loadBalancerRelations(reference, includeReverse: includeReverse)
            case .targetGroups: sections = try await targetGroupRelations(reference)
            case .ec2: sections = try await instanceRelations(reference, includeReverse: includeReverse)
            case .securityGroups: sections = try await groupRelations(reference, includeReverse: includeReverse)
            case .route53: sections = try await dnsRelations(reference)
            default: throw ResourceRelationError.invalidResource
            }
            try Task.checkCancellation()
            let scopedSections = sections.map { section in
                var section = section
                section.nodes = section.nodes.map { node in
                    ResourceRelationNode(id: Self.key([reference.scope.profile.name, reference.scope.accountID,
                                                       reference.scope.region, reference.service.rawValue, reference.resourceID,
                                                       reference.recordID?.name ?? "", reference.recordID?.type ?? "",
                                                       reference.recordID?.setIdentifier ?? "", node.id]),
                                         name: node.name, relation: node.relation, reference: node.reference,
                                         fields: node.fields, note: node.note)
                }
                return section
            }
            return ResourceRelationResult(reference: reference, sections: scopedSections)
        } catch { throw Self.sanitized(error) }
    }

    private func loadBalancerRelations(_ reference: ResourceRelationReference, includeReverse: Bool) async throws -> [ResourceRelationSection] {
        let rows = try await self.balancers(in: reference.scope)
        guard let source = rows.first(where: { $0.arn == reference.resourceID }) else { throw ResourceRelationError.notFound }
        let groups = try await Self.section("target-groups", title: "Associated target groups") {
            let groups = try await targetGroups(in: reference.scope)
            return ResourceRelationSection(id: "target-groups", title: "Associated target groups", nodes: groups.filter {
                $0.loadBalancerARNs.contains(source.arn)
            }.map { group in
                Self.node(reference, service: .targetGroups, id: group.arn, name: group.name, relation: "Load balancer association",
                          fields: [.init(name: "Target type", value: group.targetType)],
                          note: "Association reported by ELB; this does not identify a listener rule or prove traffic routing.")
            })
        }
        let securityGroups = try await boundGroups(source.securityGroupIDs, reference: reference)
        let dns = includeReverse ? try await reverseDNS(source, reference: reference)
            : Self.scanPlaceholder("dns", title: "Route 53 records", note: "Manually scan hosted zones in this profile for direct DNS references to this load balancer.")
        return [groups, securityGroups, dns]
    }

    private func targetGroupRelations(_ reference: ResourceRelationReference) async throws -> [ResourceRelationSection] {
        let rows = try await targetGroups(in: reference.scope)
        guard let source = rows.first(where: { $0.arn == reference.resourceID }) else { throw ResourceRelationError.notFound }
        let balancers = try await Self.section("load-balancers", title: "Associated load balancers") {
            guard !source.loadBalancerARNs.isEmpty else {
                return ResourceRelationSection(id: "load-balancers", title: "Associated load balancers")
            }
            let rows = try await self.balancers(in: reference.scope)
            let nodes = source.loadBalancerARNs.map { arn in
                let row = rows.first { $0.arn == arn }
                return ResourceRelationNode(id: Self.key(["association", arn]), name: row?.name ?? arn,
                                            relation: "Target group association",
                                            reference: row.map { Self.reference(reference, service: .loadBalancers, id: $0.arn, name: $0.name) },
                                            fields: [.init(name: "ARN", value: arn)],
                                            note: row == nil ? "The associated load balancer was not returned in this scope." : nil)
            }
            return ResourceRelationSection(id: "load-balancers", title: "Associated load balancers", nodes: nodes,
                                           isIncomplete: nodes.contains { $0.reference == nil })
        }
        let targets = try await Self.section("targets", title: "Registered targets") {
            try Task.checkCancellation()
            let rows = try await loadTargetHealth(reference.scope, source)
            try Task.checkCancellation()
            guard rows.allSatisfy({ !$0.targetID.isEmpty && !$0.state.isEmpty }),
                  Set(rows.map(\.id)).count == rows.count else { throw ResourceRelationError.invalidResource }
            return ResourceRelationSection(id: "targets", title: "Registered targets", nodes: rows.map {
                Self.targetNode($0, group: source, reference: reference)
            }, note: "Registered configuration and health status; this does not establish end-to-end connectivity.")
        }
        return [balancers, targets]
    }

    private func instanceRelations(_ reference: ResourceRelationReference, includeReverse: Bool) async throws -> [ResourceRelationSection] {
        try Task.checkCancellation()
        let instance = try await loadInstance(reference.scope, reference.resourceID)
        try Task.checkCancellation()
        guard let instance else { throw ResourceRelationError.notFound }
        guard instance.id == reference.resourceID, Self.validInstance(instance, scope: reference.scope) else {
            throw ResourceRelationError.invalidResource
        }
        let groups = try await boundGroups(instance.securityGroupIDs, reference: reference)
        guard includeReverse else {
            return [groups, Self.scanPlaceholder("target-groups", title: "Target group registrations",
                                                 note: "Manually scan instance target groups in this region. Each group requires a target-health request.")]
        }
        let memberships = try await Self.section("target-groups", title: "Target group registrations") {
            try Task.checkCancellation()
            let result = try await loadMembership(reference.scope, instance.id)
            try Task.checkCancellation()
            guard result.checkedGroupCount >= 0, result.totalGroupCount >= result.checkedGroupCount,
                  result.matches.count <= result.checkedGroupCount,
                  Set(result.matches.map(\.group.arn)).count == result.matches.count else {
                throw ResourceRelationError.invalidResource
            }
            var nodes: [ResourceRelationNode] = []
            for match in result.matches {
                guard ELBARN.isTargetGroup(match.group.arn, scope: reference.scope), match.group.targetType == "instance" else {
                    throw ResourceRelationError.invalidResource
                }
                for target in match.targets where target.targetID == instance.id && target.reason != "Target.NotRegistered" {
                    var node = Self.node(reference, service: .targetGroups, id: match.group.arn, name: match.group.name,
                                         relation: "Registered instance target", fields: Self.targetFields(target))
                    node = ResourceRelationNode(id: Self.key([match.group.arn, target.targetID, target.port.map(String.init) ?? "",
                                                             target.availabilityZone ?? ""]), name: node.name,
                                                relation: node.relation, reference: node.reference, fields: node.fields)
                    nodes.append(node)
                }
            }
            return ResourceRelationSection(id: "target-groups", title: "Target group registrations", nodes: nodes,
                                           error: result.failures.isEmpty ? nil : "\(result.failures.count) target group checks failed. Check ELB access and retry the scan.",
                                           note: "Registration is shown for every returned port, including unhealthy or unused targets.",
                                           isIncomplete: !result.isComplete, checkedCount: result.checkedGroupCount,
                                           totalCount: result.totalGroupCount)
        }
        return [groups, memberships]
    }

    private func groupRelations(_ reference: ResourceRelationReference, includeReverse: Bool) async throws -> [ResourceRelationSection] {
        let groups = try await securityGroups(in: reference.scope)
        guard let source = groups.first(where: { $0.id == reference.resourceID }) else { throw ResourceRelationError.notFound }
        var nodes: [ResourceRelationNode] = []
        for (direction, rules) in [("Inbound", source.inboundRules), ("Outbound", source.outboundRules)] {
            for (index, rule) in rules.enumerated() {
                guard let id = rule.referencedGroupID else { continue }
                let group = groups.first { $0.id == id }
                let owner = rule.referencedAccountID ?? group?.ownerID
                let knownForeignOwner = group?.ownerID.map { $0 != reference.scope.accountID } ?? false
                let canNavigate = SecurityGroupModel.validID(id) && owner == reference.scope.accountID && !knownForeignOwner
                nodes.append(ResourceRelationNode(
                    id: Self.key(["permission", source.id, direction, String(index), id]), name: group?.name ?? id,
                    relation: "\(direction) permission reference",
                    reference: canNavigate ? Self.reference(reference, service: .securityGroups, id: id, name: group?.name ?? id) : nil,
                    fields: [.init(name: "Group ID", value: id), .init(name: "Owner", value: owner ?? "Not returned"),
                             .init(name: "Protocol", value: rule.protocolName), .init(name: "Ports / ICMP type and code", value: rule.portRange)],
                    note: canNavigate ? "This rule grants a permission; it does not prove connectivity or traffic."
                        : "This rule references a group whose current-account ownership is unconfirmed. Navigation is unavailable."
                ))
            }
        }
        let permissions = ResourceRelationSection(id: "permissions", title: "Security group rule references", nodes: nodes,
                                                 note: "Only explicit security group references are shown. CIDRs and prefix lists are not resolved to resources.")
        guard includeReverse else {
            return [permissions, Self.scanPlaceholder("instances", title: "EC2 usage", note: "Manually query instances using this group, including secondary network interfaces."),
                    Self.scanPlaceholder("load-balancers", title: "Load balancer usage", note: "Manually inspect load balancers in this region for this group ID.")]
        }
        let instances = try await Self.section("instances", title: "EC2 usage") {
            try Task.checkCancellation()
            let rows = try await loadInstancesUsingGroup(reference.scope, source.id)
            try Task.checkCancellation()
            guard rows.allSatisfy({ Self.validInstance($0, scope: reference.scope) }), Set(rows.map(\.id)).count == rows.count else {
                throw ResourceRelationError.invalidResource
            }
            return ResourceRelationSection(id: "instances", title: "EC2 usage", nodes: rows.filter {
                $0.securityGroupIDs.contains(source.id)
            }.map { Self.node(reference, service: .ec2, id: $0.id, name: $0.name, relation: "Bound security group",
                              note: "The group is attached to the instance or one of its network interfaces.") })
        }
        let balancers = try await Self.section("load-balancers", title: "Load balancer usage") {
            let rows = try await self.balancers(in: reference.scope)
            return ResourceRelationSection(id: "load-balancers", title: "Load balancer usage", nodes: rows.filter {
                $0.securityGroupIDs.contains(source.id)
            }.map { Self.node(reference, service: .loadBalancers, id: $0.arn, name: $0.name, relation: "Bound security group") })
        }
        return [permissions, instances, balancers]
    }

    private func boundGroups(_ ids: [String], reference: ResourceRelationReference) async throws -> ResourceRelationSection {
        try await Self.section("security-groups", title: "Bound security groups") {
            guard ids.allSatisfy(SecurityGroupModel.validID) else { throw ResourceRelationError.invalidResource }
            guard !ids.isEmpty else { return ResourceRelationSection(id: "security-groups", title: "Bound security groups") }
            let rows = try await securityGroups(in: reference.scope)
            let nodes = Array(Set(ids)).sorted().map { id in
                let row = rows.first { $0.id == id }
                let canNavigate = row?.ownerID == reference.scope.accountID
                return ResourceRelationNode(id: Self.key(["binding", id]), name: row?.name ?? id, relation: "Bound security group",
                                            reference: canNavigate ? Self.reference(reference, service: .securityGroups, id: id, name: row?.name ?? id) : nil,
                                            fields: [.init(name: "Group ID", value: id), .init(name: "Owner", value: row?.ownerID ?? "Not returned")],
                                            note: canNavigate ? nil : "Group metadata or current-account ownership could not be confirmed. Navigation is unavailable.")
            }
            return ResourceRelationSection(id: "security-groups", title: "Bound security groups", nodes: nodes,
                                           isIncomplete: ids.contains { id in !rows.contains { $0.id == id } })
        }
    }

    private func dnsRelations(_ reference: ResourceRelationReference) async throws -> [ResourceRelationSection] {
        let zones = try await self.zones(in: reference.scope.route53Scope)
        guard let zone = zones.first(where: { $0.id == reference.resourceID }) else { throw ResourceRelationError.notFound }
        let rows = try await records(in: zone, scope: reference.scope.route53Scope)
        guard let recordID = reference.recordID else {
            return [ResourceRelationSection(id: "records", title: "Alias and CNAME records", nodes: rows.filter {
                !Route53LoadBalancerMatcher.targets(in: $0).isEmpty
            }.map { Self.recordNode($0, zone: zone, reference: reference, relation: "Hosted zone record") },
                                            note: "Explore a record to match its direct target in the explicitly selected query region.")]
        }
        guard let record = rows.first(where: { $0.id == recordID }) else { throw ResourceRelationError.notFound }
        let targets = Route53LoadBalancerMatcher.targets(in: record)
        var section = ResourceRelationSection(id: "load-balancers", title: "Direct DNS targets",
                                              note: "Exact configuration matching in \(reference.scope.region); no DNS lookup, suffix matching or CNAME-chain inference.")
        section.nodes = targets.enumerated().map { index, target in
            ResourceRelationNode(id: Self.key(["unmatched", reference.resourceID, record.name, record.type,
                                               record.setIdentifier ?? "", String(index), target]), name: target,
                                 relation: record.alias == nil ? "CNAME target" : "Alias target",
                                 fields: Self.recordFields(record, zone: zone),
                                 note: "No exact ALB or NLB match was confirmed in this query region.")
        }
        guard !targets.isEmpty else { return [section] }
        do {
            let balancers = try await self.balancers(in: reference.scope)
            var nodes: [ResourceRelationNode] = []
            for (index, target) in targets.enumerated() {
                var singleTarget = record
                if record.alias == nil { singleTarget.values = [target] }
                let matches = balancers.filter { Route53LoadBalancerMatcher.matches(record: singleTarget, loadBalancer: $0) }
                if matches.isEmpty { nodes.append(section.nodes[index]); continue }
                nodes += matches.map {
                    var node = Self.node(reference, service: .loadBalancers, id: $0.arn, name: $0.name,
                                         relation: record.alias == nil ? "Direct CNAME DNS match" : "Alias DNS and canonical zone match",
                                         fields: [.init(name: "DNS target", value: target), .init(name: "Query region", value: reference.scope.region)],
                                         note: "A configuration reference, not evidence of observed traffic.")
                    node = ResourceRelationNode(id: Self.key(["dns-target", String(index), $0.arn]), name: node.name,
                                                relation: node.relation, reference: node.reference, fields: node.fields, note: node.note)
                    return node
                }
            }
            section.nodes = nodes
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            section.error = Self.sanitized(error).localizedDescription
            section.isIncomplete = true
        }
        return [section]
    }

    private struct DNSScan: Sendable {
        let zone: Route53HostedZone
        let records: [Route53Record]
        let error: String?
    }

    private func reverseDNS(_ balancer: ELBLoadBalancer, reference: ResourceRelationReference) async throws -> ResourceRelationSection {
        try await Self.section("dns", title: "Route 53 records") {
            let scope = reference.scope.route53Scope
            let zones = try await self.zones(in: scope)
            return try await withThrowingTaskGroup(of: DNSScan.self) { tasks in
                var next = 0
                func add(_ zone: Route53HostedZone) {
                    tasks.addTask {
                        do {
                            let rows = try await records(in: zone, scope: scope)
                            return DNSScan(zone: zone, records: rows, error: nil)
                        } catch {
                            if error is CancellationError || Task.isCancelled { throw CancellationError() }
                            return DNSScan(zone: zone, records: [], error: Self.sanitized(error).localizedDescription)
                        }
                    }
                }
                while next < min(4, zones.count) { add(zones[next]); next += 1 }
                var scans: [DNSScan] = []
                while let result = try await tasks.next() {
                    try Task.checkCancellation()
                    scans.append(result)
                    if next < zones.count { add(zones[next]); next += 1 }
                }
                try Task.checkCancellation()
                scans.sort { $0.zone.id < $1.zone.id }
                let failures = scans.filter { $0.error != nil }
                let nodes = scans.flatMap { scan in
                    scan.records.filter { Route53LoadBalancerMatcher.matches(record: $0, loadBalancer: balancer) }.map {
                        Self.recordNode($0, zone: scan.zone, reference: reference,
                                        relation: $0.alias == nil ? "Direct CNAME DNS match" : "Alias DNS and canonical zone match")
                    }
                }
                return ResourceRelationSection(id: "dns", title: "Route 53 records", nodes: nodes,
                                               error: failures.isEmpty ? nil : failures.map {
                    "\($0.zone.name) (\($0.zone.id)): \($0.error ?? ResourceRelationError.failed.localizedDescription)"
                }.joined(separator: "\n"), note: "Only direct Alias and CNAME configuration references are matched.",
                                               isIncomplete: !failures.isEmpty, checkedCount: scans.count - failures.count,
                                               totalCount: zones.count, resourceFailures: failures.map {
                    ResourceRelationFailure(resourceName: $0.zone.name, resourceID: $0.zone.id,
                                            message: $0.error ?? ResourceRelationError.failed.localizedDescription)
                })
            }
        }
    }

    private func balancers(in scope: MonitoringScope) async throws -> [ELBLoadBalancer] {
        try Task.checkCancellation()
        let rows = try await loadBalancers(scope)
        try Task.checkCancellation()
        guard rows.allSatisfy({ ELBARN.isLoadBalancer($0.arn, scope: scope) && !$0.name.isEmpty }),
              Set(rows.map(\.arn)).count == rows.count else { throw ResourceRelationError.invalidResource }
        return rows
    }

    private func targetGroups(in scope: MonitoringScope) async throws -> [ELBTargetGroup] {
        try Task.checkCancellation()
        let rows = try await loadTargetGroups(scope)
        try Task.checkCancellation()
        guard rows.allSatisfy({ ELBARN.isTargetGroup($0.arn, scope: scope) && !$0.name.isEmpty
            && $0.loadBalancerARNs.allSatisfy { ELBARN.isLoadBalancer($0, scope: scope) } }),
              Set(rows.map(\.arn)).count == rows.count else { throw ResourceRelationError.invalidResource }
        return rows
    }

    private func securityGroups(in scope: MonitoringScope) async throws -> [SecurityGroupModel] {
        try Task.checkCancellation()
        let rows = try await loadGroups(scope)
        try Task.checkCancellation()
        guard rows.allSatisfy({ SecurityGroupModel.validID($0.id) && !$0.name.isEmpty
            && ($0.ownerID.map { $0.range(of: "^[0-9]{12}\\z", options: .regularExpression) != nil } ?? true) }),
              Set(rows.map(\.id)).count == rows.count else { throw ResourceRelationError.invalidResource }
        return rows
    }

    private func zones(in scope: Route53Scope) async throws -> [Route53HostedZone] {
        try Task.checkCancellation()
        let rows = try await loadZones(scope)
        try Task.checkCancellation()
        guard rows.allSatisfy({ Route53HostedZone.normalizedID($0.id) == $0.id && !$0.name.isEmpty }),
              Set(rows.map(\.id)).count == rows.count else { throw ResourceRelationError.invalidResource }
        return rows
    }

    private func records(in zone: Route53HostedZone, scope: Route53Scope) async throws -> [Route53Record] {
        try Task.checkCancellation()
        let rows = try await loadRecords(scope, zone)
        try Task.checkCancellation()
        guard rows.allSatisfy({ !$0.name.isEmpty && !$0.type.isEmpty && $0.setIdentifier != "" }),
              Set(rows.map(\.id)).count == rows.count else { throw ResourceRelationError.invalidResource }
        return rows
    }

    private static func section(_ id: String, title: String,
                                operation: @Sendable () async throws -> ResourceRelationSection) async throws -> ResourceRelationSection {
        do {
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            return result
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return ResourceRelationSection(id: id, title: title, error: sanitized(error).localizedDescription, isIncomplete: true)
        }
    }

    private static func sanitized(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if error is ResourceRelationError || error is SecurityGroupError || error is ELBError
            || error is AWSELBService.RequestError || error is Route53Error || error is AWSRoute53Service.RequestError { return error }
        return ResourceRelationError.failed
    }

    private static func scanPlaceholder(_ id: String, title: String, note: String) -> ResourceRelationSection {
        ResourceRelationSection(id: id, title: title, note: note, requiresScan: true)
    }

    private static func validInstance(_ instance: RelationInstance, scope: MonitoringScope) -> Bool {
        !instance.name.isEmpty && ELBResourceReference(scope: scope, service: .ec2, resourceID: instance.id, name: instance.name) != nil
            && instance.securityGroupIDs.allSatisfy(SecurityGroupModel.validID)
    }

    private static func reference(_ source: ResourceRelationReference, service: AWSService, id: String, name: String,
                                   recordID: Route53Record.ID? = nil) -> ResourceRelationReference {
        ResourceRelationReference(scope: source.scope, service: service, resourceID: id, name: name, recordID: recordID)
    }

    private static func node(_ source: ResourceRelationReference, service: AWSService, id: String, name: String,
                             relation: String, fields: [ELBField] = [], note: String? = nil) -> ResourceRelationNode {
        let destination = reference(source, service: service, id: id, name: name)
        return ResourceRelationNode(id: key([service.rawValue, id, relation]), name: name, relation: relation,
                                    reference: destination.isValid ? destination : nil, fields: fields, note: note)
    }

    private static func targetNode(_ target: ELBTargetHealth, group: ELBTargetGroup, reference: ResourceRelationReference) -> ResourceRelationNode {
        let destination = ELBResourceReference.target(target, group: group, scope: reference.scope)
        let related = destination.map { Self.reference(reference, service: $0.service, id: $0.resourceID, name: $0.name) }
        var fields = targetFields(target)
        var note: String? = nil
        if let destination, destination.service == .lambda {
            fields.append(.init(name: "Function ARN", value: destination.resourceID))
            if let qualifier = destination.qualifier { fields.append(.init(name: "Qualifier", value: qualifier)) }
            note = "Open shows the function-level overview; this target's alias or version is retained above."
        } else if destination == nil {
            note = group.targetType == "ip" ? "IP targets are displayed without inferring an EC2 resource."
                : "The target is not registered or has no supported same-account, same-region resource reference."
        }
        return ResourceRelationNode(id: key([group.arn, target.targetID, target.port.map(String.init) ?? "", target.availabilityZone ?? ""]),
                                    name: target.targetID, relation: "\(group.targetType) target registration",
                                    reference: related, fields: fields, note: note)
    }

    private static func targetFields(_ target: ELBTargetHealth) -> [ELBField] {
        var fields = [ELBField(name: "Target ID", value: target.targetID), .init(name: "State", value: target.state)]
        if let port = target.port { fields.append(.init(name: "Port", value: String(port))) }
        if let zone = target.availabilityZone { fields.append(.init(name: "Availability zone", value: zone)) }
        if let reason = target.reason { fields.append(.init(name: "Reason", value: reason)) }
        if let description = target.description { fields.append(.init(name: "Description", value: description)) }
        return fields
    }

    private static func recordNode(_ record: Route53Record, zone: Route53HostedZone, reference: ResourceRelationReference,
                                   relation: String) -> ResourceRelationNode {
        ResourceRelationNode(id: key([zone.id, record.name, record.type, record.setIdentifier ?? "", relation]),
                             name: record.name, relation: relation,
                             reference: Self.reference(reference, service: .route53, id: zone.id, name: record.name, recordID: record.id),
                             fields: recordFields(record, zone: zone))
    }

    private static func recordFields(_ record: Route53Record, zone: Route53HostedZone) -> [ELBField] {
        var fields = [ELBField(name: "Hosted zone", value: zone.name), .init(name: "Zone ID", value: zone.id),
                      .init(name: "Record type", value: record.type), .init(name: "Routing policy", value: record.routingPolicy)]
        if let identifier = record.setIdentifier { fields.append(.init(name: "Set identifier", value: identifier)) }
        for target in Route53LoadBalancerMatcher.targets(in: record) { fields.append(.init(name: "DNS target", value: target)) }
        if let alias = record.alias { fields.append(.init(name: "Alias hosted zone ID", value: alias.hostedZoneID)) }
        return fields
    }

    private static func key(_ parts: [String]) -> String { parts.map { "\($0.utf8.count):\($0)" }.joined() }
}
