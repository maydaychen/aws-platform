import SwiftUI

struct S3BucketDetailView: View {
    let bucket: S3BucketModel
    let onBrowse: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("S3 BUCKET", systemImage: "externaldrive")
                        .font(.caption).foregroundColor(.secondary)
                    Text(bucket.name)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DetailGrid(items: detailItems)

                Button("Browse Objects", action: onBrowse)
                    .buttonStyle(.borderedProminent)

                if let detailError = bucket.detailError {
                    NoticeBanner(message: detailError)
                }

                if !bucket.tags.isEmpty {
                    DetailSectionTitle(title: "Tags")
                    DetailKeyValueRows(values: bucket.tags)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func display(_ value: Bool?) -> String {
        guard let value else { return "-" }
        return value ? "Enabled" : "Disabled"
    }

    private func display(_ value: Bool) -> String {
        value ? "Enabled" : "Disabled"
    }

    private var detailItems: [(String, String)] {
        var items = [
            ("Region", bucket.region ?? "-"),
            ("Created", bucket.creationDate?.formatted() ?? "-"),
            ("Versioning", display(bucket.versioningEnabled)),
            ("Encryption", display(bucket.encryptionEnabled))
        ]
        if let publicAccessBlock = bucket.publicAccessBlock {
            items.append(contentsOf: [
                ("Block Public ACLs", display(publicAccessBlock.blockPublicACLs)),
                ("Ignore Public ACLs", display(publicAccessBlock.ignorePublicACLs)),
                ("Block Public Policy", display(publicAccessBlock.blockPublicPolicy)),
                ("Restrict Public Buckets", display(publicAccessBlock.restrictPublicBuckets))
            ])
        } else {
            items.append(("Public Access Block", "-"))
        }
        return items
    }
}
