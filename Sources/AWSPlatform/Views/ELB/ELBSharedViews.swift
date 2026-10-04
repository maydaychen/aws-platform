import AppKit
import SwiftUI

enum ELBDisplay {
    static func returned(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Not returned" }
        return value
    }

    static func kind(_ value: String) -> String {
        switch value {
        case "application": return "Application (ALB)"
        case "network": return "Network (NLB)"
        case "gateway": return "Gateway (GWLB)"
        default: return returned(value)
        }
    }

    static func action(_ value: String) -> String {
        switch value {
        case "forward": return "Forward"
        case "redirect": return "Redirect"
        case "fixed-response": return "Fixed response"
        case "authenticate-oidc": return "Authenticate with OIDC"
        case "authenticate-cognito": return "Authenticate with Cognito"
        default: return returned(value)
        }
    }

    static func resourceName(_ arn: String) -> String {
        let parts = arn.split(separator: "/")
        return parts.count >= 2 ? String(parts[parts.count - 2]) : arn
    }
}

struct ELBFieldRows: View {
    let fields: [ELBField]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(fields.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    Text(fields[index].name).font(.caption).foregroundColor(.secondary)
                    Text(ELBDisplay.returned(fields[index].value)).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                if index != fields.indices.last { Divider() }
            }
        }
        .padding(.horizontal, 12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ELBDetailHeader: View {
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
                        .help("Cancel detail requests").accessibilityLabel("Cancel detail requests")
                }
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .disabled(!isEnabled || isLoading)
                    .help("Refresh details").accessibilityLabel("Refresh details")
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
                .buttonStyle(.borderless).help("Copy ARN").accessibilityLabel("Copy ARN")
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
                Button("Open") { onOpen(reference) }
                    .help("Open \(name) in the current profile and region")
            }
        }
    }
}

struct ELBActionView: View {
    let action: ELBAction
    let scope: MonitoringScope?
    let onOpen: (ELBResourceReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ELBDisplay.action(action.type)).font(.headline)
                Spacer(minLength: 0)
                Text(action.order.map { "Order \(String($0))" } ?? "Order not returned")
                    .font(.caption).foregroundColor(.secondary)
            }
            if !action.fields.isEmpty { ELBFieldRows(fields: action.fields) }
            ForEach(action.forwards.indices, id: \.self) { index in
                let forward = action.forwards[index]
                VStack(alignment: .leading, spacing: 6) {
                    ELBLinkedResourceRow(arn: forward.targetGroupARN, name: ELBDisplay.resourceName(forward.targetGroupARN),
                                         service: .targetGroups, scope: scope, onOpen: onOpen)
                    if let weight = forward.weight {
                        Text("Configured weight: \(String(weight))").font(.caption).foregroundColor(.secondary)
                    }
                }
                if index != action.forwards.indices.last { Divider() }
            }
            if action.fields.isEmpty && action.forwards.isEmpty {
                Text("No additional action configuration returned.").font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ELBHealthLabel: View {
    let state: String

    var body: some View {
        Label(ELBDisplay.returned(state), systemImage: icon)
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
