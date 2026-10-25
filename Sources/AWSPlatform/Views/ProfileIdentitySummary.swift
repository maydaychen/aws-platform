import Foundation

/// Presentation derived from the identity already validated for the selected Profile.
struct ProfileIdentitySummary {
    let account: String
    let principal: String
    let principalLabel: String

    init(identity: AWSIdentity) {
        account = identity.account
        let fields = identity.arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        if fields.count == 6, fields[0] == "arn", fields[2] == "sts" {
            let resource = fields[5].split(separator: "/", omittingEmptySubsequences: false)
            if resource.count == 3, resource[0] == "assumed-role", !resource[1].isEmpty {
                principal = String(resource[1])
                principalLabel = "Role"
                return
            }
        } else if fields.count == 6, fields[0] == "arn", fields[2] == "iam",
                  fields[5].hasPrefix("role/"), fields[5].count > "role/".count {
            principal = String(fields[5].dropFirst("role/".count))
            principalLabel = "Role"
            return
        }
        principal = identity.arn
        principalLabel = "Identity"
    }
}
