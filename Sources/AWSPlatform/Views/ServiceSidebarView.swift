import SwiftUI

struct ServiceSidebarView: View {
    @Binding var selectedService: AWSService
    @Binding var showingFavorites: Bool

    var body: some View {
        VStack(spacing: 8) {
            Button {
                showingFavorites = true
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "star").font(.title3)
                    Text("Favorites").font(.caption2)
                }
                .frame(width: 72, height: 60)
                .background(showingFavorites ? Color.accentColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            ForEach(AWSService.allCases) { service in
                Button {
                    showingFavorites = false
                    selectedService = service
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: service.icon)
                            .font(.title3)
                        Text(service.rawValue)
                            .font(.caption2)
                    }
                    .frame(width: 72, height: 60)
                    .background(!showingFavorites && selectedService == service ? Color.accentColor.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
    }
}
