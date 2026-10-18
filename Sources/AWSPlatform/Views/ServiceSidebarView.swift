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
                .padding(10)
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
                .clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
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
