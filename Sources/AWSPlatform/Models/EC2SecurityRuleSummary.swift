import Foundation

struct EC2SecurityRuleSummary {
    let inbound: [EC2SecurityRuleSummaryRow]
    let outbound: [EC2SecurityRuleSummaryRow]

    init(groups: [EC2SecurityGroupModel]) {
        inbound = Self.rows(groups: groups, inbound: true)
        outbound = Self.rows(groups: groups, inbound: false)
    }

    private static func rows(groups: [EC2SecurityGroupModel], inbound: Bool) -> [EC2SecurityRuleSummaryRow] {
        groups.enumerated().flatMap { groupIndex, group in
            let rules = inbound ? group.inboundRules : group.outboundRules
            return rules.enumerated().map { ruleIndex, rule in
                EC2SecurityRuleSummaryRow(
                    id: .init(groupId: group.groupId, groupIndex: groupIndex,
                              isInbound: inbound, ruleIndex: ruleIndex),
                    groupId: group.groupId,
                    groupName: group.name,
                    rule: rule
                )
            }
        }
    }
}

struct EC2SecurityRuleSummaryRow: Identifiable, Hashable {
    struct ID: Hashable {
        let groupId: String
        let groupIndex: Int
        let isInbound: Bool
        let ruleIndex: Int
    }

    let id: ID
    let groupId: String
    let groupName: String?
    let rule: EC2SecurityRuleModel
}
