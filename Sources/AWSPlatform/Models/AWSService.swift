import Foundation

enum AWSService: String, CaseIterable, Identifiable, Codable {
    case ec2 = "EC2"
    case lambda = "Lambda"
    case s3 = "S3"
    case alarms = "CloudWatch"
    case sns = "SNS"
    case route53 = "Route 53"
    case loadBalancers = "Load Balancers"
    case targetGroups = "Target Groups"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ec2: return "server.rack"
        case .lambda: return "function"
        case .s3: return "externaldrive"
        case .alarms: return "bell.badge"
        case .sns: return "dot.radiowaves.left.and.right"
        case .route53: return "network"
        case .loadBalancers: return "point.3.connected.trianglepath.dotted"
        case .targetGroups: return "scope"
        }
    }
}
