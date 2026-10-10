import Foundation

struct AWSAccountInformation: Sendable {
    let accountID: String
    let name: String
}

/// Only display metadata is persisted; it never supplies credentials or selects a profile.
struct ProfileAccountName: Codable {
    let profileID: String
    let accountID: String
    let name: String
    let configPath: String
    let credentialsPath: String

    var isValid: Bool {
        accountID.range(of: "^[0-9]{12}$", options: .regularExpression) != nil
            && !profileID.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 128
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    func matches(profile: AWSProfile, accountID: String, paths: AWSConfigurationPaths) -> Bool {
        profileID == profile.id && self.accountID == accountID
            && configPath == paths.config && credentialsPath == paths.credentials && isValid
    }
}
