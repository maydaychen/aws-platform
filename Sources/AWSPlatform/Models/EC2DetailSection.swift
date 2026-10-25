import Foundation

enum EC2DetailSection: String, CaseIterable, Hashable {
    case storage, security
}

enum EC2DetailSectionState: Equatable {
    case notLoaded, loading, loaded
    case failed(String)
}

enum EC2DetailSectionResult {
    case storage([EC2VolumeModel])
    case security([EC2SecurityGroupModel])

    var section: EC2DetailSection {
        switch self {
        case .storage: return .storage
        case .security: return .security
        }
    }
}
