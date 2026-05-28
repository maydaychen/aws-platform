import SwiftUI

struct S3BucketDetailView: View {
    let bucket: S3BucketModel
    let onBrowse: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(bucket.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                DetailGrid(items: [
                    ("Region", bucket.region ?? "-"),
                    ("Created", bucket.creationDate?.formatted() ?? "-"),
                    ("Versioning", display(bucket.versioningEnabled)),
                    ("Encryption", display(bucket.encryptionEnabled)),
                    ("Public Access Block", display(bucket.publicAccessBlock))
                ])

                Button("Browse Objects", action: onBrowse)
                    .buttonStyle(.borderedProminent)

                if !bucket.tags.isEmpty {
                    Text("Tags")
                        .font(.headline)
                    ForEach(bucket.tags.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(bucket.tags[key] ?? "")")
                            .font(.caption)
                    }
                }
            }
            .padding()
        }
    }

    private func display(_ value: Bool?) -> String {
        guard let value else { return "-" }
        return value ? "Enabled" : "Disabled"
    }
}
