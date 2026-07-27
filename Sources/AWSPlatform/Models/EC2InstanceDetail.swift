import Foundation

struct EC2InstanceHealth: Hashable {
    let systemStatus: String?
    let instanceStatus: String?
    let attachedEBSStatus: String?
    let events: [EC2ScheduledEvent]

    var needsAttention: Bool {
        !events.isEmpty || [systemStatus, instanceStatus, attachedEBSStatus]
            .compactMap { $0 }
            .contains { status in
                status != "ok" && status != "not-applicable"
            }
    }

    var summary: String {
        if !events.isEmpty {
            return "Scheduled event"
        }
        if needsAttention {
            return "Check failed"
        }
        if systemStatus == "ok", instanceStatus == "ok" {
            return "Checks passed"
        }
        return "Not available"
    }
}

struct EC2ScheduledEvent: Identifiable, Hashable {
    let eventId: String
    let code: String
    let description: String?
    let notBefore: Date?
    let notAfter: Date?

    var id: String { eventId }
}

struct EC2InstanceDetailModel: Hashable {
    let instanceId: String
    let privateDNSName: String?
    let publicDNSName: String?
    let ipv6Address: String?
    let monitoringState: String?
    let stateTransitionReason: String?
    let iamProfileARN: String?
    let rootDeviceName: String?
    let rootDeviceType: String?
    let virtualizationType: String?
    let hypervisor: String?
    let lifecycle: String?
    let spotRequestId: String?
    let capacityReservationId: String?
    let cpuCoreCount: Int?
    let threadsPerCore: Int?
    let ebsOptimized: Bool?
    let enaSupport: Bool?
    let sourceDestCheck: Bool?
    let metadataHttpEndpoint: String?
    let metadataHttpTokens: String?
    let metadataHopLimit: Int?
    let metadataTags: String?
    let networkInterfaces: [EC2NetworkInterfaceModel]
    let volumes: [EC2VolumeModel]
    let securityGroups: [EC2SecurityGroupModel]
    let health: EC2InstanceHealth?
    let warnings: [String]
}

struct EC2NetworkInterfaceModel: Identifiable, Hashable {
    let interfaceId: String
    let description: String?
    let status: String?
    let interfaceType: String?
    let macAddress: String?
    let privateIP: String?
    let privateDNSName: String?
    let publicIP: String?
    let publicDNSName: String?
    let privateIPs: [String]
    let ipv6Addresses: [String]
    let vpcId: String?
    let subnetId: String?
    let securityGroupIds: [String]
    let deviceIndex: Int?
    let deleteOnTermination: Bool?
    let sourceDestCheck: Bool?

    var id: String { interfaceId }
}

struct EC2VolumeModel: Identifiable, Hashable {
    let volumeId: String
    let name: String?
    let device: String?
    let state: String?
    let type: String?
    let sizeGiB: Int?
    let iops: Int?
    let throughputMiBps: Int?
    let encrypted: Bool?
    let deleteOnTermination: Bool?
    let availabilityZone: String?
    let snapshotId: String?

    var id: String { volumeId }
}

struct EC2SecurityGroupModel: Identifiable, Hashable {
    let groupId: String
    let name: String?
    let description: String?
    let vpcId: String?
    let inboundRules: [EC2SecurityRuleModel]
    let outboundRules: [EC2SecurityRuleModel]

    var id: String { groupId }
}

struct EC2SecurityRuleModel: Identifiable, Hashable {
    let protocolName: String
    let portRange: String
    let source: String
    let description: String?

    var id: String {
        [protocolName, portRange, source, description ?? ""].joined(separator: "|")
    }
}
