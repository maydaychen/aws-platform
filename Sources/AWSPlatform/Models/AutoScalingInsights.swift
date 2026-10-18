import Foundation

struct ASGTemplateVersion: Identifiable, Hashable, Sendable {
    let reference: ASGLaunchTemplate
    let templateID: String
    let templateName: String?
    let version: Int64
    let isDefault: Bool?
    let description: String?
    let createdAt: Date?
    let createdBy: String?
    let imageID: String?
    let instanceType: String?
    let keyName: String?
    let securityGroupIDs: [String]?
    let instanceProfileARN: String?
    let instanceProfileName: String?
    let ebsOptimized: Bool?
    let detailedMonitoring: Bool?

    var id: String { "\(templateID):\(version)" }
}

struct ASGInstanceRefresh: Identifiable, Hashable, Sendable {
    let id: String
    let groupName: String
    let status: String?
    let percentageComplete: Int?
    let instancesRemaining: Int?
    let startedAt: Date?
    let endedAt: Date?
    let statusReason: String?
    let strategy: String?
}

enum AutoScalingInsightsError: LocalizedError, Equatable {
    case invalidScope, invalidResponse, invalidTemplate, incompletePagination
    case templatesPermission, refreshesPermission, credentials, network, throttled, failed

    var errorDescription: String? {
        switch self {
        case .invalidScope: return "Select a verified profile and current Auto Scaling group before loading details."
        case .invalidResponse: return "Auto Scaling details returned mismatched or incomplete data. Reload to try again."
        case .invalidTemplate: return "The group launch template reference has no valid ID or name and version. No broader template query was made."
        case .incompletePagination: return "Auto Scaling detail pagination could not be completed. Partial results were not displayed."
        case .templatesPermission: return "Launch template versions could not be read. Check ec2:DescribeLaunchTemplateVersions permission."
        case .refreshesPermission: return "Instance refreshes could not be read. Check autoscaling:DescribeInstanceRefreshes permission."
        case .credentials: return "AWS credentials expired or are unavailable. Verify the profile again before loading Auto Scaling details."
        case .network: return "Unable to reach AWS for Auto Scaling details. Check the network and reload."
        case .throttled: return "AWS is limiting Auto Scaling detail requests. Wait and reload manually."
        case .failed: return "Unable to load Auto Scaling details. Check the selected profile, region and permissions."
        }
    }
}

enum ASGInsightsContext {
    static func templates(in group: ASGGroup) -> [ASGLaunchTemplate] {
        let values = [group.launchTemplate, group.mixedInstances?.launchTemplate]
            + (group.mixedInstances?.overrides.map(\.launchTemplate) ?? [])
        var seen: Set<ASGLaunchTemplate> = []
        return values.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    static func validate(scope: MonitoringScope, group: ASGGroup) throws {
        guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty else {
            throw AutoScalingInsightsError.invalidScope
        }
        let parts = group.arn.split(separator: ":", maxSplits: 7, omittingEmptySubsequences: false)
        let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
        guard !group.name.isEmpty,
              parts.count == 8, parts[0] == "arn", parts[1] == partition, parts[2] == "autoscaling",
              parts[3] == scope.region, parts[4] == scope.accountID, parts[5] == "autoScalingGroup",
              !parts[6].isEmpty, !parts[6].contains("/"), !parts[6].contains(where: \.isWhitespace),
              parts[7] == "autoScalingGroupName/\(group.name)" else { throw AutoScalingInsightsError.invalidResponse }
    }

    static func memberReference(_ member: ASGMember, group: ASGGroup, scope: MonitoringScope?) -> ELBResourceReference? {
        guard let scope, (try? validate(scope: scope, group: group)) != nil, group.members.contains(member) else { return nil }
        return ELBResourceReference(scope: scope, service: .ec2, resourceID: member.instanceID, name: member.instanceID)
    }
}
