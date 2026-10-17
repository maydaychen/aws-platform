import Foundation

struct EC2InstanceHealthResult: Sendable {
    static let notReturned = "Status checks were not returned for this instance."
    let health: [String: EC2InstanceHealth]
    let errors: [String: String]
}
