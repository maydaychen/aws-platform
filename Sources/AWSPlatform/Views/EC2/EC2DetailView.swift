import SwiftUI

struct EC2DetailView: View {
    let instance: EC2InstanceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(instance.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                DetailGrid(items: [
                    ("Instance ID", instance.instanceId),
                    ("State", instance.state),
                    ("Type", instance.instanceType),
                    ("OS", instance.imageName ?? instance.platformDetails ?? "-"),
                    ("Architecture", instance.architecture ?? "-"),
                    ("Private IP", instance.privateIP ?? "-"),
                    ("Public IP", instance.publicIP ?? "-"),
                    ("VPC", instance.vpcId ?? "-"),
                    ("Subnet", instance.subnetId ?? "-"),
                    ("AZ", instance.availabilityZone ?? "-"),
                    ("AMI", instance.imageId ?? "-"),
                    ("Key Pair", instance.keyName ?? "-"),
                    ("Launch Time", instance.launchTime?.formatted() ?? "-")
                ])

                if !instance.securityGroups.isEmpty {
                    Text("Security Groups")
                        .font(.headline)
                    Text(instance.securityGroups.joined(separator: ", "))
                        .foregroundColor(.secondary)
                }

                if !instance.tags.isEmpty {
                    Text("Tags")
                        .font(.headline)
                    ForEach(instance.tags.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(instance.tags[key] ?? "")")
                            .font(.caption)
                    }
                }
            }
            .padding()
        }
    }
}
