import Foundation

struct AWSProfile: Identifiable, Hashable, Sendable {
    let name: String
    let region: String
    let ssoStartURL: String?
    let ssoRegion: String?
    let ssoAccountID: String?
    let ssoRoleName: String?
    let ssoSessionName: String?
    let roleARN: String?
    let sourceProfile: String?

    init(
        name: String,
        region: String,
        ssoStartURL: String?,
        ssoRegion: String?,
        ssoAccountID: String?,
        ssoRoleName: String?,
        ssoSessionName: String? = nil,
        roleARN: String? = nil,
        sourceProfile: String? = nil
    ) {
        self.name = name
        self.region = region
        self.ssoStartURL = ssoStartURL
        self.ssoRegion = ssoRegion
        self.ssoAccountID = ssoAccountID
        self.ssoRoleName = ssoRoleName
        self.ssoSessionName = ssoSessionName
        self.roleARN = roleARN
        self.sourceProfile = sourceProfile
    }

    var id: String { name }

    var isSSO: Bool {
        ssoSessionName != nil || ssoStartURL != nil || ssoAccountID != nil || ssoRoleName != nil
    }

    var roleAccountID: String? {
        guard let roleARN else { return nil }
        let parts = roleARN.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "arn", parts[2] == "iam", parts[3].isEmpty,
              parts[1].range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
              parts[4].range(of: "^[0-9]{12}$", options: .regularExpression) != nil,
              parts[5].hasPrefix("role/"),
              parts[5].unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              let roleName = parts[5].split(separator: "/", omittingEmptySubsequences: false).last,
              roleName.range(of: "^[A-Za-z0-9_+=,.@-]{1,64}$", options: .regularExpression) != nil else {
            return nil
        }
        return String(parts[4])
    }

    var assumedRolePrincipalARN: String? {
        guard let roleARN, let account = roleAccountID else { return nil }
        let parts = roleARN.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard let roleName = parts[5].split(separator: "/").last else { return nil }
        // STS omits the IAM role's path and adds a separate session suffix.
        return "arn:\(parts[1]):sts::\(account):assumed-role/\(roleName)"
    }

    var displayName: String {
        guard let ssoRoleName, !ssoRoleName.isEmpty else { return name }
        return "\(name) (\(ssoRoleName))"
    }
}
