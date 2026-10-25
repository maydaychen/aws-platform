import Foundation
import SotoCodeCommit
import XCTest
@testable import AWSPlatform

final class AWSCodeCommitBrowserServiceTests: XCTestCase {
    func testFolderRequestUsesFixedCommitAndMapsAllEntryKindsWithoutFollowingLinks() async throws {
        let fixture = CodeCommitBrowserFixture(folder: .init(commitId: codeCommitSHA,
            files: [.init(absolutePath: "/main.swift", blobId: browserBlobID, relativePath: "main.swift")], folderPath: "/",
            subFolders: [.init(absolutePath: "/Sources", relativePath: "Sources", treeId: browserBlobID)],
            subModules: [.init(absolutePath: "/module", commitId: browserBeforeSHA, relativePath: "module")],
            symbolicLinks: [.init(absolutePath: "/link", blobId: browserBlobID, relativePath: "link")]))
        let folder = try await fixture.service.loadFolder(scope: codeCommitScope(), repository: browserRepository, commit: codeCommitSHA, path: "/")
        XCTAssertEqual(folder.entries.count, 4)
        XCTAssertEqual(folder.entries.first?.kind, .folder)
        XCTAssertEqual(Set(folder.entries.map(\.kind)), [.folder, .file, .symbolicLink, .submodule])
        let calls = await fixture.requestedFolders()
        XCTAssertEqual(calls.first?.commitSpecifier, codeCommitSHA)
        XCTAssertEqual(calls.first?.folderPath, "/")
        XCTAssertEqual(calls.first?.repositoryName, "example")
        let counts = await fixture.callCounts()
        XCTAssertEqual(counts.2, 0)
    }

    func testFolderRejectsCommitPathOrChildRelationshipMismatchAndDuplicatePaths() async {
        let rows: [CodeCommit.GetFolderOutput] = [
            .init(commitId: browserBeforeSHA, folderPath: "/"), .init(commitId: codeCommitSHA, folderPath: "/other"),
            .init(commitId: codeCommitSHA, files: [.init(absolutePath: "/a/deeper", blobId: browserBlobID)], folderPath: "/"),
            .init(commitId: codeCommitSHA, files: [.init(absolutePath: "/file", blobId: "invalid")], folderPath: "/"),
            .init(commitId: codeCommitSHA, files: [.init(absolutePath: "/file", blobId: browserBlobID, relativePath: "wrong")], folderPath: "/"),
            .init(commitId: codeCommitSHA, files: [.init(absolutePath: "/file", blobId: browserBlobID), .init(absolutePath: "/file", blobId: browserBlobID)], folderPath: "/")
        ]
        for row in rows {
            let fixture = CodeCommitBrowserFixture(folder: row)
            await assertBrowserError(.invalidResponse) {
                _ = try await fixture.service.loadFolder(scope: codeCommitScope(), repository: browserRepository, commit: codeCommitSHA, path: "/")
            }
        }
    }

    func testInvalidSHAAndPathsAreRejectedBeforeMetadataOrContentRequests() async {
        for (sha, path) in [("HEAD", "/"), ("main", "/"), (String(repeating: "A", count: 40), "/"),
                            (codeCommitSHA, "relative"), (codeCommitSHA, "/../secrets"), (codeCommitSHA, "/a//b"),
                            (codeCommitSHA, "/a/./b"), (codeCommitSHA, "/a\0"), (codeCommitSHA, "/a/"),
                            (codeCommitSHA, "/a\\"), (codeCommitSHA, ""), (codeCommitSHA, "/" + String(repeating: "a", count: 4_096))] {
            let fixture = CodeCommitBrowserFixture()
            await assertBrowserError(.invalidInput) {
                _ = try await fixture.service.loadFolder(scope: codeCommitScope(), repository: browserRepository, commit: sha, path: path)
            }
            let counts = await fixture.callCounts(); XCTAssertEqual(counts.0, 0)
        }
    }

    func testLegalRemoteNamesKeepInternalBackslashAndControlBytesUnchanged() async throws {
        for name in ["a\\b.txt", "line\nname", "tab\tname", "control\u{1}name", "\u{301}name"] {
            let path = "/folder/" + name
            let fixture = CodeCommitBrowserFixture(folder: .init(commitId: codeCommitSHA,
                files: [.init(absolutePath: path, blobId: browserBlobID, relativePath: name)], folderPath: "/folder"),
                file: browserRawFile(path: path))
            let folder = try await fixture.service.loadFolder(scope: codeCommitScope(), repository: browserRepository,
                commit: codeCommitSHA, path: "/folder")
            XCTAssertEqual(folder.entries.first?.id, Data(path.utf8))
            let file = try await fixture.service.loadFile(scope: codeCommitScope(), repository: browserRepository,
                commit: codeCommitSHA, path: path)
            XCTAssertEqual(Data(file.path.utf8), Data(path.utf8))
            let calls = await fixture.requestedFiles()
            XCTAssertEqual(calls.first.map { Data($0.filePath.utf8) }, Data(path.utf8))
        }
    }

    func testUnicodeEquivalentGitNamesRemainDistinctFolderAndDifferenceEntries() async throws {
        let paths = ["/caf\u{e9}.txt", "/cafe\u{301}.txt"]
        XCTAssertEqual(paths[0], paths[1])
        let fixture = CodeCommitBrowserFixture(folder: .init(commitId: codeCommitSHA,
            files: paths.map { .init(absolutePath: $0, blobId: browserBlobID) }, folderPath: "/"),
            differences: [.init(differences: paths.map { .init(afterBlob: .init(blobId: browserBlobID, path: $0), changeType: .added) })])
        let folder = try await fixture.service.loadFolder(scope: codeCommitScope(), repository: browserRepository,
            commit: codeCommitSHA, path: "/")
        XCTAssertEqual(Set(folder.entries.map(\.id)).count, 2)
        XCTAssertNotEqual(folder.entries[0], folder.entries[1])
        let changes = try await fixture.service.loadDifferences(scope: codeCommitScope(), repository: browserRepository,
            before: nil, after: codeCommitSHA)
        XCTAssertEqual(Set(changes.map(\.id)).count, 2)
        XCTAssertNotEqual(changes[0], changes[1])
    }

    func testUnicodeEquivalentWrongFolderFileParentAndRelativePathsAreRejected() async {
        let requested = "/caf\u{e9}", other = "/cafe\u{301}"
        let folders: [(String, CodeCommit.GetFolderOutput)] = [
            (requested, .init(commitId: codeCommitSHA, folderPath: other)),
            (requested, .init(commitId: codeCommitSHA,
                files: [.init(absolutePath: other + "/file", blobId: browserBlobID)], folderPath: requested)),
            ("/", .init(commitId: codeCommitSHA,
                files: [.init(absolutePath: requested, blobId: browserBlobID, relativePath: String(other.dropFirst()))], folderPath: "/"))
        ]
        for (path, raw) in folders {
            let fixture = CodeCommitBrowserFixture(folder: raw)
            await assertBrowserError(.invalidResponse) {
                _ = try await fixture.service.loadFolder(scope: codeCommitScope(), repository: browserRepository,
                    commit: codeCommitSHA, path: path)
            }
        }
        let fixture = CodeCommitBrowserFixture(file: browserRawFile(path: other))
        await assertBrowserError(.invalidResponse) {
            _ = try await fixture.service.loadFile(scope: codeCommitScope(), repository: browserRepository,
                commit: codeCommitSHA, path: requested)
        }
    }

    func testOpaquePaginationTokensUseByteIdentity() async throws {
        let tokens = ["caf\u{e9}", "cafe\u{301}"]
        let fixture = CodeCommitBrowserFixture(differences: [.init(nextToken: tokens[0]), .init(nextToken: tokens[1]), .init()])
        let changes = try await fixture.service.loadDifferences(scope: codeCommitScope(), repository: browserRepository,
            before: nil, after: codeCommitSHA)
        XCTAssertTrue(changes.isEmpty)
        let calls = await fixture.requestedDifferences()
        XCTAssertEqual(calls.map { $0.nextToken.map { Data($0.utf8) } }, [nil] + tokens.map { Optional(Data($0.utf8)) })
    }

    func testRepositoryUUIDNameAccountRegionAndPartitionAreBoundBeforeContentReads() async {
        let values: [CodeCommit.RepositoryMetadata?] = [nil, .init(accountId: "111122223333", arn: "arn:aws:codecommit:eu-west-1:111122223333:example", repositoryId: "99999999-1111-2222-3333-444444444444", repositoryName: "example"),
            codeCommitMetadata(name: "other"), codeCommitMetadata(account: "999999999999"),
            codeCommitMetadata(region: "us-east-1"), codeCommitMetadata(partition: "aws-cn")]
        for value in values {
            let fixture = CodeCommitBrowserFixture(repository: .init(repositoryMetadata: value))
            await assertBrowserError(.invalidResponse) {
                _ = try await fixture.service.loadFolder(scope: codeCommitScope(), repository: browserRepository, commit: codeCommitSHA, path: "/")
            }
            let counts = await fixture.callCounts(); XCTAssertEqual(counts.1, 0)
        }
    }

    func testFileUsesFixedCommitAndExpectedBlobAndPreservesLiteralUTF8() async throws {
        let fixture = CodeCommitBrowserFixture(file: browserRawFile(data: Data("[link](javascript:alert(1))\n你好".utf8)))
        let file = try await fixture.service.loadFile(scope: codeCommitScope(), repository: browserRepository,
            commit: codeCommitSHA, path: "/main.swift", expectedBlob: browserBlobID)
        XCTAssertEqual(file.preview, .text("[link](javascript:alert(1))\n你好"))
        let calls = await fixture.requestedFiles()
        XCTAssertEqual(calls.first?.commitSpecifier, codeCommitSHA)
        XCTAssertEqual(calls.first?.repositoryName, "example")
    }

    func testFileRejectsCommitPathBlobAndDeclaredSizeMismatch() async {
        for raw in [browserRawFile(commit: browserBeforeSHA), browserRawFile(path: "/other"),
                    browserRawFile(blob: browserBeforeSHA), browserRawFile(size: -1), browserRawFile(size: 1)] {
            let fixture = CodeCommitBrowserFixture(file: raw)
            await assertBrowserError(.invalidResponse) {
                _ = try await fixture.service.loadFile(scope: codeCommitScope(), repository: browserRepository,
                    commit: codeCommitSHA, path: "/main.swift", expectedBlob: browserBlobID)
            }
        }
    }

    func testBinaryOversizedAndLineLimitedFilesDoNotCreateTextPreviews() async throws {
        for (data, expected) in [(Data([0, 1, 2]), CodeCommitPreview.binary), (Data([0xff, 0xfe]), .binary),
            (Data(repeating: 65, count: CodeCommitPreview.maximumBytes + 1), .tooLarge),
            (Data(String(repeating: "x\n", count: 5_000).utf8), .tooLarge)] {
            let fixture = CodeCommitBrowserFixture(file: browserRawFile(data: data))
            let file = try await fixture.service.loadFile(scope: codeCommitScope(), repository: browserRepository,
                commit: codeCommitSHA, path: "/main.swift")
            XCTAssertEqual(file.preview, expected)
        }
        XCTAssertEqual(CodeCommitPreview.make(data: Data()), .text(""))
        XCTAssertEqual(CodeCommitPreview.make(data: Data(repeating: 65, count: 512 * 1_024)), .text(String(repeating: "A", count: 512 * 1_024)))
        XCTAssertEqual(CodeCommitPreview.make(data: Data(String(repeating: "\r", count: 5_000).utf8)), .tooLarge)
        XCTAssertEqual(CodeCommitPreview.make(data: Data(String(repeating: "\u{2028}", count: 5_000).utf8)), .tooLarge)
        XCTAssertEqual(CodeCommitPreview.make(data: Data(String(repeating: "\r\n", count: 4_999).utf8)), .text(String(repeating: "\r\n", count: 4_999)))
    }

    func testDifferencesFollowAllPagesUsingFixedBeforeAfterAndNormalizePaths() async throws {
        let fixture = CodeCommitBrowserFixture(differences: [
            .init(differences: [.init(afterBlob: .init(blobId: browserBlobID, mode: "100644", path: "new.txt"), changeType: .added)], nextToken: "empty"),
            .init(differences: [], nextToken: "last"),
            .init(differences: [.init(beforeBlob: .init(blobId: browserBeforeSHA, path: "/old.txt"), changeType: .deleted)])])
        let values = try await fixture.service.loadDifferences(scope: codeCommitScope(), repository: browserRepository, before: browserBeforeSHA, after: codeCommitSHA)
        XCTAssertEqual(values.map(\.path), ["/new.txt", "/old.txt"])
        let calls = await fixture.requestedDifferences()
        XCTAssertEqual(calls.map(\.nextToken), [nil, "empty", "last"])
        XCTAssertTrue(calls.allSatisfy { $0.beforeCommitSpecifier == browserBeforeSHA && $0.afterCommitSpecifier == codeCommitSHA && $0.maxResults == 100 && $0.repositoryName == "example" })
    }

    func testDifferenceCycleBlankTokenAndPageBudgetFailWithoutPartialSuccess() async {
        for pages in [[CodeCommit.GetDifferencesOutput(nextToken: "again"), .init(nextToken: "again")],
                      [.init(nextToken: "\n")], (0..<1_000).map { .init(nextToken: "page-\($0)") }] {
            let fixture = CodeCommitBrowserFixture(differences: pages)
            await assertBrowserError(.incompletePagination) {
                _ = try await fixture.service.loadDifferences(scope: codeCommitScope(), repository: browserRepository, before: nil, after: codeCommitSHA)
            }
        }
    }

    func testDifferenceLaterPageFailureIsSanitizedAndDuplicateOrMalformedRowsFail() async {
        let changed = CodeCommit.Difference(afterBlob: .init(blobId: browserBlobID, path: "file"), changeType: .added)
        let fixture = CodeCommitBrowserFixture(differences: [.init(differences: [changed], nextToken: "next")], failPage: 1)
        await assertBrowserError(.permission) {
            _ = try await fixture.service.loadDifferences(scope: codeCommitScope(), repository: browserRepository, before: nil, after: codeCommitSHA)
        }
        for rows in [[changed, changed], [.init(afterBlob: .init(blobId: browserBlobID, path: "../file"), changeType: .added)],
                     [.init(afterBlob: .init(blobId: browserBlobID, path: "file"), changeType: .deleted)], [.init()]] {
            let fixture = CodeCommitBrowserFixture(differences: [.init(differences: rows)])
            await assertBrowserError(.invalidResponse) {
                _ = try await fixture.service.loadDifferences(scope: codeCommitScope(), repository: browserRepository, before: nil, after: codeCommitSHA)
            }
        }
    }

    func testPullRequestIDsFollowPaginationWithoutEagerDetailCallsAndKeepStatusFilter() async throws {
        let fixture = CodeCommitBrowserFixture(requests: [.init(nextToken: "next", pullRequestIds: ["1", "2"]), .init(pullRequestIds: ["3"])])
        let values = try await fixture.service.loadPullRequests(scope: codeCommitScope(), repository: browserRepository, status: "CLOSED")
        XCTAssertEqual(values, ["1", "2", "3"])
        let calls = await fixture.requestedPullRequests()
        XCTAssertEqual(calls.map(\.nextToken), [nil, "next"])
        XCTAssertTrue(calls.allSatisfy { $0.pullRequestStatus == .closed && $0.maxResults == 100 && $0.repositoryName == "example" })
    }

    func testPullRequestPaginationRejectsCycleMalformedIDsDuplicatesAndLaterFailure() async {
        for (pages, expected) in [([CodeCommit.ListPullRequestsOutput(nextToken: "repeat", pullRequestIds: []), .init(nextToken: "repeat", pullRequestIds: [])], CodeCommitBrowserError.incompletePagination),
            ([.init(pullRequestIds: ["bad"])], .invalidResponse), ([.init(pullRequestIds: ["1", "1"])], .invalidResponse)] {
            let fixture = CodeCommitBrowserFixture(requests: pages)
            await assertBrowserError(expected) { _ = try await fixture.service.loadPullRequests(scope: codeCommitScope(), repository: browserRepository, status: nil) }
        }
        let fixture = CodeCommitBrowserFixture(requests: [.init(nextToken: "next", pullRequestIds: ["1"])], failPage: 1)
        await assertBrowserError(.permission) { _ = try await fixture.service.loadPullRequests(scope: codeCommitScope(), repository: browserRepository, status: nil) }
    }

    func testPullRequestDetailBindsIDRepositoryAndOptionalCommitSHAs() async throws {
        let fixture = CodeCommitBrowserFixture()
        let value = try await fixture.service.loadPullRequest(scope: codeCommitScope(), repository: browserRepository, id: "1")
        XCTAssertEqual(value.title, "Fixture"); XCTAssertEqual(value.sourceCommit, codeCommitSHA)
        for raw in [CodeCommit.PullRequest(pullRequestId: "2", pullRequestTargets: [.init(repositoryName: "example")]),
                    .init(pullRequestId: "1", pullRequestTargets: [.init(repositoryName: "other")]),
                    .init(pullRequestId: "1", pullRequestTargets: [.init(repositoryName: "example", sourceCommit: "main")]),
                    .init(pullRequestId: "1", pullRequestTargets: [])] {
            let bad = CodeCommitBrowserFixture(request: .init(pullRequest: raw))
            await assertBrowserError(.invalidResponse) { _ = try await bad.service.loadPullRequest(scope: codeCommitScope(), repository: browserRepository, id: "1") }
        }
    }

    func testPullRequestPageBudgetAndContentRowBudgetAreBounded() async {
        let pages = (0..<1_000).map { CodeCommit.ListPullRequestsOutput(nextToken: "page-\($0)", pullRequestIds: []) }
        let fixture = CodeCommitBrowserFixture(requests: pages)
        await assertBrowserError(.incompletePagination) {
            _ = try await fixture.service.loadPullRequests(scope: codeCommitScope(), repository: browserRepository, status: nil)
        }
        let calls = await fixture.requestedPullRequests(); XCTAssertEqual(calls.count, 1_000)
        let excessive = CodeCommitBrowserFixture(requests: [.init(pullRequestIds: (1...50_001).map(String.init))])
        await assertBrowserError(.incompletePagination) {
            _ = try await excessive.service.loadPullRequests(scope: codeCommitScope(), repository: browserRepository, status: nil)
        }
    }

    private func assertBrowserError(_ expected: CodeCommitBrowserError, operation: () async throws -> Void,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? CodeCommitBrowserError, expected, file: file, line: line) }
    }
}
