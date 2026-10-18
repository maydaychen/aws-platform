import SwiftUI

struct AutoScalingGroupFieldsView: View {
    @Environment(\.locale) private var locale
    let group: ASGGroup
    let scope: MonitoringScope?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailSectionTitle(title: "Overview")
            DetailFieldRows(items: overview)
            Text(L10n.text("Capacity values use the group's capacity units and may differ from instance count.", locale: locale))
                .font(.caption).foregroundColor(.secondary)
            DetailSectionTitle(title: "Network and load balancing")
            DetailFieldRows(items: [("Availability Zones", lines(group.availabilityZones)), ("Subnets", lines(group.subnetIDs)),
                                    ("Load balancers", lines(group.loadBalancerNames)), ("Target groups", lines(group.targetGroupARNs))])
            DetailSectionTitle(title: "Launch configuration and templates")
            DetailFieldRows(items: [("Launch configuration", value(group.launchConfiguration))])
            if let template = group.launchTemplate { templateFields(template) }
            if let mixed = group.mixedInstances { mixedFields(mixed) }
            DetailSectionTitle(title: "Health checks and lifecycle")
            DetailFieldRows(items: lifecycle)
            if !group.suspendedProcesses.isEmpty {
                DetailSectionTitle(title: "Suspended processes")
                ForEach(group.suspendedProcesses.indices, id: \.self) { index in
                    let process = group.suspendedProcesses[index]
                    DetailFieldRows(items: [("Process", value(process.name)), ("Reason", value(process.reason))])
                }
            }
            DetailSectionTitle(title: "Group members")
            Text(L10n.text("Regular members only; warm pool instances are not included.", locale: locale))
                .font(.caption).foregroundColor(.secondary)
            if group.members.isEmpty { Text(L10n.text("No group members returned.", locale: locale)).foregroundColor(.secondary) }
            ForEach(group.members) { member in
                DetailFieldRows(items: [("Instance ID", member.instanceID), ("Instance type", value(member.instanceType)),
                    ("Availability Zone", value(member.availabilityZone)), ("Lifecycle state", value(member.lifecycleState)),
                    ("Health status", value(member.healthStatus)), ("Weighted capacity", value(member.weightedCapacity)),
                    ("Protected from scale in", boolean(member.protectedFromScaleIn)),
                    ("Launch configuration", value(member.launchConfiguration))])
                if let template = member.launchTemplate { templateFields(template) }
            }
            DetailSectionTitle(title: "Tags")
            if group.tags.isEmpty { Text(L10n.text("No tags returned.", locale: locale)).foregroundColor(.secondary) }
            ForEach(group.tags) { tag in
                VStack(alignment: .leading, spacing: 4) {
                    Text(tag.key).font(.caption).foregroundColor(.secondary)
                    Text(tag.value.map { $0.isEmpty ? L10n.text("(empty)", locale: locale) : $0 } ?? missing).font(.callout)
                    Text(L10n.format("Propagate at launch: %@", boolean(tag.propagateAtLaunch), locale: locale))
                        .font(.caption).foregroundColor(.secondary)
                }
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var overview: [(String, String)] {
        [("ARN", group.arn), ("Account ID", value(scope?.accountID)), ("Region", value(scope?.region)),
         ("Desired capacity", number(group.desiredCapacity)), ("Minimum capacity", number(group.minSize)),
         ("Maximum capacity", number(group.maxSize)), ("Capacity type", value(group.desiredCapacityType)),
         ("Regular member count", String(group.members.count)), ("Group operation status", value(group.status)),
         ("Created", group.createdAt.map { $0.formatted(.dateTime.year().month().day().hour().minute().locale(locale)) } ?? missing)]
    }

    private var lifecycle: [(String, String)] {
        [("Health check type", value(group.healthCheckType)), ("Health check grace period (s)", number(group.healthCheckGracePeriod)),
         ("Default cooldown (s)", number(group.defaultCooldown)), ("Default instance warmup (s)", number(group.defaultInstanceWarmup)),
         ("New instances protected from scale in", boolean(group.newInstancesProtectedFromScaleIn)),
         ("Capacity rebalance", boolean(group.capacityRebalance)), ("Termination policies", lines(group.terminationPolicies)),
         ("Service-linked role ARN", value(group.serviceLinkedRoleARN))]
    }

    private func templateFields(_ template: ASGLaunchTemplate) -> some View {
        DetailFieldRows(items: [("Launch template ID", value(template.templateID)), ("Launch template name", value(template.name)),
                                ("Launch template version", value(template.version))])
    }

    private func mixedFields(_ mixed: ASGMixedInstances) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailSectionTitle(title: "Mixed instances")
            if let template = mixed.launchTemplate { templateFields(template) }
            DetailFieldRows(items: [("On-Demand base capacity", number(mixed.onDemandBaseCapacity)),
                ("On-Demand above base (%)", number(mixed.onDemandPercentageAboveBaseCapacity)),
                ("On-Demand allocation strategy", value(mixed.onDemandAllocationStrategy)),
                ("Spot allocation strategy", value(mixed.spotAllocationStrategy))])
            ForEach(mixed.overrides.indices, id: \.self) { index in
                let item = mixed.overrides[index]
                DetailFieldRows(items: [("Instance type", value(item.instanceType)), ("Weighted capacity", value(item.weightedCapacity)),
                                        ("Attribute-based instance selection", boolean(item.usesInstanceRequirements))])
                if let template = item.launchTemplate { templateFields(template) }
            }
        }
    }

    private var missing: String { L10n.text("Not returned", locale: locale) }
    private func value(_ text: String?) -> String { text.flatMap { $0.isEmpty ? nil : $0 } ?? missing }
    private func number(_ value: Int?) -> String { value.map(String.init) ?? missing }
    private func lines(_ values: [String]) -> String { values.isEmpty ? missing : values.joined(separator: "\n") }
    private func boolean(_ value: Bool?) -> String {
        value.map { L10n.text($0 ? "Yes" : "No", locale: locale) } ?? L10n.text("Unknown", locale: locale)
    }
}
