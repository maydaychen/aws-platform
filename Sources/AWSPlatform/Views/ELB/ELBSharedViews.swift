import AppKit
import SwiftUI

enum ELBDisplay {
    static func returned(_ value: String?, locale: Locale) -> String {
        guard let value, !value.isEmpty else { return L10n.text("Not returned", locale: locale) }
        return value
    }

    static func kind(_ value: String) -> String {
        switch value {
        case "application": return "Application (ALB)"
        case "network": return "Network (NLB)"
        case "gateway": return "Gateway (GWLB)"
        default: return value.isEmpty ? "Not returned" : value
        }
    }

    static func action(_ value: String) -> String {
        switch value {
        case "forward": return "Forward"
        case "redirect": return "Redirect"
        case "fixed-response": return "Fixed response"
        case "authenticate-oidc": return "Authenticate with OIDC"
        case "authenticate-cognito": return "Authenticate with Cognito"
        default: return value.isEmpty ? "Not returned" : value
        }
    }

    static func resourceName(_ arn: String) -> String {
        let parts = arn.split(separator: "/")
        return parts.count >= 2 ? String(parts[parts.count - 2]) : arn
    }
}

struct ELBFieldRows: View {
    @Environment(\.locale) private var locale
    let fields: [ELBField]
    var isVerbatimLabels = false
    var isMessageValues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(fields.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: isVerbatimLabels ? fields[index].name : L10n.text(fields[index].name, locale: locale))
                        .font(.caption).foregroundColor(.secondary)
                    Text(verbatim: displayedValue(fields[index])).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                if index != fields.indices.last { Divider() }
            }
        }
        .padding(.horizontal, 12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func displayedValue(_ field: ELBField) -> String {
        if isMessageValues { return L10n.text(field.value, locale: locale) }
        if !isVerbatimLabels {
            switch field.name {
            case "Stickiness enabled", "Ignore client certificate expiry", "Health checks enabled":
                return L10n.text(field.value, locale: locale)
            case "Owner", "Protocol", "Ports / ICMP type and code":
                return L10n.text(field.value, locale: locale)
            case "State" where field.value == "Unknown":
                return L10n.text("Unknown", locale: locale)
            case "Routing policy":
                return Route53Display.routingPolicy(field.value, locale: locale)
            default:
                if field.name.hasPrefix("Certificate ") && field.name.hasSuffix(" default") {
                    return L10n.text(field.value, locale: locale)
                }
            }
        }
        return ELBDisplay.returned(field.value, locale: locale)
    }
}

struct ELBDetailHeader: View {
    @Environment(\.locale) private var locale
    let name: String
    let subtitle: String
    let arn: String
    let isLoading: Bool
    let isEnabled: Bool
    let onRefresh: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isLoading {
                    Button(action: onCancel) { Image(systemName: "xmark.circle") }
                        .help(L10n.text("Cancel detail requests", locale: locale)).accessibilityLabel(L10n.text("Cancel detail requests", locale: locale))
                }
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .disabled(!isEnabled || isLoading)
                    .help(L10n.text("Refresh details", locale: locale)).accessibilityLabel(L10n.text("Refresh details", locale: locale))
            }
            Text(subtitle).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 6) {
                Text(arn).font(.caption.monospaced()).foregroundColor(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(arn, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help(L10n.text("Copy ARN", locale: locale)).accessibilityLabel(L10n.text("Copy ARN", locale: locale))
            }
        }
        .padding(16)
    }
}

struct ELBScopeCaption: View {
    let scope: MonitoringScope?

    var body: some View {
        if let scope {
            Text("\(scope.accountID) · \(scope.region)")
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ELBLinkedResourceRow: View {
    @Environment(\.locale) private var locale
    let arn: String
    let name: String
    let service: AWSService
    let scope: MonitoringScope?
    let onOpen: (ELBResourceReference) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.callout.weight(.medium)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(arn).font(.caption.monospaced()).foregroundColor(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let scope, let reference = ELBResourceReference(scope: scope, service: service, resourceID: arn, name: name) {
                Button(L10n.text("Open", locale: locale)) { onOpen(reference) }
                    .help(L10n.format("Open %@ in the current profile and region", name, locale: locale))
            }
        }
    }
}

struct ELBActionView: View {
    @Environment(\.locale) private var locale
    let action: ELBAction
    let scope: MonitoringScope?
    let onOpen: (ELBResourceReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L10n.text(ELBDisplay.action(action.type), locale: locale)).font(.headline)
                Spacer(minLength: 0)
                Text(action.order.map { L10n.format("Order %@", String($0), locale: locale) }
                     ?? L10n.text("Order not returned", locale: locale))
                    .font(.caption).foregroundColor(.secondary)
            }
            if !action.fields.isEmpty { ELBFieldRows(fields: action.fields) }
            ForEach(action.forwards.indices, id: \.self) { index in
                let forward = action.forwards[index]
                VStack(alignment: .leading, spacing: 6) {
                    ELBLinkedResourceRow(arn: forward.targetGroupARN, name: ELBDisplay.resourceName(forward.targetGroupARN),
                                         service: .targetGroups, scope: scope, onOpen: onOpen)
                    if let weight = forward.weight {
                        Text(L10n.format("Configured weight: %@", String(weight), locale: locale)).font(.caption).foregroundColor(.secondary)
                    }
                }
                if index != action.forwards.indices.last { Divider() }
            }
            if action.fields.isEmpty && action.forwards.isEmpty {
                Text(L10n.text("No additional action configuration returned.", locale: locale)).font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ELBHealthLabel: View {
    @Environment(\.locale) private var locale
    let state: String

    var body: some View {
        Label(state == "Unknown" ? L10n.text("Unknown", locale: locale) : ELBDisplay.returned(state, locale: locale), systemImage: icon)
            .font(.caption).foregroundColor(color).lineLimit(1).help(state)
    }

    private var color: Color {
        switch state {
        case "healthy": return .green
        case "unhealthy": return .red
        case "initial", "draining": return .orange
        default: return .secondary
        }
    }

    private var icon: String {
        switch state {
        case "healthy": return "checkmark.circle"
        case "unhealthy": return "exclamationmark.triangle"
        case "initial", "draining": return "clock"
        default: return "minus.circle"
        }
    }
}
