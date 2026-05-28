import SwiftUI

struct S3ObjectDetailView: View {
    let object: S3ObjectModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(object.key)
                    .font(.title3)
                    .fontWeight(.semibold)

                DetailGrid(items: [
                    ("Type", object.isPrefix ? "Prefix" : "Object"),
                    ("Size", object.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "-"),
                    ("Last Modified", object.lastModified?.formatted() ?? "-"),
                    ("Storage Class", object.storageClass ?? "-")
                ])
            }
            .padding()
        }
    }
}
