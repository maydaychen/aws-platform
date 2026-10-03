import Foundation

struct AWSSOSession: Identifiable, Hashable {
    let name: String

    var id: String { name }
}
