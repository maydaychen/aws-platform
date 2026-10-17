import Foundation

struct CodeCommitRepository: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct CodeCommitRepositoryDetail: Equatable, Sendable {
    let id: String
    let name: String
    let arn: String
    let accountID: String
    let description: String?
    let defaultBranch: String?
    let cloneURLHTTP: String?
    let cloneURLSSH: String?
    let creationDate: Date?
    let lastModifiedDate: Date?
}

struct CodeCommitCommit: Equatable, Sendable {
    let id: String
    let message: String?
    let authorName: String?
    let authorEmail: String?
    let authorDate: String?
    let committerName: String?
    let committerEmail: String?
    let committerDate: String?
    let parentIDs: [String]
}

enum CodeCommitError: LocalizedError, Equatable {
    case invalidScope, invalidInput, invalidResponse, incompletePagination

    var errorDescription: String? {
        switch self {
        case .invalidScope: return "Select and verify an AWS profile before loading CodeCommit."
        case .invalidInput: return "The CodeCommit repository or branch name is invalid. Refresh and select it again."
        case .invalidResponse: return "CodeCommit returned incomplete or mismatched data. Refresh to try again."
        case .incompletePagination: return "CodeCommit pagination could not be completed. Partial results were not displayed. Refresh to try again."
        }
    }
}
