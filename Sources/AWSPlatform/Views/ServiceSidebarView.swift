import SwiftUI

struct ServiceSidebarView: View {
    @Binding var selectedService: AWSService
    @Binding var destination: WorkspaceDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WORKSPACE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Button {
                destination = .favorites
            } label: {
                Label("Favorites", systemImage: destination == .favorites ? "star.fill" : "star")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(destination == .favorites ? Color.accentColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Button {
                destination = .recents
            } label: {
                Label("Recent", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(destination == .recents ? Color.accentColor.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button {
                destination = .costs
            } label: {
                Label("Costs", systemImage: "chart.bar.xaxis")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(destination == .costs ? Color.accentColor.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Button {
                destination = .health
            } label: {
                Label("Health", systemImage: "heart.text.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(destination == .health ? Color.accentColor.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            Text("SERVICES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 20)
                .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(AWSService.allCases) { service in
                        Button {
                            destination = .resources
                            selectedService = service
                        } label: {
                            Label(service.rawValue, systemImage: service.icon)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(destination == .resources && selectedService == service ? Color.accentColor.opacity(0.18) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Label("Read only", systemImage: "lock")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(10)
        }
        .padding(8)
        .frame(width: 176)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }
}
