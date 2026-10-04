import SwiftUI

struct S3ObjectDetailView: View {
    @Environment(\.locale) private var locale
    let object: S3ObjectModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.text(object.isPrefix ? "FOLDER" : "S3 OBJECT", locale: locale), systemImage: object.isPrefix ? "folder" : "doc")
                        .font(.caption).foregroundColor(.secondary)
                    Text(object.key)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DetailGrid(items: [
                    ("Type", L10n.text(object.isPrefix ? "Prefix" : "Object", locale: locale)),
                    ("Size", object.size.map { $0.formatted(.byteCount(style: .file).locale(locale)) } ?? "-"),
                    ("Last Modified", object.lastModified?.formatted(Date.FormatStyle().locale(locale)) ?? "-"),
                    ("Storage Class", object.storageClass ?? "-")
                ])
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
