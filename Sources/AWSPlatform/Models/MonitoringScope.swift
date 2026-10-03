import Foundation
import SotoCore

struct MonitoringScope: Hashable, Sendable {
    let profile: AWSProfile
    let accountID: String
    let principalARN: String
    let region: String
    let configPath: String
    let credentialsPath: String

    var paths: AWSConfigurationPaths {
        AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": configPath, "AWS_SHARED_CREDENTIALS_FILE": credentialsPath
        ])
    }

    init(profile: AWSProfile, identity: AWSIdentity, region: String,
         paths: AWSConfigurationPaths = AWSConfigurationPaths()) {
        self.profile = profile
        accountID = identity.account
        principalARN = identity.arn
        self.region = region
        configPath = paths.config
        credentialsPath = paths.credentials
    }

    var isValid: Bool {
        let identity = principalARN.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.range(of: "^[0-9]{12}$", options: .regularExpression) != nil,
              accountID.count == 12,
              region.range(of: "^[a-z]{2,4}(?:-[a-z0-9]+)+-[0-9]+$", options: .regularExpression) != nil,
              !region.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              identity.count == 6, identity[0] == "arn", ["iam", "sts"].contains(String(identity[2])),
              identity[3].isEmpty, identity[4] == accountID, !identity[5].isEmpty,
              !principalARN.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return false }
        let partitions: [String: AWSPartition] = [
            "aws": .aws, "aws-cn": .awscn, "aws-us-gov": .awsusgov,
            "aws-iso": .awsiso, "aws-iso-b": .awsisob, "aws-iso-e": .awsisoe,
            "aws-iso-f": .awsisof, "aws-eusc": .awseusc
        ]
        return partitions[String(identity[1])] == Region(rawValue: region).partition
    }
}

enum MonitoringTimeRange: Int, CaseIterable, Identifiable, Sendable {
    case hour = 1, sixHours = 6, day = 24
    var id: Self { self }
    var title: String { "Last \(rawValue)h" }
    var duration: TimeInterval { Double(rawValue) * 3_600 }
}
