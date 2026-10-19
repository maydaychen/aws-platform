import Foundation
import SotoCore
import SotoEC2

enum EC2DataLoader {
    static func fetchInstances(client: EC2) async throws -> [EC2InstanceModel] {
        var rows: [EC2InstanceModel] = []
        var nextToken: String?

        repeat {
            try Task.checkCancellation()
            let response = try await client.describeInstances(.init(nextToken: nextToken))
            nextToken = response.nextToken

            for reservation in response.reservations ?? [] {
                for instance in reservation.instances ?? [] {
                    let instanceId = instance.instanceId ?? "unknown"
                    let tags = dictionary(from: instance.tags)

                    rows.append(
                        EC2InstanceModel(
                            instanceId: instanceId,
                            name: tags["Name"] ?? instanceId,
                            instanceType: instance.instanceType?.rawValue ?? "-",
                            state: instance.state?.name?.rawValue ?? "-",
                            privateIP: instance.privateIpAddress,
                            publicIP: instance.publicIpAddress,
                            platformDetails: instance.platformDetails,
                            architecture: instance.architecture?.rawValue,
                            vpcId: instance.vpcId,
                            subnetId: instance.subnetId,
                            availabilityZone: instance.placement?.availabilityZone,
                            securityGroups: (instance.securityGroups ?? []).compactMap {
                                $0.groupId ?? $0.groupName
                            },
                            imageId: instance.imageId,
                            imageName: nil,
                            keyName: instance.keyName,
                            launchTime: instance.launchTime,
                            tags: tags
                        )
                    )
                }
            }
        } while nextToken != nil

        return rows
    }

    static func fetchImageNames(ids: [String], client: EC2) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let response = try await client.describeImages(.init(imageIds: ids))
        return Dictionary(
            uniqueKeysWithValues: (response.images ?? []).compactMap { image in
                guard let imageId = image.imageId else { return nil }
                return (imageId, image.name ?? image.description ?? "Unknown")
            }
        )
    }

    static func fetchDetail(
        instanceId: String,
        client: EC2
    ) async throws -> EC2InstanceDetailModel {
        let response = try await client.describeInstances(.init(instanceIds: [instanceId]))
        guard let instance = response.reservations?.first?.instances?.first else {
            throw EC2DetailError.instanceNotFound
        }

        let cpuCreditMode = try await fetchCPUCreditMode(
            instanceId: instanceId,
            instanceType: instance.instanceType?.rawValue ?? "",
            request: { try await client.describeInstanceCreditSpecifications($0) }
        )

        return EC2InstanceDetailModel(
            instanceId: instanceId,
            privateDNSName: instance.privateDnsName,
            publicDNSName: instance.publicDnsName,
            ipv6Address: instance.ipv6Address,
            monitoringState: instance.monitoring?.state?.rawValue,
            stateTransitionReason: instance.stateTransitionReason,
            iamProfileARN: instance.iamInstanceProfile?.arn,
            rootDeviceName: instance.rootDeviceName,
            rootDeviceType: instance.rootDeviceType?.rawValue,
            virtualizationType: instance.virtualizationType?.rawValue,
            hypervisor: instance.hypervisor?.rawValue,
            lifecycle: instance.instanceLifecycle?.rawValue,
            spotRequestId: instance.spotInstanceRequestId,
            capacityReservationId: instance.capacityReservationId,
            cpuCoreCount: instance.cpuOptions?.coreCount,
            threadsPerCore: instance.cpuOptions?.threadsPerCore,
            ebsOptimized: instance.ebsOptimized,
            enaSupport: instance.enaSupport,
            sourceDestCheck: instance.sourceDestCheck,
            metadataHttpEndpoint: instance.metadataOptions?.httpEndpoint?.rawValue,
            metadataHttpTokens: instance.metadataOptions?.httpTokens?.rawValue,
            metadataHopLimit: instance.metadataOptions?.httpPutResponseHopLimit,
            metadataTags: instance.metadataOptions?.instanceMetadataTags?.rawValue,
            networkInterfaces: (instance.networkInterfaces ?? []).map(networkInterface(from:)),
            volumes: [],
            securityGroups: [],
            health: nil,
            warnings: [],
            cpuCreditMode: cpuCreditMode,
            volumeIDs: (instance.blockDeviceMappings ?? []).compactMap(\.ebs?.volumeId),
            securityGroupIDs: Array(Set((instance.securityGroups ?? []).compactMap(\.groupId))),
            volumeAttachmentHints: (instance.blockDeviceMappings ?? []).compactMap { mapping in
                guard let volumeID = mapping.ebs?.volumeId else { return nil }
                return EC2VolumeAttachmentHint(volumeID: volumeID, device: mapping.deviceName,
                                               deleteOnTermination: mapping.ebs?.deleteOnTermination)
            }
        )
    }

    @MainActor
    static func fetchCPUCreditMode(
        instanceId: String,
        instanceType: String,
        request: (EC2.DescribeInstanceCreditSpecificationsRequest) async throws -> EC2.DescribeInstanceCreditSpecificationsResult
    ) async throws -> EC2CPUCreditMode? {
        guard EC2CPUCreditMode.applies(to: instanceType) else { return nil }
        try Task.checkCancellation()
        do {
            let response = try await request(.init(instanceIds: [instanceId]))
            try Task.checkCancellation()
            let credits = response.instanceCreditSpecifications?.first { $0.instanceId == instanceId }?.cpuCredits
            switch credits {
            case "standard": return .standard
            case "unlimited": return .unlimited
            default: return .unknown
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            let code = (error as? AWSErrorType)?.errorCode ?? ""
            if ["UnauthorizedOperation", "AccessDenied", "AccessDeniedException", "Forbidden", "ForbiddenException"].contains(code) {
                return .permissionDenied
            }
            return .readFailed
        }
    }

    private static func fetchVolumes(
        instanceId: String,
        volumeIds: [String],
        mappings: [EC2VolumeAttachmentHint],
        client: EC2
    ) async throws -> [EC2VolumeModel] {
        guard !volumeIds.isEmpty else { return [] }
        let response = try await client.describeVolumes(.init(volumeIds: volumeIds))
        let mappingByVolumeId = Dictionary(mappings.map { ($0.volumeID, $0) }, uniquingKeysWith: { first, _ in first })

        return (response.volumes ?? []).compactMap { volume -> EC2VolumeModel? in
            guard let volumeId = volume.volumeId else { return nil }
            let mapping = mappingByVolumeId[volumeId]
            let attachment = volume.attachments?.first { $0.instanceId == instanceId }
            let tags = dictionary(from: volume.tags)
            return EC2VolumeModel(
                volumeId: volumeId,
                name: tags["Name"],
                device: attachment?.device ?? mapping?.device,
                state: volume.state?.rawValue,
                type: volume.volumeType?.rawValue,
                sizeGiB: volume.size,
                iops: volume.iops,
                throughputMiBps: volume.throughput,
                encrypted: volume.encrypted,
                deleteOnTermination: attachment?.deleteOnTermination
                    ?? mapping?.deleteOnTermination,
                availabilityZone: volume.availabilityZone,
                snapshotId: volume.snapshotId
            )
        }
        .sorted { ($0.device ?? $0.volumeId) < ($1.device ?? $1.volumeId) }
    }

    private static func fetchSecurityGroups(
        ids: [String],
        client: EC2
    ) async throws -> [EC2SecurityGroupModel] {
        guard !ids.isEmpty else { return [] }
        let response = try await client.describeSecurityGroups(.init(groupIds: ids))
        return (response.securityGroups ?? []).compactMap { group in
            guard let groupId = group.groupId else { return nil }
            return EC2SecurityGroupModel(
                groupId: groupId,
                name: group.groupName,
                description: group.description,
                vpcId: group.vpcId,
                inboundRules: (group.ipPermissions ?? []).flatMap(securityRules(from:)),
                outboundRules: (group.ipPermissionsEgress ?? []).flatMap(securityRules(from:))
            )
        }
        .sorted { $0.groupId < $1.groupId }
    }

    private static func networkInterface(
        from interface: EC2.InstanceNetworkInterface
    ) -> EC2NetworkInterfaceModel {
        let privateAddresses = interface.privateIpAddresses ?? []
        let associatedAddress = privateAddresses.compactMap(\.association).first
        return EC2NetworkInterfaceModel(
            interfaceId: interface.networkInterfaceId ?? "unknown",
            description: interface.description,
            status: interface.status?.rawValue,
            interfaceType: interface.interfaceType,
            macAddress: interface.macAddress,
            privateIP: interface.privateIpAddress,
            privateDNSName: interface.privateDnsName,
            publicIP: interface.association?.publicIp ?? associatedAddress?.publicIp,
            publicDNSName: interface.association?.publicDnsName
                ?? associatedAddress?.publicDnsName,
            privateIPs: privateAddresses.compactMap(\.privateIpAddress),
            ipv6Addresses: (interface.ipv6Addresses ?? []).compactMap(\.ipv6Address),
            vpcId: interface.vpcId,
            subnetId: interface.subnetId,
            securityGroupIds: (interface.groups ?? []).compactMap {
                $0.groupId ?? $0.groupName
            },
            deviceIndex: interface.attachment?.deviceIndex,
            deleteOnTermination: interface.attachment?.deleteOnTermination,
            sourceDestCheck: interface.sourceDestCheck
        )
    }

    private static func securityRules(
        from permission: EC2.IpPermission
    ) -> [EC2SecurityRuleModel] {
        let protocolName = permission.ipProtocol == "-1"
            ? "All"
            : permission.ipProtocol ?? "-"
        let portRange: String
        if permission.ipProtocol == "-1" {
            portRange = "All"
        } else if let fromPort = permission.fromPort, let toPort = permission.toPort {
            portRange = fromPort == toPort ? "\(fromPort)" : "\(fromPort)-\(toPort)"
        } else {
            portRange = "All"
        }

        var rules: [EC2SecurityRuleModel] = []
        rules += (permission.ipRanges ?? []).map {
            EC2SecurityRuleModel(
                protocolName: protocolName,
                portRange: portRange,
                source: $0.cidrIp ?? "-",
                description: $0.description
            )
        }
        rules += (permission.ipv6Ranges ?? []).map {
            EC2SecurityRuleModel(
                protocolName: protocolName,
                portRange: portRange,
                source: $0.cidrIpv6 ?? "-",
                description: $0.description
            )
        }
        rules += (permission.prefixListIds ?? []).map {
            EC2SecurityRuleModel(
                protocolName: protocolName,
                portRange: portRange,
                source: $0.prefixListId ?? "-",
                description: $0.description
            )
        }
        rules += (permission.userIdGroupPairs ?? []).map {
            EC2SecurityRuleModel(
                protocolName: protocolName,
                portRange: portRange,
                source: $0.groupId ?? $0.groupName ?? "-",
                description: $0.description
            )
        }

        if rules.isEmpty {
            rules.append(
                EC2SecurityRuleModel(
                    protocolName: protocolName,
                    portRange: portRange,
                    source: "-",
                    description: nil
                )
            )
        }
        return rules
    }

    private static func dictionary(from tags: [EC2.Tag]?) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: (tags ?? []).compactMap { tag in
                guard let key = tag.key else { return nil }
                return (key, tag.value ?? "")
            }
        )
    }

    static func fetchSection(base: EC2InstanceDetailModel, section: EC2DetailSection, client: EC2) async throws -> EC2DetailSectionResult {
        try Task.checkCancellation()
        switch section {
        case .storage:
            return .storage(try await fetchVolumes(instanceId: base.instanceId, volumeIds: base.volumeIDs, mappings: base.volumeAttachmentHints, client: client))
        case .security:
            return .security(try await fetchSecurityGroups(ids: base.securityGroupIDs, client: client))
        case .status:
            return .status(try await EC2InstanceHealthService(client: client).loadDetail(instanceId: base.instanceId))
        }
    }

}

private enum EC2DetailError: LocalizedError {
    case instanceNotFound

    var errorDescription: String? {
        "The selected EC2 instance is no longer available."
    }
}
