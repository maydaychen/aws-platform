import Foundation

struct AWSProfile: Identifiable, Hashable {
    let name: String
    let region: String
    let ssoStartURL: String?
    let ssoRegion: String?
    let ssoAccountID: String?
    let ssoRoleName: String?

    var id: String { name }

    var isSSO: Bool {
        ssoStartURL != nil || ssoAccountID != nil || ssoRoleName != nil
    }

    var displayName: String {
        guard let ssoRoleName, !ssoRoleName.isEmpty else { return name }
        return "\(name) (\(ssoRoleName))"
    }
}
