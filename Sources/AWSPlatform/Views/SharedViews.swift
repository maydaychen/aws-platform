import SwiftUI

struct EmptyStateView: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(text)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DetailGrid: View {
    let items: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
            ForEach(items, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
