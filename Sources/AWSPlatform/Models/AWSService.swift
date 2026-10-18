import Foundation

enum AWSService: String, CaseIterable, Identifiable, Codable {
    case ec2 = "EC2"
    case lambda = "Lambda"
    case s3 = "S3"
    case alarms = "CloudWatch"
    case sns = "SNS"
    case codeCommit = "CodeCommit"
    case rds = "RDS"
    case autoScaling = "Auto Scaling"
    case route53 = "Route 53"
    case loadBalancers = "Load Balancers"
    case targetGroups = "Target Groups"
    case securityGroups = "Security Groups"
    case ebsVolumes = "EBS Volumes"
    case ebsSnapshots = "EBS Snapshots"

    var id: String { rawValue }

    static let ec2Services: [AWSService] = [.ec2, .autoScaling, .ebsVolumes, .ebsSnapshots, .loadBalancers, .targetGroups, .securityGroups]
    static var standaloneServices: [AWSService] { allCases.filter { !$0.isEC2Service } }
    var isEC2Service: Bool { Self.ec2Services.contains(self) }
    var sidebarTitle: String {
        switch self {
        case .ec2: return "Instances"
        case .ebsSnapshots: return "Snapshots"
        case .loadBalancers: return "Load balancers"
        case .targetGroups: return "Target groups"
        case .securityGroups: return "Security groups"
        default: return rawValue
        }
    }

    var icon: String {
        switch self {
        case .ec2: return "server.rack"
        case .lambda: return "function"
        case .s3: return "externaldrive"
        case .alarms: return "bell.badge"
        case .sns: return "dot.radiowaves.left.and.right"
        case .codeCommit: return "chevron.left.forwardslash.chevron.right"
        case .rds: return "cylinder"
        case .autoScaling: return "arrow.up.arrow.down"
        case .route53: return "network"
        case .loadBalancers: return "point.3.connected.trianglepath.dotted"
        case .targetGroups: return "scope"
        case .securityGroups: return "shield.lefthalf.filled"
        case .ebsVolumes: return "externaldrive"
        case .ebsSnapshots: return "camera.on.rectangle"
        }
    }
}
