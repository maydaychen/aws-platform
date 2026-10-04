import SwiftUI

struct ELBListenersView: View {
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
            Text("Configured listeners, actions and routing rules. No traffic is sent or measured.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if isCurrentSelection && vm.isListenersLoading {
                ProgressView("Loading listeners…").controlSize(.small)
            } else if isCurrentSelection, let error = vm.listenersError {
                NoticeBanner(message: error)
                Button("Retry listeners", action: vm.refreshListeners)
            } else if isCurrentSelection && !vm.listeners.isEmpty {
                ForEach(vm.listeners) { listener in listenerRow(listener) }
            } else {
                Text("No listeners were returned.").font(.callout).foregroundColor(.secondary)
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
                        Text("No default actions returned.").font(.callout).foregroundColor(.secondary)
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
                    Text(listener.actions.isEmpty ? "No default actions returned" : listener.actions.map { ELBDisplay.action($0.type) }.joined(separator: " → "))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if listener.supportsRules {
                Button(ruleListener?.arn == listener.arn ? "Refresh rules" : "View rules") {
                    if ruleListener?.arn == listener.arn { vm.refreshRules() }
                    else { vm.selectedListener = listener }
                }
                .disabled(vm.isRulesLoading && ruleListener?.arn == listener.arn)
                .help("Load ALB routing rules for \(listenerTitle(listener))")
            }
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func rules(_ listener: ELBListener) -> some View {
        DetailSectionTitle(title: "Rules · \(listenerTitle(listener))")
        if vm.isRulesLoading {
            ProgressView("Loading listener rules…").controlSize(.small)
        } else if let error = vm.rulesError {
            NoticeBanner(message: error)
            Button("Retry rules", action: vm.refreshRules)
        } else if vm.rules.isEmpty {
            Text("No listener rules were returned.").font(.callout).foregroundColor(.secondary)
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
                            Text(rule.isDefault ? "Applies when no other rule matches." : "No conditions returned.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        if !rule.transforms.isEmpty {
                            DetailSectionTitle(title: "Transforms")
                            ELBFieldRows(fields: rule.transforms)
                        }
                        DetailSectionTitle(title: "Actions")
                        if rule.actions.isEmpty {
                            Text("No actions returned.").font(.caption).foregroundColor(.secondary)
                        } else {
                            ForEach(rule.actions.indices, id: \.self) { index in
                                ELBActionView(action: rule.actions[index], scope: vm.scope, onOpen: onOpen)
                            }
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(rule.isDefault ? "Default rule" : "Priority \(rule.priority)").font(.headline)
                        Text(rule.actions.map { ELBDisplay.action($0.type) }.joined(separator: " → "))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func listenerTitle(_ listener: ELBListener) -> String {
        "\(listener.protocolName) · \(listener.port.map(String.init) ?? "Port not returned")"
    }
}
