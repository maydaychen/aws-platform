import SwiftUI

struct S3ObjectDetailView: View {
    let object: S3ObjectModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(object.isPrefix ? "FOLDER" : "S3 OBJECT", systemImage: object.isPrefix ? "folder" : "doc")
                        .font(.caption).foregroundColor(.secondary)
                    Text(object.key)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DetailGrid(items: [
                    ("Type", object.isPrefix ? "Prefix" : "Object"),
                    ("Size", object.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "-"),
                    ("Last Modified", object.lastModified?.formatted() ?? "-"),
                    ("Storage Class", object.storageClass ?? "-")
                ])
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
