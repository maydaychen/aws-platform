import Foundation
import SotoCodeCommit
import SotoCore
@testable import AWSPlatform

let browserRepository = CodeCommitRepository(id: codeCommitRepositoryID, name: "example")
let browserBeforeSHA = String(repeating: "b", count: 40)
let browserBlobID = String(repeating: "c", count: 40)

func browserRawFile(commit: String = codeCommitSHA, path: String = "/main.swift", blob: String = browserBlobID,
                    data: Data = Data("let value = 1\n".utf8), size: Int64? = nil) -> CodeCommit.GetFileOutput {
    .init(blobId: blob, commitId: commit, fileContent: .data(data), fileMode: .normal, filePath: path,
          fileSize: size ?? Int64(data.count))
}

actor CodeCommitBrowserFixture {
    var repository: CodeCommit.GetRepositoryOutput
    var folder: CodeCommit.GetFolderOutput
    var file: CodeCommit.GetFileOutput
    var differences: [CodeCommit.GetDifferencesOutput]
    var requests: [CodeCommit.ListPullRequestsOutput]
    var request: CodeCommit.GetPullRequestOutput
    var failPage: Int?
    var folderCalls: [CodeCommit.GetFolderInput] = []
    var fileCalls: [CodeCommit.GetFileInput] = []
    var diffCalls: [CodeCommit.GetDifferencesInput] = []
    var requestCalls: [CodeCommit.ListPullRequestsInput] = []
    var metadataCalls = 0

    init(repository: CodeCommit.GetRepositoryOutput = .init(repositoryMetadata: codeCommitMetadata()),
         folder: CodeCommit.GetFolderOutput = .init(commitId: codeCommitSHA,
            files: [.init(absolutePath: "/main.swift", blobId: browserBlobID, relativePath: "main.swift")], folderPath: "/"),
         file: CodeCommit.GetFileOutput = browserRawFile(), differences: [CodeCommit.GetDifferencesOutput] = [.init()],
         requests: [CodeCommit.ListPullRequestsOutput] = [.init(pullRequestIds: [])],
         request: CodeCommit.GetPullRequestOutput = .init(pullRequest: .init(pullRequestId: "1", pullRequestStatus: .open,
            pullRequestTargets: [.init(destinationCommit: browserBeforeSHA, destinationReference: "refs/heads/main",
                                      repositoryName: "example", sourceCommit: codeCommitSHA, sourceReference: "refs/heads/feature")], title: "Fixture")),
         failPage: Int? = nil) {
        self.repository = repository; self.folder = folder; self.file = file; self.differences = differences
        self.requests = requests; self.request = request; self.failPage = failPage
    }

    nonisolated var service: AWSCodeCommitBrowserService {
        .init(repositoryLoader: { _ in await self.metadata() }, folderLoader: { await self.getFolder($0) },
              fileLoader: { await self.getFile($0) }, differencesLoader: { try await self.diff($0) },
              pullRequestsLoader: { try await self.list($0) }, pullRequestLoader: { _ in await self.getRequest() })
    }
    func metadata() -> CodeCommit.GetRepositoryOutput { metadataCalls += 1; return repository }
    func getFolder(_ input: CodeCommit.GetFolderInput) -> CodeCommit.GetFolderOutput { folderCalls.append(input); return folder }
    func getFile(_ input: CodeCommit.GetFileInput) -> CodeCommit.GetFileOutput { fileCalls.append(input); return file }
    func getRequest() -> CodeCommit.GetPullRequestOutput { request }
    func diff(_ input: CodeCommit.GetDifferencesInput) throws -> CodeCommit.GetDifferencesOutput {
        let index = diffCalls.count; diffCalls.append(input)
        if failPage == index { throw CodeCommitFixtureError("AccessDeniedException") }
        return differences[min(index, differences.count - 1)]
    }
    func list(_ input: CodeCommit.ListPullRequestsInput) throws -> CodeCommit.ListPullRequestsOutput {
        let index = requestCalls.count; requestCalls.append(input)
        if failPage == index { throw CodeCommitFixtureError("AccessDeniedException") }
        return requests[min(index, requests.count - 1)]
    }
    func callCounts() -> (Int, Int, Int, Int, Int) { (metadataCalls, folderCalls.count, fileCalls.count, diffCalls.count, requestCalls.count) }
    func requestedFolders() -> [CodeCommit.GetFolderInput] { folderCalls }
    func requestedFiles() -> [CodeCommit.GetFileInput] { fileCalls }
    func requestedDifferences() -> [CodeCommit.GetDifferencesInput] { diffCalls }
    func requestedPullRequests() -> [CodeCommit.ListPullRequestsInput] { requestCalls }
}

func browserPreview(commit: String = codeCommitSHA, path: String = "/main.swift", blob: String = browserBlobID,
                    preview: CodeCommitPreview = .text("fixture")) -> CodeCommitFilePreview {
    .init(commitID: commit, path: path, blobID: blob, byteCount: 7, preview: preview)
}

func browserCommit(_ sha: String = codeCommitSHA) -> CodeCommitCommit {
    .init(id: sha, message: nil, authorName: nil, authorEmail: nil, authorDate: nil, committerName: nil,
          committerEmail: nil, committerDate: nil, parentIDs: [browserBeforeSHA])
}
