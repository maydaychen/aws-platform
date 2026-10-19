import Foundation

enum EC2DetailSection: String, CaseIterable, Hashable {
    case storage, security, status
}

enum EC2DetailSectionState: Equatable {
    case notLoaded, loading, loaded
    case failed(String)
}

enum EC2DetailSectionResult {
    case storage([EC2VolumeModel])
    case security([EC2SecurityGroupModel])
    case status(EC2InstanceHealth?)

    var section: EC2DetailSection {
        switch self {
        case .storage: return .storage
        case .security: return .security
        case .status: return .status
        }
    }
}
