import SwiftUI

struct EmptyStateView: View {
    @Environment(\.locale) private var locale
    let text: String
    var icon: String = "tray"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundColor(.secondary)
            Text(L10n.text(text, locale: locale))
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
    @Environment(\.locale) private var locale
    let items: [(String, String)]
    var localizesLabels = true

    var body: some View {
        LazyVGrid(columns: [.init(.adaptive(minimum: 210), alignment: .topLeading)], alignment: .leading, spacing: 10) {
            ForEach(items, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 6) {
                    Text(localizesLabels ? L10n.text(label, locale: locale) : label)
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
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let isLoading: Bool
    @Binding var searchText: String
    let onRefresh: () -> Void
    let onCancel: () -> Void
    var searchPlaceholder = "Search resources"

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.text(title, locale: locale))
                    .font(.headline)
                Spacer()
                if isLoading {
                    HStack(spacing: 6) {
                        if reduceMotion {
                            Text(L10n.text("Loading…", locale: locale)).font(.caption).foregroundColor(.secondary)
                        } else {
                            ProgressView().controlSize(.small).accessibilityLabel(L10n.format("Refreshing %@", L10n.text(title, locale: locale), locale: locale))
                        }
                    }
                    .transition(.opacity)
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle")
                    }
                    .help(L10n.text("Cancel", locale: locale))
                    .accessibilityLabel(L10n.text("Cancel refresh", locale: locale))
                }
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help(L10n.text("Refresh", locale: locale))
                .accessibilityLabel(L10n.format("Refresh %@", L10n.text(title, locale: locale), locale: locale))
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isLoading)
            ResourceSearchField(text: $searchText, placeholder: searchPlaceholder)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

struct ResourceSearchField: View {
    @Environment(\.locale) private var locale
    @Binding var text: String
    var placeholder = "Search resources"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(L10n.text(placeholder, locale: locale), text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(L10n.text(placeholder, locale: locale))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help(L10n.text("Clear search", locale: locale))
                    .accessibilityLabel(L10n.text("Clear search", locale: locale))
            }
        }
        .padding(7)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.08)))
    }
}

struct ResourceListFooter: View {
    @Environment(\.locale) private var locale
    let visible: Int
    let total: Int

    var body: some View {
        HStack {
            Text(visible == total
                 ? L10n.format(total == 1 ? "%@ resource" : "%@ resources", String(total), locale: locale)
                 : L10n.format("%@ of %@ resources", String(visible), String(total), locale: locale))
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
    @Environment(\.locale) private var locale
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text(L10n.text(title, locale: locale)).font(.headline)
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
        }
        .padding(.top, 4)
    }
}

struct DetailKeyValueRows: View {
    @Environment(\.locale) private var locale
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
    @Environment(\.locale) private var locale
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(L10n.text(message, locale: locale)).foregroundColor(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
