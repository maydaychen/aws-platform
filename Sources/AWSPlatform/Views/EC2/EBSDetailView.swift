import SwiftUI

struct EBSDetailView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: EBSViewModel

    var body: some View {
        if let resource = vm.selectedResource, vm.scope?.isValid == true, vm.resources.contains(resource) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
                    Text(resource.name).font(.title2).fontWeight(.semibold).lineLimit(2).textSelection(.enabled)
                    Text(resource.id).font(.caption.monospaced()).foregroundColor(.secondary).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let error = vm.error { NoticeBanner(message: error) }
                        if vm.isStale { NoticeBanner(message: "Showing previously loaded EBS resources; they may be out of date.") }
                        Text(L10n.text("Overview", locale: locale)).font(.headline)
                        DetailFieldRows(items: overview(resource))
                        if resource.kind == .volume {
                            Text(L10n.text("Volume attachments", locale: locale)).font(.headline)
                            if resource.attachments.isEmpty {
                                Text(L10n.text("No volume attachments returned.", locale: locale)).foregroundColor(.secondary)
                            }
                            ForEach(Array(resource.attachments.enumerated()), id: \.offset) { _, attachment in
                                DetailFieldRows(items: [
                                    ("Instance ID", attachment.instanceID ?? "-"), ("Device", attachment.device ?? "-"),
                                    ("State", attachment.state ?? "-"), ("Delete on Termination", boolean(attachment.deleteOnTermination))
                                ])
                            }
                        }
                        Text(L10n.text("Tags", locale: locale)).font(.headline)
                        if resource.tags.isEmpty {
                            Text(L10n.text("No tags returned.", locale: locale)).foregroundColor(.secondary)
                        } else {
                            ForEach(resource.tags.keys.sorted(), id: \.self) { key in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(key).font(.caption).foregroundColor(.secondary)
                                    Text(resource.tags[key] ?? "").font(.callout)
                                }.textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .id(resource.id)
            }
        } else {
            EmptyStateView(text: vm.kind.emptySelection, icon: vm.kind.service.icon)
        }
    }

    private func overview(_ resource: EBSResource) -> [(String, String)] {
        var fields = [
            ("State", L10n.text(resource.state, locale: locale)), ("Account", resource.ownerID), ("Region", vm.scope?.region ?? "-"),
            ("Size", resource.sizeGiB.map { "\($0) GiB" } ?? "-"), ("Encrypted", boolean(resource.encrypted)),
            ("KMS Key", resource.kmsKeyID ?? "-"),
            ("Created", resource.createdAt?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)) ?? "-")
        ]
        if resource.kind == .volume {
            fields += [("Type", resource.volumeType ?? "-"), ("Availability Zone", resource.availabilityZone ?? "-"),
                       ("IOPS", resource.iops.map(String.init) ?? "-"),
                       ("Throughput", resource.throughput.map { "\($0) MiB/s" } ?? "-"), ("Source snapshot", resource.snapshotID ?? "-")]
        } else {
            fields += [("Source volume", resource.volumeID ?? "-"), ("Progress", resource.progress ?? "-"),
                       ("Storage tier", resource.storageTier ?? "-"), ("Description", resource.description ?? "-")]
        }
        return fields
    }

    private func boolean(_ value: Bool?) -> String {
        value.map { L10n.text($0 ? "Yes" : "No", locale: locale) } ?? L10n.text("Unknown", locale: locale)
    }
}
