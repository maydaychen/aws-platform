import AppKit
import SwiftUI

struct ServiceSidebarView: View {
    @Environment(\.locale) private var locale
    @Binding var selectedService: AWSService
    @Binding var destination: WorkspaceDestination
    @AppStorage("sidebar.ec2Expanded") private var ec2Expanded = true
    @AppStorage("sidebar.cloudWatchExpanded") private var cloudWatchExpanded = true

    init(selectedService: Binding<AWSService>, destination: Binding<WorkspaceDestination>, defaults: UserDefaults = .standard) {
        _selectedService = selectedService
        _destination = destination
        _ec2Expanded = AppStorage(wrappedValue: true, "sidebar.ec2Expanded", store: defaults)
        _cloudWatchExpanded = AppStorage(wrappedValue: true, "sidebar.cloudWatchExpanded", store: defaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("WORKSPACE", locale: locale))
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    WorkspaceSidebarButton(title: "Favorites", systemImage: destination == .favorites ? "star.fill" : "star",
                                           isSelected: destination == .favorites, accessibilityID: "workspace.favorites",
                                           shortcut: "f") { activate(.favorites) }
                    WorkspaceSidebarButton(title: "Recent", systemImage: "clock.arrow.circlepath",
                                           isSelected: destination == .recents, accessibilityID: "workspace.recents",
                                           shortcut: "r") { activate(.recents) }
                    WorkspaceSidebarButton(title: "Costs", systemImage: "chart.bar.xaxis",
                                           isSelected: destination == .costs, accessibilityID: "workspace.costs",
                                           shortcut: "b") { activate(.costs) }
                    WorkspaceSidebarButton(title: "Health", systemImage: "heart.text.square",
                                           isSelected: destination == .health, accessibilityID: "workspace.health",
                                           shortcut: nil) { activate(.health) }
                    Text(L10n.text("SERVICES", locale: locale))
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 20)
                        .padding(.bottom, 8)
                    VStack(spacing: 2) {
                        Button {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { ec2Expanded.toggle() }
                        } label: {
                            HStack(spacing: WorkspaceLayout.controlSpacing) {
                                Image(systemName: ec2Expanded ? "chevron.down" : "chevron.right").font(.caption)
                                Image(systemName: "server.rack")
                                VStack(alignment: .leading, spacing: WorkspaceLayout.sidebarCaptionSpacing) {
                                    Text("EC2").fontWeight(.medium)
                                    if !ec2Expanded && destination == .resources && selectedService.isEC2Service {
                                        Text(L10n.text(selectedService.sidebarTitle, locale: locale))
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sidebar.ec2.group")
                        .accessibilityLabel(L10n.text(ec2Expanded ? "Collapse EC2 group" : "Expand EC2 group", locale: locale))
                        .accessibilityValue(L10n.text(ec2Expanded ? "Expanded" : "Collapsed", locale: locale))
                        if ec2Expanded {
                            ForEach(AWSService.ec2Services) { service in serviceButton(service, child: true) }
                        }
                        cloudWatchGroup
                        ForEach(AWSService.standaloneServices) { service in serviceButton(service) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            settingsLink
                .buttonStyle(.plain)
                .help(L10n.text("Settings (⌘,)", locale: locale))
            Label("\(L10n.text("Version", locale: locale)) \(AppUpdateController.shared.version)", systemImage: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .padding(8)
        .frame(width: WorkspaceLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(.bar)
        .onChange(of: selectedService) { service in
            if destination == .resources && service.isEC2Service { ec2Expanded = true }
            if destination == .resources && service.isCloudWatchService { cloudWatchExpanded = true }
        }
        .onChange(of: destination) { destination in
            if destination == .resources && selectedService.isEC2Service { ec2Expanded = true }
            if destination == .resources && selectedService.isCloudWatchService { cloudWatchExpanded = true }
        }
    }

    private var cloudWatchGroup: some View {
        VStack(spacing: 2) {
            Button {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { cloudWatchExpanded.toggle() }
            } label: {
                HStack(spacing: WorkspaceLayout.controlSpacing) {
                    Image(systemName: cloudWatchExpanded ? "chevron.down" : "chevron.right").font(.caption)
                    Image(systemName: "chart.bar.xaxis")
                    VStack(alignment: .leading, spacing: WorkspaceLayout.sidebarCaptionSpacing) {
                        Text("CloudWatch").fontWeight(.medium)
                        if !cloudWatchExpanded && destination == .resources && selectedService.isCloudWatchService {
                            Text(L10n.text(selectedService.sidebarTitle, locale: locale))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.cloudwatch.group")
            .accessibilityLabel(L10n.text(cloudWatchExpanded ? "Collapse CloudWatch group" : "Expand CloudWatch group", locale: locale))
            .accessibilityValue(L10n.text(cloudWatchExpanded ? "Expanded" : "Collapsed", locale: locale))
            if cloudWatchExpanded {
                ForEach(AWSService.cloudWatchServices) { service in serviceButton(service, child: true) }
            }
        }
    }

    private func serviceButton(_ service: AWSService, child: Bool = false) -> some View {
        Button { activate(.resources, service: service) } label: {
            Label(L10n.text(service.sidebarTitle, locale: locale), systemImage: service.icon)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).padding(.leading, child ? WorkspaceLayout.sidebarChildIndent : 0)
                .background(destination == .resources && selectedService == service ? Color.accentColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: WorkspaceLayout.selectionCornerRadius)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("service.\(service.rawValue)")
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

private struct WorkspaceSidebarButton: View {
    @Environment(\.locale) private var locale
    let title: String
    let systemImage: String
    let isSelected: Bool
    let accessibilityID: String
    let shortcut: KeyEquivalent?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: [.command, .shift])
        } else {
            button
        }
    }

    private var button: some View {
        Button(action: action) {
            Label(L10n.text(title, locale: locale), systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(isSelected ? Color.accentColor.opacity(0.18) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
                .clipShape(RoundedRectangle(cornerRadius: WorkspaceLayout.selectionCornerRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .onHover { isHovered = $0 }
    }
}
