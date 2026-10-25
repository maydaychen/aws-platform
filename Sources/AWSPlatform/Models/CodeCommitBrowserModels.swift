import Foundation

enum CodeCommitPath {
    static func matches(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    static func identity(_ path: String) -> Data { Data(path.utf8) }
    static func precedes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.lexicographicallyPrecedes(rhs.utf8) }
}

enum CodeCommitEntryKind: String, Hashable, Sendable { case folder, file, symbolicLink, submodule }

struct CodeCommitTreeEntry: Identifiable, Equatable, Sendable {
    let path: String
    let kind: CodeCommitEntryKind
    let objectID: String
    var id: Data { CodeCommitPath.identity(path) }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.objectID == rhs.objectID
    }
}

struct CodeCommitFolder: Equatable, Sendable {
    let commitID: String
    let path: String
    let entries: [CodeCommitTreeEntry]
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.commitID == rhs.commitID && CodeCommitPath.matches(lhs.path, rhs.path) && lhs.entries == rhs.entries
    }
}

enum CodeCommitPreview: Equatable, Sendable {
    case text(String)
    case binary
    case tooLarge

    static let maximumBytes = 512 * 1_024
    static let maximumLines = 5_000

    static func make(data: Data) -> Self {
        guard data.count <= maximumBytes else { return .tooLarge }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
        guard text.reduce(1, { $1.isNewline ? $0 + 1 : $0 }) <= maximumLines else { return .tooLarge }
        return .text(text)
    }
}

struct CodeCommitFilePreview: Equatable, Sendable {
    let commitID: String
    let path: String
    let blobID: String
    let byteCount: Int64
    let preview: CodeCommitPreview
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.commitID == rhs.commitID && CodeCommitPath.matches(lhs.path, rhs.path) && lhs.blobID == rhs.blobID &&
            lhs.byteCount == rhs.byteCount && lhs.preview == rhs.preview
    }
}

struct CodeCommitChangeBlob: Equatable, Sendable {
    let id: String
    let path: String
    let mode: String?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && CodeCommitPath.matches(lhs.path, rhs.path) && lhs.mode == rhs.mode
    }
}

struct CodeCommitFileChange: Identifiable, Equatable, Sendable {
    let type: String
    let before: CodeCommitChangeBlob?
    let after: CodeCommitChangeBlob?
    var id: Data { CodeCommitPath.identity("\(before?.path ?? "")\u{0}\(after?.path ?? "")") }
    var path: String { after?.path ?? before?.path ?? "" }
}

struct CodeCommitPullRequest: Identifiable, Equatable, Sendable {
    let id: String
    let title: String?
    let description: String?
    let status: String?
    let authorARN: String?
    let createdAt: Date?
    let updatedAt: Date?
    let sourceReference: String?
    let destinationReference: String?
    let sourceCommit: String?
    let destinationCommit: String?
}

enum CodeCommitBrowserError: LocalizedError, Equatable {
    case invalidInput, invalidResponse, incompletePagination, permission, credentials, failed
    var errorDescription: String? {
        switch self {
        case .invalidInput: return "Select a repository and enter a full 40-character commit SHA and a valid repository path."
        case .invalidResponse: return "CodeCommit returned mismatched repository content. Reload the repository before trying again."
        case .incompletePagination: return "CodeCommit content pagination could not be completed. Partial results were not displayed."
        case .permission: return "CodeCommit content access was denied. Check the read permissions for this repository."
        case .credentials: return "AWS credentials expired or are unavailable. Sign in and select the profile again."
        case .failed: return "The CodeCommit content request failed. Check the selected profile and region, then retry manually."
        }
    }
}
