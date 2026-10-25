import Foundation

struct EC2InstanceModel: Identifiable, Hashable {
    let instanceId: String
    let name: String
    let instanceType: String
    let state: String
    let privateIP: String?
    let publicIP: String?
    let platformDetails: String?
    let architecture: String?
    let vpcId: String?
    let subnetId: String?
    let availabilityZone: String?
    let securityGroups: [String]
    let imageId: String?
    let imageName: String?
    let keyName: String?
    let launchTime: Date?
    let tags: [String: String]

    var id: String { instanceId }
}
