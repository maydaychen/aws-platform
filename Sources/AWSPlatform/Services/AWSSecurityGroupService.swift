import Darwin
import Foundation
import SotoCore
import SotoEC2

struct AWSSecurityGroupService: Sendable {
    typealias GroupLoader = @Sendable (EC2.DescribeSecurityGroupsRequest) async throws -> EC2.DescribeSecurityGroupsResult
    typealias InstanceLoader = @Sendable (EC2.DescribeInstancesRequest) async throws -> EC2.DescribeInstancesResult

    private struct Operations: Sendable {
        let groups: GroupLoader
        let instances: InstanceLoader
    }

    private let provider: AWSServiceProvider?
    private let injected: Operations?

    init(provider: AWSServiceProvider) {
        self.provider = provider
        injected = nil
    }

    init(groupLoader: @escaping GroupLoader, instanceLoader: @escaping InstanceLoader) {
        provider = nil
        injected = Operations(groups: groupLoader, instances: instanceLoader)
    }

    func loadGroups(scope: MonitoringScope) async throws -> [SecurityGroupModel] {
        do {
            let operations = try await operations(scope: scope)
            let groups = try await Self.pages { token in
                let response = try await operations.groups(.init(maxResults: 200, nextToken: token))
                try Task.checkCancellation()
                return (try (response.securityGroups ?? []).map { try Self.map($0, scope: scope) }, response.nextToken)
            }
            return groups.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        } catch { throw Self.sanitized(error) }
    }

    func loadInstance(scope: MonitoringScope, instanceID: String) async throws -> RelationInstance? {
        do {
            try Self.validate(scope)
            guard Self.validInstanceID(instanceID) else { throw SecurityGroupError.invalidResponse }
            let instances = try await loadInstances(scope: scope, filter: .init(name: "instance-id", values: [instanceID]))
            guard instances.allSatisfy({ $0.id == instanceID }), instances.count <= 1 else { throw SecurityGroupError.invalidResponse }
            return instances.first
        } catch { throw Self.sanitized(error) }
    }

    func loadInstancesUsingGroup(scope: MonitoringScope, groupID: String) async throws -> [RelationInstance] {
        do {
            try Self.validate(scope)
            guard SecurityGroupModel.validID(groupID) else { throw SecurityGroupError.invalidResponse }
            let instances = try await loadInstances(scope: scope, filter: .init(name: "network-interface.group-id", values: [groupID]))
            guard instances.allSatisfy({ $0.securityGroupIDs.contains(groupID) }) else { throw SecurityGroupError.invalidResponse }
            return instances
        } catch { throw Self.sanitized(error) }
    }

    private func loadInstances(scope: MonitoringScope, filter: EC2.Filter) async throws -> [RelationInstance] {
        let operations = try await operations(scope: scope)
        let instances = try await Self.pages { token in
            let response = try await operations.instances(.init(filters: [filter], maxResults: 200, nextToken: token))
            try Task.checkCancellation()
            var page: [RelationInstance] = []
            for reservation in response.reservations ?? [] {
                guard reservation.ownerId == nil || reservation.ownerId == scope.accountID else { throw SecurityGroupError.invalidResponse }
                page += try (reservation.instances ?? []).map(Self.map)
            }
            return (page, response.nextToken)
        }
        return instances.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    private func operations(scope: MonitoringScope) async throws -> Operations {
        try Self.validate(scope)
        if let injected { return injected }
        guard let provider else { throw SecurityGroupError.invalidScope }
        let client = try await provider.relationshipEC2Client(scope: scope)
        return Operations(groups: { try await client.describeSecurityGroups($0) }, instances: { try await client.describeInstances($0) })
    }

    private static func validate(_ scope: MonitoringScope) throws {
        try Task.checkCancellation()
        guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty else { throw SecurityGroupError.invalidScope }
    }

    private static func pages<Item: Identifiable & Sendable>(
        _ loader: @Sendable (String?) async throws -> ([Item], String?)
    ) async throws -> [Item] {
        var items: [Item] = []
        var ids: Set<Item.ID> = []
        var token: String?
        var tokens: Set<String> = []
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            let (page, next) = try await loader(token)
            try Task.checkCancellation()
            for item in page {
                guard ids.insert(item.id).inserted else { throw SecurityGroupError.invalidResponse }
                items.append(item)
            }
            guard let next, !next.isEmpty else {
                try Task.checkCancellation()
                return items
            }
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  tokens.insert(next).inserted else { throw SecurityGroupError.incompletePagination }
            token = next
        }
        throw SecurityGroupError.incompletePagination
    }

    private static func map(_ raw: EC2.SecurityGroup, scope: MonitoringScope) throws -> SecurityGroupModel {
        guard let id = raw.groupId, SecurityGroupModel.validID(id), let name = raw.groupName, !name.isEmpty,
              raw.ownerId.map(validAccountID) ?? true else { throw SecurityGroupError.invalidResponse }
        if let arn = raw.securityGroupArn {
            let parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
            let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
            guard parts.count == 6, parts[0] == "arn", parts[1] == partition, parts[2] == "ec2", parts[3] == scope.region,
                  validAccountID(String(parts[4])), raw.ownerId.map({ String(parts[4]) == $0 }) ?? true,
                  parts[5] == "security-group/\(id)" else { throw SecurityGroupError.invalidResponse }
        }
        return SecurityGroupModel(id: id, name: name, ownerID: raw.ownerId, vpcID: raw.vpcId, description: raw.description,
                                  inboundRules: try rules(raw.ipPermissions ?? []), outboundRules: try rules(raw.ipPermissionsEgress ?? []),
                                  tags: try tags(raw.tags ?? []))
    }

    private static func rules(_ permissions: [EC2.IpPermission]) throws -> [SecurityGroupRule] {
        var result: [SecurityGroupRule] = []
        for permission in permissions {
            guard let rawProtocol = permission.ipProtocol, !rawProtocol.isEmpty else { throw SecurityGroupError.invalidResponse }
            let proto = rawProtocol.lowercased()
            let protocolName: String
            switch proto {
            case "-1": protocolName = "All"
            case "tcp", "6": protocolName = "TCP"
            case "udp", "17": protocolName = "UDP"
            case "icmp", "1": protocolName = "ICMP"
            case "icmpv6", "58": protocolName = "ICMPv6"
            default:
                guard let number = Int(proto), (0...255).contains(number) else { throw SecurityGroupError.invalidResponse }
                protocolName = "Protocol \(number)"
            }
            let portRange = try ports(permission, protocolName: protocolName)
            let initialCount = result.count
            for range in permission.ipRanges ?? [] {
                guard let cidr = range.cidrIp, validCIDR(cidr, ipv6: false) else { throw SecurityGroupError.invalidResponse }
                result.append(.init(protocolName: protocolName, portRange: portRange, target: cidr, description: range.description,
                                    fields: [.init(name: "Target type", value: "IPv4")]))
            }
            for range in permission.ipv6Ranges ?? [] {
                guard let cidr = range.cidrIpv6, validCIDR(cidr, ipv6: true) else { throw SecurityGroupError.invalidResponse }
                result.append(.init(protocolName: protocolName, portRange: portRange, target: cidr, description: range.description,
                                    fields: [.init(name: "Target type", value: "IPv6")]))
            }
            for prefix in permission.prefixListIds ?? [] {
                guard let id = prefix.prefixListId, id.range(of: "^pl-[0-9a-f]+\\z", options: .regularExpression) != nil else {
                    throw SecurityGroupError.invalidResponse
                }
                result.append(.init(protocolName: protocolName, portRange: portRange, target: id, description: prefix.description,
                                    fields: [.init(name: "Target type", value: "Prefix list")]))
            }
            for reference in permission.userIdGroupPairs ?? [] {
                guard reference.groupId.map(SecurityGroupModel.validID) ?? true,
                      reference.userId.map(validAccountID) ?? true,
                      let target = reference.groupId ?? reference.groupName, !target.isEmpty else { throw SecurityGroupError.invalidResponse }
                let values: [(String, String?)] = [
                    ("Group name", reference.groupName), ("Referenced account", reference.userId), ("VPC", reference.vpcId),
                    ("VPC peering connection", reference.vpcPeeringConnectionId), ("Peering status", reference.peeringStatus)
                ]
                let fields = [ELBField(name: "Target type", value: "Security group")] + values.compactMap { name, value in
                    value.map { ELBField(name: name, value: $0) }
                }
                result.append(.init(protocolName: protocolName, portRange: portRange, target: target, description: reference.description,
                                    referencedGroupID: reference.groupId, referencedAccountID: reference.userId, fields: fields))
            }
            guard result.count > initialCount else { throw SecurityGroupError.invalidResponse }
        }
        return result
    }

    private static func ports(_ permission: EC2.IpPermission, protocolName: String) throws -> String {
        if protocolName == "All" || protocolName.hasPrefix("Protocol ") { return "All" }
        if protocolName == "ICMP" || protocolName == "ICMPv6" {
            for value in [permission.fromPort, permission.toPort].compactMap({ $0 }) {
                guard (-1...255).contains(value) else { throw SecurityGroupError.invalidResponse }
            }
            func label(_ value: Int?) -> String { value.map { $0 == -1 ? "All" : String($0) } ?? "Unknown" }
            return "Type: \(label(permission.fromPort)); Code: \(label(permission.toPort))"
        }
        for value in [permission.fromPort, permission.toPort].compactMap({ $0 }) {
            guard (0...65535).contains(value) else { throw SecurityGroupError.invalidResponse }
        }
        guard let first = permission.fromPort, let last = permission.toPort else {
            if permission.fromPort == nil && permission.toPort == nil { return "Unknown" }
            return "\(permission.fromPort.map(String.init) ?? "Unknown")-\(permission.toPort.map(String.init) ?? "Unknown")"
        }
        guard first <= last else { throw SecurityGroupError.invalidResponse }
        return first == last ? String(first) : "\(first)-\(last)"
    }

    private static func map(_ raw: EC2.Instance) throws -> RelationInstance {
        guard let id = raw.instanceId, validInstanceID(id) else { throw SecurityGroupError.invalidResponse }
        let groups = (raw.securityGroups ?? []) + (raw.networkInterfaces ?? []).flatMap { $0.groups ?? [] }
        var ids: Set<String> = []
        for group in groups {
            guard let id = group.groupId, SecurityGroupModel.validID(id) else { throw SecurityGroupError.invalidResponse }
            ids.insert(id)
        }
        let name = try tags(raw.tags ?? []).first { $0.name == "Name" }?.value
        return RelationInstance(id: id, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                                securityGroupIDs: ids.sorted(), vpcID: raw.vpcId)
    }

    private static func tags(_ raw: [EC2.Tag]) throws -> [ELBField] {
        var keys: Set<String> = []
        return try raw.map { tag in
            guard let key = tag.key, !key.isEmpty, let value = tag.value, keys.insert(key).inserted else {
                throw SecurityGroupError.invalidResponse
            }
            return ELBField(name: key, value: value)
        }.sorted { $0.name < $1.name }
    }

    private static func validInstanceID(_ value: String) -> Bool {
        value.range(of: "^i-(?:[0-9a-f]{8}|[0-9a-f]{17})\\z", options: .regularExpression) != nil
    }

    private static func validAccountID(_ value: String) -> Bool {
        value.range(of: "^[0-9]{12}\\z", options: .regularExpression) != nil
    }

    private static func validCIDR(_ value: String, ipv6: Bool) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              parts.count == 2, let prefix = Int(parts[1]), (0...(ipv6 ? 128 : 32)).contains(prefix) else { return false }
        var address4 = in_addr()
        var address6 = in6_addr()
        return ipv6 ? inet_pton(AF_INET6, String(parts[0]), &address6) == 1 : inet_pton(AF_INET, String(parts[0]), &address4) == 1
    }

    private static func sanitized(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? SecurityGroupError { return error }
        if error is AWSServiceError { return SecurityGroupError.invalidScope }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedOperation", "UnauthorizedException", "ForbiddenException"].contains(code) {
            return SecurityGroupError.permission
        }
        if UserFacingError.requiresSSOLogin(error) { return SecurityGroupError.credentials }
        if error is URLError { return SecurityGroupError.network }
        switch code {
        case "Throttling", "ThrottlingException", "RequestLimitExceeded", "TooManyRequestsException": return SecurityGroupError.throttled
        case "InvalidNextToken", "InvalidNextTokenException", "InvalidPaginationToken": return SecurityGroupError.incompletePagination
        default: return SecurityGroupError.failed
        }
    }
}
