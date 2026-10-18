import SwiftUI

struct RDSDatabaseFieldsView: View {
    @Environment(\.locale) private var locale
    let database: RDSDatabase
    let scope: MonitoringScope?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailSectionTitle(title: "Overview")
            DetailFieldRows(items: overview)
            DetailSectionTitle(title: "Endpoints and network")
            DetailFieldRows(items: network)
            DetailSectionTitle(title: "Storage and protection")
            DetailFieldRows(items: storage)
            if database.serverlessV2MinACU != nil || database.serverlessV2MaxACU != nil {
                DetailSectionTitle(title: "Serverless v2 capacity")
                DetailFieldRows(items: [
                    ("Minimum capacity (ACU)", database.serverlessV2MinACU.map { String($0) } ?? missing),
                    ("Maximum capacity (ACU)", database.serverlessV2MaxACU.map { String($0) } ?? missing)
                ])
            }
            if database.kind == .cluster {
                DetailSectionTitle(title: "DB cluster members")
                if database.members.isEmpty {
                    Text(L10n.text("No DB cluster members returned.", locale: locale)).foregroundColor(.secondary)
                }
                ForEach(database.members) { member in
                    DetailFieldRows(items: [("DB instance", member.identifier),
                                            ("Writer", boolean(member.isWriter)),
                                            ("Promotion tier", number(member.promotionTier))])
                }
            }
            tags
        }
    }

    private var overview: [(String, String)] {
        var fields = [
            ("ARN", database.arn), ("Account ID", value(scope?.accountID)), ("Region", value(scope?.region)),
            ("Engine", value(database.engine)), ("Engine version", value(database.engineVersion)),
            ("Status", value(database.status)), ("Instance class", value(database.instanceClass)),
            ("Created", database.createdAt.map { $0.formatted(.dateTime.year().month().day().hour().minute().locale(locale)) } ?? missing)
        ]
        if database.kind == .instance { fields += [("DB cluster identifier", value(database.clusterIdentifier))] }
        if database.kind == .cluster { fields += [("Engine mode", value(database.engineMode))] }
        return fields
    }

    private var network: [(String, String)] {
        var fields = [("Endpoint", value(database.endpoint)), ("Port", number(database.port))]
        if database.kind == .cluster {
            fields += [("Reader endpoint", value(database.readerEndpoint)),
                       ("Availability Zones", lines(database.availabilityZones))]
        } else {
            fields += [("Availability Zone", value(database.availabilityZone)),
                       ("Secondary Availability Zone", value(database.secondaryAvailabilityZone)),
                       ("VPC ID", value(database.vpcID)), ("Subnets", lines(database.subnetIDs))]
        }
        fields += [("Multi-AZ", boolean(database.multiAZ)),
                   ("Publicly accessible", boolean(database.publiclyAccessible)),
                   ("DB subnet group", value(database.subnetGroup)),
                   ("Security groups", lines(database.securityGroupIDs))]
        return fields
    }

    private var storage: [(String, String)] {
        [("Allocated storage", database.allocatedStorageGB.map { "\($0) GiB" } ?? missing),
         ("Storage type", value(database.storageType)), ("Encrypted", boolean(database.encrypted)),
         ("KMS Key", value(database.kmsKeyID)), ("Backup retention (days)", number(database.backupRetentionDays)),
         ("Deletion protection", boolean(database.deletionProtection))]
    }

    @ViewBuilder
    private var tags: some View {
        DetailSectionTitle(title: "Tags")
        if let tags = database.tags {
            if tags.isEmpty {
                Text(L10n.text("No tags returned.", locale: locale)).foregroundColor(.secondary)
            }
            ForEach(tags.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key).font(.caption).foregroundColor(.secondary)
                    Text(tags[key] ?? "").font(.callout)
                }
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(L10n.text("Tags were not returned.", locale: locale)).foregroundColor(.secondary)
        }
    }

    private var missing: String { L10n.text("Not returned", locale: locale) }
    private func value(_ text: String?) -> String { text.flatMap { $0.isEmpty ? nil : $0 } ?? missing }
    private func number(_ value: Int?) -> String { value.map(String.init) ?? missing }
    private func lines(_ values: [String]) -> String { values.isEmpty ? missing : values.joined(separator: "\n") }
    private func boolean(_ value: Bool?) -> String {
        value.map { L10n.text($0 ? "Yes" : "No", locale: locale) } ?? L10n.text("Unknown", locale: locale)
    }
}
