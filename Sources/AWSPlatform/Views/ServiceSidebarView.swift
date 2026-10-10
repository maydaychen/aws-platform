import AppKit
import SwiftUI

struct ServiceSidebarView: View {
    @Environment(\.locale) private var locale
    @Binding var selectedService: AWSService
    @Binding var destination: WorkspaceDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("WORKSPACE", locale: locale))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    Button {
                        activate(.favorites)
                    } label: {
                        Label(L10n.text("Favorites", locale: locale), systemImage: destination == .favorites ? "star.fill" : "star")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(destination == .favorites ? Color.accentColor.opacity(0.18) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace.favorites")
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    Button {
                        activate(.recents)
                    } label: {
                        Label(L10n.text("Recent", locale: locale), systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(destination == .recents ? Color.accentColor.opacity(0.18) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace.recents")
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    Button {
                        activate(.costs)
                    } label: {
                        Label(L10n.text("Costs", locale: locale), systemImage: "chart.bar.xaxis")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(destination == .costs ? Color.accentColor.opacity(0.18) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace.costs")
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    Button {
                        activate(.health)
                    } label: {
                        Label(L10n.text("Health", locale: locale), systemImage: "heart.text.square")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(destination == .health ? Color.accentColor.opacity(0.18) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace.health")
                    Text(L10n.text("SERVICES", locale: locale))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 20)
                        .padding(.bottom, 8)
                    VStack(spacing: 2) {
                        ForEach(AWSService.allCases) { service in
                            Button {
                                activate(.resources, service: service)
                            } label: {
                                Label(L10n.text(service.rawValue, locale: locale), systemImage: service.icon)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(destination == .resources && selectedService == service ? Color.accentColor.opacity(0.18) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("service.\(service.rawValue)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            settingsLink
                .buttonStyle(.plain)
                .help(L10n.text("Settings (⌘,)", locale: locale))
            Label(L10n.text("Read only", locale: locale), systemImage: "lock")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(10)
        }
        .padding(8)
        .frame(width: 176)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }

    private func activate(_ nextDestination: WorkspaceDestination, service: AWSService? = nil) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            destination = nextDestination
            if let service { selectedService = service }
        }
    }

    private var settingsLabel: some View {
        Label(L10n.text("Settings", locale: locale), systemImage: "gearshape")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var settingsLink: some View {
        if #available(macOS 14, *) {
            SettingsLink {
                settingsLabel
            }
        } else {
            // SettingsLink requires macOS 14; the native Settings scene supplies this responder action on 13.
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                settingsLabel
            }
        }
    }
}
