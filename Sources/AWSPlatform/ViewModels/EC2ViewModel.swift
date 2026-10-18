import Foundation
import SotoCore
import SotoEC2

@MainActor
final class EC2ViewModel: ObservableObject {
    enum HealthFilter: String, CaseIterable, Identifiable {
        case all
        case attention

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:
                return "All checks"
            case .attention:
                return "Needs attention"
            }
        }
    }

    typealias InstanceLoader = () async throws -> [EC2InstanceModel]
    typealias ImageNameLoader = ([String]) async throws -> [String: String]
    typealias HealthLoader = ([String]) async throws -> [String: EC2InstanceHealth]
    typealias HealthResultLoader = ([String]) async throws -> EC2InstanceHealthResult
    typealias DetailLoader = (String) async throws -> EC2InstanceDetailModel

    @Published var instances: [EC2InstanceModel] = []
    @Published var selectedInstance: EC2InstanceModel? {
        didSet {
            guard oldValue?.instanceId != selectedInstance?.instanceId else { return }
            loadDetailForSelection()
        }
    }
    @Published var instanceHealth: [String: EC2InstanceHealth] = [:]
    @Published var instanceHealthErrors: [String: String] = [:]
    @Published var isHealthLoading = false
    @Published var instanceDetail: EC2InstanceDetailModel?
    @Published var isLoading = false
    @Published var isDetailLoading = false
    @Published var error: String?
    @Published var detailError: String?
    private(set) var scope: MonitoringScope?
    @Published var searchText = ""
    @Published var stateFilter = "All"
    @Published var healthFilter: HealthFilter = .all

    private var loadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var instanceLoader: InstanceLoader?
    private var imageNameLoader: ImageNameLoader?
    private var healthLoader: HealthLoader?
    private var healthResultLoader: HealthResultLoader?
    private var detailLoader: DetailLoader?
    private var listGeneration = 0
    private var hasAttemptedLoad = false

    init(
        instanceLoader: InstanceLoader? = nil,
        imageNameLoader: ImageNameLoader? = nil,
        healthLoader: HealthLoader? = nil,
        healthResultLoader: HealthResultLoader? = nil,
        detailLoader: DetailLoader? = nil
    ) {
        self.instanceLoader = instanceLoader
        self.imageNameLoader = imageNameLoader
        self.healthLoader = healthLoader
        self.healthResultLoader = healthResultLoader
        self.detailLoader = detailLoader
    }

    var availableStates: [String] {
        ["All"] + Set(instances.map(\.state)).sorted()
    }

    var filteredInstances: [EC2InstanceModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return instances.filter { instance in
            let matchesState = stateFilter == "All" || instance.state == stateFilter
            let matchesHealth = healthFilter == .all
                || instanceHealth[instance.instanceId]?.needsAttention == true
                || instanceHealthErrors[instance.instanceId] != nil
            let matchesSearch = query.isEmpty || [
                instance.name,
                instance.instanceId,
                instance.instanceType,
                instance.state,
                instance.privateIP,
                instance.publicIP,
                instance.vpcId,
                instance.subnetId,
                instance.availabilityZone
            ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
            || instance.tags.contains { key, value in
                key.lowercased().contains(query) || value.lowercased().contains(query)
            }
            return matchesState && matchesHealth && matchesSearch
        }
    }

    func configure(provider: AWSServiceProvider, scope: MonitoringScope, refreshImmediately: Bool = true) {
        instanceLoader = {
            let client = try await provider.ec2Client(scope: scope)
            return try await Self.fetchInstances(client: client)
        }
        imageNameLoader = { ids in
            let client = try await provider.ec2Client(scope: scope)
            return try await Self.fetchImageNames(ids: ids, client: client)
        }
        healthLoader = nil
        healthResultLoader = { ids in
            let client = try await provider.ec2Client(scope: scope)
            return try await EC2InstanceHealthService(client: client).load(instanceIds: ids)
        }
        detailLoader = { instanceId in
            let client = try await provider.ec2Client(scope: scope)
            return try await Self.fetchDetail(instanceId: instanceId, client: client)
        }
        reset()
        self.scope = scope
        if refreshImmediately { refresh() }
    }

    func loadIfNeeded() {
        guard !hasAttemptedLoad else { return }
        refresh()
    }

    func refresh() {
        guard instanceLoader != nil else { return }
        hasAttemptedLoad = true
        loadTask?.cancel()
        loadTask = Task { await loadInstances() }
    }

    func waitForCurrentLoad() async { await loadTask?.value }

    func cancelLoading() {
        if isHealthLoading {
            for instance in instances where instanceHealth[instance.instanceId]?.hasStatusChecks != true {
                instanceHealthErrors[instance.instanceId] = "Loading cancelled. Use Refresh to try again."
            }
        }
        listGeneration += 1
        loadTask?.cancel()
        detailTask?.cancel()
        isLoading = false
        isDetailLoading = false
        isHealthLoading = false
    }

    func reset() {
        scope = nil
        cancelLoading()
        hasAttemptedLoad = false
        detailTask?.cancel()
        instances = []
        selectedInstance = nil
        instanceHealth = [:]
        instanceHealthErrors = [:]
        isHealthLoading = false
        instanceDetail = nil
        error = nil
        detailError = nil
        isDetailLoading = false
        stateFilter = "All"
        healthFilter = .all
    }

    func loadInstances(selectFirstIfNeeded: Bool = true) async {
        guard !Task.isCancelled, let instanceLoader else { return }
        hasAttemptedLoad = true
        listGeneration += 1
        let generation = listGeneration
        detailTask?.cancel()
        instanceDetail = nil
        detailError = nil
        isDetailLoading = false
        instanceHealth = [:]
        instanceHealthErrors = [:]
        isHealthLoading = true
        isLoading = true
        error = nil
        defer {
            if generation == listGeneration {
                isLoading = false
                isHealthLoading = false
            }
        }

        do {
            let rows = try await instanceLoader()
            try Task.checkCancellation()
            guard generation == listGeneration else { return }

            let imageIDs = Array(Set(rows.compactMap(\.imageId)))
            let imageNames: [String: String]
            do {
                imageNames = try await imageNameLoader?(imageIDs) ?? [:]
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                imageNames = [:]
            }

            try Task.checkCancellation()
            guard generation == listGeneration else { return }
            let loadedInstances = rows.map { row in
                EC2InstanceModel(
                    instanceId: row.instanceId,
                    name: row.name,
                    instanceType: row.instanceType,
                    state: row.state,
                    privateIP: row.privateIP,
                    publicIP: row.publicIP,
                    platformDetails: row.platformDetails,
                    architecture: row.architecture,
                    vpcId: row.vpcId,
                    subnetId: row.subnetId,
                    availabilityZone: row.availabilityZone,
                    securityGroups: row.securityGroups,
                    imageId: row.imageId,
                    imageName: row.imageId.flatMap { imageNames[$0] } ?? row.imageName,
                    keyName: row.keyName,
                    launchTime: row.launchTime,
                    tags: row.tags
                )
            }

            instances = loadedInstances
            let ids = loadedInstances.map(\.instanceId)
            let loadedHealth: EC2InstanceHealthResult
            do {
                if let healthResultLoader {
                    loadedHealth = try await healthResultLoader(ids)
                } else {
                    loadedHealth = .init(health: try await healthLoader?(ids) ?? [:], errors: [:])
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let message = EC2InstanceHealthService.errorMessage(error)
                loadedHealth = .init(health: [:], errors: Dictionary(ids.map { ($0, message) }, uniquingKeysWith: { first, _ in first }))
            }

            try Task.checkCancellation()
            guard generation == listGeneration else { return }
            let selectedID = selectedInstance?.instanceId
            let wanted = Set(ids)
            var mergedHealth = loadedHealth.health.filter { wanted.contains($0.key) }
            for (id, value) in instanceHealth where wanted.contains(id) && mergedHealth[id]?.hasStatusChecks != true {
                mergedHealth[id] = value
            }
            instanceHealth = mergedHealth
            instanceHealthErrors = loadedHealth.errors.filter { wanted.contains($0.key) && mergedHealth[$0.key]?.hasStatusChecks != true }
            for id in ids where mergedHealth[id]?.hasStatusChecks != true && instanceHealthErrors[id] == nil {
                instanceHealthErrors[id] = EC2InstanceHealthResult.notReturned
            }
            selectedInstance = selectedID.flatMap { id in
                loadedInstances.first { $0.instanceId == id }
            } ?? (selectFirstIfNeeded ? loadedInstances.first : nil)
            if selectedID == selectedInstance?.instanceId, instanceDetail == nil, !isDetailLoading {
                loadDetailForSelection()
            }

            if !availableStates.contains(stateFilter) {
                stateFilter = "All"
            }
        } catch {
            guard generation == listGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            instances = []
            selectedInstance = nil
            instanceHealth = [:]
            instanceHealthErrors = [:]
            self.error = UserFacingError.message(for: error)
        }
    }

    func loadDetailForSelection() {
        detailTask?.cancel()
        instanceDetail = nil
        detailError = nil

        guard let instanceId = selectedInstance?.instanceId, detailLoader != nil else {
            isDetailLoading = false
            return
        }

        isDetailLoading = true
        detailTask = Task { await loadDetail(instanceId: instanceId) }
    }

    func loadDetail(instanceId: String) async {
        guard !Task.isCancelled, let detailLoader else { return }
        let generation = listGeneration

        do {
            let detail = try await detailLoader(instanceId)
            try Task.checkCancellation()
            guard generation == listGeneration, selectedInstance?.instanceId == instanceId else { return }
            instanceDetail = detail
            if let health = detail.health {
                instanceHealth[instanceId] = health
                if health.hasStatusChecks { instanceHealthErrors[instanceId] = nil }
                else { instanceHealthErrors[instanceId] = EC2InstanceHealthResult.notReturned }
            } else if instanceHealth[instanceId]?.hasStatusChecks != true, instanceHealthErrors[instanceId] == nil {
                instanceHealthErrors[instanceId] = EC2InstanceHealthResult.notReturned
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            guard generation == listGeneration, selectedInstance?.instanceId == instanceId else { return }
            detailError = UserFacingError.message(for: error)
        }

        if generation == listGeneration, selectedInstance?.instanceId == instanceId {
            isDetailLoading = false
        }
    }

    private static func fetchInstances(client: EC2) async throws -> [EC2InstanceModel] {
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

    private static func fetchImageNames(ids: [String], client: EC2) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let response = try await client.describeImages(.init(imageIds: ids))
        return Dictionary(
            uniqueKeysWithValues: (response.images ?? []).compactMap { image in
                guard let imageId = image.imageId else { return nil }
                return (imageId, image.name ?? image.description ?? "Unknown")
            }
        )
    }

    private static func fetchDetail(
        instanceId: String,
        client: EC2
    ) async throws -> EC2InstanceDetailModel {
        let response = try await client.describeInstances(.init(instanceIds: [instanceId]))
        guard let instance = response.reservations?.first?.instances?.first else {
            throw EC2DetailError.instanceNotFound
        }

        var warnings: [String] = []
        let status: EC2InstanceHealth?
        do {
            status = try await EC2InstanceHealthService(client: client).loadDetail(instanceId: instanceId)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            status = nil
            warnings.append("Status checks: \(UserFacingError.message(for: error))")
        }

        try Task.checkCancellation()
        let mappings = instance.blockDeviceMappings ?? []
        let volumeIds = mappings.compactMap(\.ebs?.volumeId)
        let volumes: [EC2VolumeModel]
        do {
            volumes = try await fetchVolumes(
                instanceId: instanceId,
                volumeIds: volumeIds,
                mappings: mappings,
                client: client
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            volumes = []
            warnings.append("EBS volumes: \(UserFacingError.message(for: error))")
        }

        try Task.checkCancellation()
        let groupIds = Array(
            Set((instance.securityGroups ?? []).compactMap(\.groupId))
        )
        let securityGroups: [EC2SecurityGroupModel]
        do {
            securityGroups = try await fetchSecurityGroups(ids: groupIds, client: client)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            securityGroups = []
            warnings.append("Security groups: \(UserFacingError.message(for: error))")
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
            volumes: volumes,
            securityGroups: securityGroups,
            health: status,
            warnings: warnings,
            cpuCreditMode: cpuCreditMode
        )
    }

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
        mappings: [EC2.InstanceBlockDeviceMapping],
        client: EC2
    ) async throws -> [EC2VolumeModel] {
        guard !volumeIds.isEmpty else { return [] }
        let response = try await client.describeVolumes(.init(volumeIds: volumeIds))
        let mappingByVolumeId: [String: EC2.InstanceBlockDeviceMapping] = Dictionary(
            uniqueKeysWithValues: mappings.compactMap { mapping in
                guard let volumeId = mapping.ebs?.volumeId else { return nil }
                return (volumeId, mapping)
            }
        )

        return (response.volumes ?? []).compactMap { volume -> EC2VolumeModel? in
            guard let volumeId = volume.volumeId else { return nil }
            let mapping = mappingByVolumeId[volumeId]
            let attachment = volume.attachments?.first { $0.instanceId == instanceId }
            let tags = dictionary(from: volume.tags)
            return EC2VolumeModel(
                volumeId: volumeId,
                name: tags["Name"],
                device: attachment?.device ?? mapping?.deviceName,
                state: volume.state?.rawValue,
                type: volume.volumeType?.rawValue,
                sizeGiB: volume.size,
                iops: volume.iops,
                throughputMiBps: volume.throughput,
                encrypted: volume.encrypted,
                deleteOnTermination: attachment?.deleteOnTermination
                    ?? mapping?.ebs?.deleteOnTermination,
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
}

private enum EC2DetailError: LocalizedError {
    case instanceNotFound

    var errorDescription: String? {
        "The selected EC2 instance is no longer available."
    }
}
