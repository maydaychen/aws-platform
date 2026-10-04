import SwiftUI

struct ELBListenersView: View {
    @Environment(\.locale) private var locale
    let loadBalancer: ELBLoadBalancer
    @ObservedObject var vm: ELBViewModel
    let onOpen: (ELBResourceReference) -> Void

    private var isCurrentSelection: Bool { vm.scope != nil && vm.selectedLoadBalancer?.arn == loadBalancer.arn }
    private var ruleListener: ELBListener? {
        guard isCurrentSelection, let listener = vm.selectedListener, listener.loadBalancerARN == loadBalancer.arn,
              listener.supportsRules else { return nil }
        return listener
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Configured listeners, actions and routing rules. No traffic is sent or measured.", locale: locale))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if isCurrentSelection && vm.isListenersLoading {
                ProgressView(L10n.text("Loading listeners…", locale: locale)).controlSize(.small)
            } else if isCurrentSelection, let error = vm.listenersError {
                NoticeBanner(message: error)
                Button(L10n.text("Retry listeners", locale: locale), action: vm.refreshListeners)
            } else if isCurrentSelection && !vm.listeners.isEmpty {
                ForEach(vm.listeners) { listener in listenerRow(listener) }
            } else {
                Text(L10n.text("No listeners were returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
            }
            if let listener = ruleListener { rules(listener) }
        }
    }

    private func listenerRow(_ listener: ELBListener) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Text(listener.arn).font(.caption.monospaced()).foregroundColor(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !listener.fields.isEmpty { ELBFieldRows(fields: listener.fields) }
                    DetailSectionTitle(title: "Default actions")
                    if listener.actions.isEmpty {
                        Text(L10n.text("No default actions returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
                    } else {
                        ForEach(listener.actions.indices, id: \.self) { index in
                            ELBActionView(action: listener.actions[index], scope: vm.scope, onOpen: onOpen)
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(listenerTitle(listener)).font(.headline)
                    Text(listener.actions.isEmpty ? L10n.text("No default actions returned", locale: locale)
                         : listener.actions.map { L10n.text(ELBDisplay.action($0.type), locale: locale) }.joined(separator: " → "))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if listener.supportsRules {
                Button(L10n.text(ruleListener?.arn == listener.arn ? "Refresh rules" : "View rules", locale: locale)) {
                    if ruleListener?.arn == listener.arn { vm.refreshRules() }
                    else { vm.selectedListener = listener }
                }
                .disabled(vm.isRulesLoading && ruleListener?.arn == listener.arn)
                .help(L10n.format("Load ALB routing rules for %@", listenerTitle(listener), locale: locale))
            }
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func rules(_ listener: ELBListener) -> some View {
        DetailSectionTitle(title: L10n.format("Rules · %@", listenerTitle(listener), locale: locale))
        if vm.isRulesLoading {
            ProgressView(L10n.text("Loading listener rules…", locale: locale)).controlSize(.small)
        } else if let error = vm.rulesError {
            NoticeBanner(message: error)
            Button(L10n.text("Retry rules", locale: locale), action: vm.refreshRules)
        } else if vm.rules.isEmpty {
            Text(L10n.text("No listener rules were returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
        } else {
            ForEach(vm.rules) { rule in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(rule.arn).font(.caption.monospaced()).foregroundColor(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if !rule.conditions.isEmpty {
                            DetailSectionTitle(title: "Conditions")
                            ELBFieldRows(fields: rule.conditions)
                        } else {
                            Text(L10n.text(rule.isDefault ? "Applies when no other rule matches." : "No conditions returned.", locale: locale))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if !rule.transforms.isEmpty {
                            DetailSectionTitle(title: "Transforms")
                            ELBFieldRows(fields: rule.transforms)
                        }
                        DetailSectionTitle(title: "Actions")
                        if rule.actions.isEmpty {
                            Text(L10n.text("No actions returned.", locale: locale)).font(.caption).foregroundColor(.secondary)
                        } else {
                            ForEach(rule.actions.indices, id: \.self) { index in
                                ELBActionView(action: rule.actions[index], scope: vm.scope, onOpen: onOpen)
                            }
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(rule.isDefault ? L10n.text("Default rule", locale: locale)
                             : L10n.format("Priority %@", rule.priority, locale: locale)).font(.headline)
                        Text(rule.actions.map { L10n.text(ELBDisplay.action($0.type), locale: locale) }.joined(separator: " → "))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func listenerTitle(_ listener: ELBListener) -> String {
        "\(listener.protocolName == "Unknown" ? L10n.text("Unknown", locale: locale) : listener.protocolName) · \(listener.port.map(String.init) ?? L10n.text("Port not returned", locale: locale))"
    }
}
