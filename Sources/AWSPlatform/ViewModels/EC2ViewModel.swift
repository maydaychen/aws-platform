import Foundation
import SotoEC2

@MainActor
final class EC2ViewModel: ObservableObject {
    typealias InstanceLoader = () async throws -> [EC2InstanceModel]
    typealias ImageNameLoader = ([String]) async throws -> [String: String]

    @Published var instances: [EC2InstanceModel] = []
    @Published var selectedInstance: EC2InstanceModel?
    @Published var isLoading = false
    @Published var error: String?
    @Published var searchText = ""

    private var loadTask: Task<Void, Never>?
    private var instanceLoader: InstanceLoader?
    private var imageNameLoader: ImageNameLoader?

    init(
        instanceLoader: InstanceLoader? = nil,
        imageNameLoader: ImageNameLoader? = nil
    ) {
        self.instanceLoader = instanceLoader
        self.imageNameLoader = imageNameLoader
    }

    var filteredInstances: [EC2InstanceModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return instances }
        return instances.filter { instance in
            [
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
        }
    }

    func configure(provider: AWSServiceProvider) {
        instanceLoader = {
            let client = try await provider.ec2Client()
            return try await Self.fetchInstances(client: client)
        }
        imageNameLoader = { ids in
            let client = try await provider.ec2Client()
            return try await Self.fetchImageNames(ids: ids, client: client)
        }
        loadTask?.cancel()
        instances = []
        selectedInstance = nil
        refresh()
    }

    func refresh() {
        loadTask?.cancel()
        loadTask = Task { await loadInstances() }
    }

    func cancelLoading() {
        loadTask?.cancel()
        isLoading = false
    }

    func reset() {
        cancelLoading()
        instances = []
        selectedInstance = nil
        error = nil
    }

    func loadInstances() async {
        guard let instanceLoader else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let rows = try await instanceLoader()
            try Task.checkCancellation()

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
            instances = rows.map { row in
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

            if selectedInstance == nil {
                selectedInstance = instances.first
            }
        } catch {
            if error is CancellationError { return }
            instances = []
            selectedInstance = nil
            self.error = UserFacingError.message(for: error)
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
                    let tags = Dictionary<String, String>(
                        uniqueKeysWithValues: (instance.tags ?? []).compactMap { tag in
                            guard let key = tag.key else { return nil }
                            return (key, tag.value ?? "")
                        }
                    )

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
                            securityGroups: (instance.securityGroups ?? []).compactMap { $0.groupId ?? $0.groupName },
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
}
