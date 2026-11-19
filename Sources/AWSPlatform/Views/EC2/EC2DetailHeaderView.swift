import AppKit
import SwiftUI

struct EC2DetailHeaderView: View {
    @Environment(\.locale) private var locale
    let instance: EC2InstanceModel
    let scope: MonitoringScope?
    let isCurrentSelection: Bool
    let isFavorite: Bool
    let canToggleFavorite: Bool
    let onToggleFavorite: (() -> Void)?
    let onShowRelationships: (() -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: WorkspaceLayout.detailActionSpacing) {
                identity.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: WorkspaceLayout.detailActionSpacing) {
                identity
                actions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.detailTitleSpacing) {
            Text(instance.name).font(.title2.weight(.semibold))
                .textSelection(.enabled).help(instance.name)
                .fixedSize(horizontal: false, vertical: true)
            Text(instance.instanceId).font(.caption.monospaced()).foregroundColor(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Label(instance.state, systemImage: "circle.fill")
                .font(.caption).foregroundColor(stateColor)
                .symbolRenderingMode(.monochrome)
        }
    }

    private var actions: some View {
        VStack(alignment: .trailing, spacing: WorkspaceLayout.detailActionSpacing) {
            EC2ConnectButton(instance: instance, scope: scope, isCurrentSelection: isCurrentSelection)
            HStack(spacing: WorkspaceLayout.detailActionSpacing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(instance.instanceId, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .help(L10n.text("Copy instance ID", locale: locale))
                .accessibilityLabel(L10n.text("Copy instance ID", locale: locale))
                .accessibilityIdentifier("ec2.copyID")
                if let onToggleFavorite {
                    Button(action: onToggleFavorite) { Image(systemName: isFavorite ? "star.fill" : "star") }
                        .disabled(!canToggleFavorite)
                        .help(L10n.text(isFavorite ? "Remove from Favorites" : "Add to Favorites", locale: locale))
                        .accessibilityLabel(L10n.text(isFavorite ? "Remove from Favorites" : "Add to Favorites", locale: locale))
                        .accessibilityIdentifier("ec2.favorite")
                }
                if let onShowRelationships {
                    Button(action: onShowRelationships) { Image(systemName: "point.3.connected.trianglepath.dotted") }
                        .disabled(!isCurrentSelection)
                        .help(L10n.text("View relationships", locale: locale))
                        .accessibilityLabel(L10n.text("View relationships", locale: locale))
                        .accessibilityIdentifier("ec2.relationships")
                }
            }
        }
        .fixedSize()
    }

    private var stateColor: Color {
        Self.statusColor(for: instance.state)
    }

    static func statusColor(for state: String) -> Color {
        switch state {
        case "running": return .green
        case "pending", "stopping": return .orange
        case "shutting-down", "terminated": return .red
        default: return .secondary
        }
    }
}
