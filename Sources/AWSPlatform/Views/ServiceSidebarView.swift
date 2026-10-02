import SwiftUI

struct ServiceSidebarView: View {
    @Binding var selectedService: AWSService
    @Binding var showingFavorites: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WORKSPACE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Button {
                showingFavorites = true
            } label: {
                Label("Favorites", systemImage: showingFavorites ? "star.fill" : "star")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(showingFavorites ? Color.accentColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Text("SERVICES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 20)
                .padding(.bottom, 8)
            ForEach(AWSService.allCases) { service in
                Button {
                    showingFavorites = false
                    selectedService = service
                } label: {
                    Label(service.rawValue, systemImage: service.icon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(!showingFavorites && selectedService == service ? Color.accentColor.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Label("Read only", systemImage: "lock")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(10)
        }
        .padding(8)
        .frame(width: 144)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }
}
