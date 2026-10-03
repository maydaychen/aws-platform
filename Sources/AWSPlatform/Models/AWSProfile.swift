import Foundation

struct AWSProfile: Identifiable, Hashable {
    let name: String
    let region: String
    let ssoStartURL: String?
    let ssoRegion: String?
    let ssoAccountID: String?
    let ssoRoleName: String?
    let ssoSessionName: String?

    init(
        name: String,
        region: String,
        ssoStartURL: String?,
        ssoRegion: String?,
        ssoAccountID: String?,
        ssoRoleName: String?,
        ssoSessionName: String? = nil
    ) {
        self.name = name
        self.region = region
        self.ssoStartURL = ssoStartURL
        self.ssoRegion = ssoRegion
        self.ssoAccountID = ssoAccountID
        self.ssoRoleName = ssoRoleName
        self.ssoSessionName = ssoSessionName
    }

    var id: String { name }

    var isSSO: Bool {
        ssoSessionName != nil || ssoStartURL != nil || ssoAccountID != nil || ssoRoleName != nil
    }

    var displayName: String {
        guard let ssoRoleName, !ssoRoleName.isEmpty else { return name }
        return "\(name) (\(ssoRoleName))"
    }
}
