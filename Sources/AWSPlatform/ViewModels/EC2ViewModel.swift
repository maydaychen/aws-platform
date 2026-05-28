import Foundation
import SotoEC2

@MainActor
final class EC2ViewModel: ObservableObject {
    @Published var instances: [EC2InstanceModel] = []
    @Published var selectedInstance: EC2InstanceModel?
    @Published var isLoading = false
    @Published var error: String?

    private var provider: AWSServiceProvider?

    func configure(provider: AWSServiceProvider) {
        self.provider = provider
        Task { await loadInstances() }
    }

    func loadInstances() async {
        guard let provider else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let client = try await provider.ec2Client()
            let response = try await client.describeInstances(.init())

            var rows: [EC2InstanceModel] = []
            var imageIDs = Set<String>()

            for reservation in response.reservations ?? [] {
                for instance in reservation.instances ?? [] {
                    let instanceId = instance.instanceId ?? "unknown"
                    let tags = Dictionary(
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

                    if let imageId = instance.imageId {
                        imageIDs.insert(imageId)
                    }
                }
            }

            let imageNames = try await fetchImageNames(ids: Array(imageIDs), client: client)
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
                    imageName: row.imageId.flatMap { imageNames[$0] },
                    keyName: row.keyName,
                    launchTime: row.launchTime,
                    tags: row.tags
                )
            }

            if selectedInstance == nil {
                selectedInstance = instances.first
            }
        } catch {
            instances = []
            selectedInstance = nil
            self.error = error.localizedDescription
        }
    }

    private func fetchImageNames(ids: [String], client: EC2) async throws -> [String: String] {
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
