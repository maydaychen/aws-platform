import SwiftUI

struct EmptyStateView: View {
    let text: String
    var icon: String = "tray"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundColor(.secondary)
            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DetailGrid: View {
    let items: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [.init(.adaptive(minimum: 210), alignment: .topLeading)], alignment: .leading, spacing: 10) {
            ForEach(items, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 6) {
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(value)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06)))
            }
        }
    }
}

struct ListToolbar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let isLoading: Bool
    @Binding var searchText: String
    let onRefresh: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                Spacer()
                if isLoading {
                    HStack(spacing: 6) {
                        if reduceMotion {
                            Text("Loading…").font(.caption).foregroundColor(.secondary)
                        } else {
                            ProgressView().controlSize(.small).accessibilityLabel("Refreshing \(title)")
                        }
                    }
                    .transition(.opacity)
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle")
                    }
                    .help("Cancel")
                    .accessibilityLabel("Cancel refresh")
                }
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help("Refresh")
                .accessibilityLabel("Refresh \(title)")
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isLoading)
            ResourceSearchField(text: $searchText)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

struct ResourceSearchField: View {
    @Binding var text: String
    var placeholder = "Search resources"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(7)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.08)))
    }
}

struct ResourceListFooter: View {
    let visible: Int
    let total: Int

    var body: some View {
        HStack {
            Text(visible == total ? "\(total) \(total == 1 ? "resource" : "resources")" : "\(visible) of \(total) resources")
            Spacer()
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }
}

struct DetailSectionTitle: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.headline)
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
        }
        .padding(.top, 4)
    }
}

struct DetailKeyValueRows: View {
    let values: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(values.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key).font(.caption).foregroundColor(.secondary)
                    Text(values[key] ?? "").font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                if key != values.keys.sorted().last { Divider() }
            }
        }
        .padding(.horizontal, 12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct NoticeBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(message).foregroundColor(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
