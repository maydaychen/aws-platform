import Foundation

enum AWSService: String, CaseIterable, Identifiable, Codable {
    case ec2 = "EC2"
    case lambda = "Lambda"
    case s3 = "S3"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ec2: return "server.rack"
        case .lambda: return "function"
        case .s3: return "externaldrive"
        }
    }
}
