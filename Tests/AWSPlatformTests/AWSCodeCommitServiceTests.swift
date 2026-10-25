import Foundation
import SotoCodeCommit
import SotoCore
import XCTest
@testable import AWSPlatform

final class AWSCodeCommitServiceTests: XCTestCase {
    func testRepositoriesFollowAllPagesIncludingEmptyPagesAndSortByName() async throws {
        let otherID = "99999999-1111-2222-3333-444444444444"
        let fixture = CodeCommitServiceFixture(listPages: [
            .init(nextToken: "empty", repositories: [.init(repositoryId: codeCommitRepositoryID, repositoryName: "z-repo")]),
            .init(nextToken: "last", repositories: []),
            .init(repositories: [.init(repositoryId: otherID, repositoryName: "a-repo")])
        ])
        let repositories = try await fixture.service.loadRepositories(scope: codeCommitScope())
        XCTAssertEqual(repositories.map(\.name), ["a-repo", "z-repo"])
        XCTAssertEqual(repositories.map(\.id), [otherID, codeCommitRepositoryID])
        let requests = await fixture.requests()
        XCTAssertEqual(requests.list.map(\.nextToken), [nil, "empty", "last"])
        XCTAssertTrue(requests.list.allSatisfy { $0.sortBy == .repositoryName && $0.order == .ascending })
        XCTAssertEqual(requests.total, 3)
    }

    func testBranchesFollowAllPagesIncludingEmptyPagesWithSameRepository() async throws {
        let fixture = CodeCommitServiceFixture(branchPages: [
            .init(branches: ["release/v1"], nextToken: "empty"),
            .init(branches: [], nextToken: "last"), .init(branches: ["develop"])
        ])
        let branches = try await fixture.service.loadBranches(scope: codeCommitScope(), repositoryName: "example")
        XCTAssertEqual(branches, ["develop", "release/v1"])
        let requests = await fixture.requests()
        XCTAssertEqual(requests.branches.map(\.nextToken), [nil, "empty", "last"])
        XCTAssertEqual(requests.branches.map(\.repositoryName), Array(repeating: "example", count: 3))
        XCTAssertEqual(requests.total, 3)
    }

    func testEmptyListsAndEmptyRepositoryMetadataAreSuccessfulWithoutCommitCalls() async throws {
        let fixture = CodeCommitServiceFixture(metadata: .init(repositoryMetadata: codeCommitMetadata(defaultBranch: nil)))
        let repositories = try await fixture.service.loadRepositories(scope: codeCommitScope())
        let branches = try await fixture.service.loadBranches(scope: codeCommitScope(), repositoryName: "example")
        let metadata = try await fixture.service.loadRepository(scope: codeCommitScope(), repositoryName: "example")
        XCTAssertTrue(repositories.isEmpty)
        XCTAssertTrue(branches.isEmpty)
        XCTAssertNil(metadata.defaultBranch)
        let requests = await fixture.requests()
        XCTAssertTrue(requests.branch.isEmpty)
        XCTAssertTrue(requests.commit.isEmpty)
    }

    func testBothListsRejectRepeatedWhitespaceAndCyclicTokens() async {
        for tokens in [["repeat", "repeat"], ["first", "second", "first"], [" \n"]] {
            let fixture = CodeCommitServiceFixture(
                listPages: tokens.map { .init(nextToken: $0, repositories: []) },
                branchPages: tokens.map { .init(branches: [], nextToken: $0) }
            )
            await assertError(CodeCommitError.incompletePagination) { _ = try await fixture.service.loadRepositories(scope: codeCommitScope()) }
            await assertError(CodeCommitError.incompletePagination) {
                _ = try await fixture.service.loadBranches(scope: codeCommitScope(), repositoryName: "example")
            }
            let requests = await fixture.requests()
            XCTAssertEqual(requests.list.count, tokens.count)
            XCTAssertEqual(requests.branches.count, tokens.count)
        }
    }

    func testBothListsStopAtPageBudgetWithoutDisplayingPartialResults() async {
        let fixture = CodeCommitServiceFixture(
            listPages: (0..<1_000).map { .init(nextToken: "page-\($0)", repositories: []) },
            branchPages: (0..<1_000).map { .init(branches: [], nextToken: "page-\($0)") }
        )
        await assertError(CodeCommitError.incompletePagination) { _ = try await fixture.service.loadRepositories(scope: codeCommitScope()) }
        await assertError(CodeCommitError.incompletePagination) {
            _ = try await fixture.service.loadBranches(scope: codeCommitScope(), repositoryName: "example")
        }
        let requests = await fixture.requests()
        XCTAssertEqual(requests.list.count, 1_000)
        XCTAssertEqual(requests.branches.count, 1_000)
    }

    func testBothListsAcceptAnExplicitEmptyFinalToken() async throws {
        let fixture = CodeCommitServiceFixture(listPages: [.init(nextToken: "", repositories: [])],
                                              branchPages: [.init(branches: ["develop"], nextToken: "")])
        let repositories = try await fixture.service.loadRepositories(scope: codeCommitScope())
        let branches = try await fixture.service.loadBranches(scope: codeCommitScope(), repositoryName: "example")
        XCTAssertTrue(repositories.isEmpty)
        XCTAssertEqual(branches, ["develop"])
        let requests = await fixture.requests()
        XCTAssertEqual(requests.list.count, 1)
        XCTAssertEqual(requests.branches.count, 1)
    }

    func testBothListsRejectDuplicateIDsAndNamesAcrossPages() async {
        let first = CodeCommit.RepositoryNameIdPair(repositoryId: codeCommitRepositoryID, repositoryName: "example")
        for duplicate in [first, .init(repositoryId: codeCommitRepositoryID, repositoryName: "other"),
                          .init(repositoryId: "99999999-1111-2222-3333-444444444444", repositoryName: "example")] {
            let fixture = CodeCommitServiceFixture(listPages: [
                .init(nextToken: "next", repositories: [first]), .init(repositories: [duplicate])
            ])
            await assertError(CodeCommitError.invalidResponse) { _ = try await fixture.service.loadRepositories(scope: codeCommitScope()) }
        }
        let fixture = CodeCommitServiceFixture(branchPages: [.init(branches: ["develop"], nextToken: "next"), .init(branches: ["develop"])])
        await assertError(CodeCommitError.invalidResponse) {
            _ = try await fixture.service.loadBranches(scope: codeCommitScope(), repositoryName: "example")
        }
    }

    func testMalformedRepositoryListRowsAreNotSilentlyDropped() async {
        let rows: [CodeCommit.RepositoryNameIdPair] = [
            .init(repositoryName: "example"), .init(repositoryId: codeCommitRepositoryID),
            .init(repositoryId: "bad", repositoryName: "example"), .init(repositoryId: codeCommitRepositoryID, repositoryName: "bad/name")
        ]
        for row in rows {
            let fixture = CodeCommitServiceFixture(listPages: [.init(repositories: [row])])
            await assertError(CodeCommitError.invalidResponse) { _ = try await fixture.service.loadRepositories(scope: codeCommitScope()) }
        }
    }

    func testBothListsFailWhenLaterPageFails() async {
        let list = CodeCommitServiceFixture(listPages: [.init(nextToken: "next", repositories: [.init(repositoryId: codeCommitRepositoryID, repositoryName: "example")])],
                                            failOperation: .list, failAt: 1)
        await assertError(AWSCodeCommitService.RequestError.repositoriesPermission) {
            _ = try await list.service.loadRepositories(scope: codeCommitScope())
        }
        let branches = CodeCommitServiceFixture(branchPages: [.init(branches: ["develop"], nextToken: "next")], failOperation: .branches, failAt: 1)
        await assertError(AWSCodeCommitService.RequestError.branchesPermission) {
            _ = try await branches.service.loadBranches(scope: codeCommitScope(), repositoryName: "example")
        }
    }

    func testRepositoryMetadataMapsFieldsAndBindsNameAccountRegionPartition() async throws {
        let fixture = CodeCommitServiceFixture()
        let detail = try await fixture.service.loadRepository(scope: codeCommitScope(), repositoryName: "example")
        XCTAssertEqual(detail.id, codeCommitRepositoryID)
        XCTAssertEqual(detail.name, "example")
        XCTAssertEqual(detail.arn, "arn:aws:codecommit:eu-west-1:111122223333:example")
        XCTAssertEqual(detail.accountID, "111122223333")
        XCTAssertEqual(detail.description, "Fixture repository")
        XCTAssertEqual(detail.defaultBranch, "develop")
        XCTAssertEqual(detail.cloneURLHTTP, "https://git-codecommit.eu-west-1.amazonaws.com/v1/repos/example")
        XCTAssertEqual(detail.cloneURLSSH, "ssh://git-codecommit.eu-west-1.amazonaws.com/v1/repos/example")
        XCTAssertEqual(detail.creationDate, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(detail.lastModifiedDate, Date(timeIntervalSince1970: 2_000))
        let requests = await fixture.requests()
        XCTAssertEqual(requests.repository.map(\.repositoryName), ["example"])
        XCTAssertEqual(requests.total, 1)
        for (region, partition) in [("cn-north-1", "aws-cn"), ("us-gov-west-1", "aws-us-gov")] {
            let scoped = CodeCommitServiceFixture(metadata: .init(repositoryMetadata: codeCommitMetadata(region: region, partition: partition)))
            let result = try await scoped.service.loadRepository(scope: codeCommitScope(region: region, partition: partition), repositoryName: "example")
            XCTAssertTrue(result.arn.hasPrefix("arn:\(partition):codecommit:\(region):"))
        }
    }

    func testRepositoryMetadataRejectsMissingFieldsWrongNameAccountARNRegionAndPartition() async {
        let invalid: [CodeCommit.RepositoryMetadata?] = [
            nil, .init(), codeCommitMetadata(name: "different"), codeCommitMetadata(account: "999900001111"),
            codeCommitMetadata(region: "us-east-1"), codeCommitMetadata(partition: "aws-cn"),
            .init(accountId: "111122223333", arn: "arn:aws:s3:eu-west-1:111122223333:example", repositoryId: codeCommitRepositoryID, repositoryName: "example"),
            .init(accountId: "999900001111", arn: "arn:aws:codecommit:eu-west-1:111122223333:example", repositoryId: codeCommitRepositoryID, repositoryName: "example"),
            .init(accountId: "111122223333", arn: "arn:aws:codecommit:eu-west-1:111122223333:example:extra", repositoryId: codeCommitRepositoryID, repositoryName: "example"),
            codeCommitMetadata(defaultBranch: "bad branch")
        ]
        for metadata in invalid {
            let fixture = CodeCommitServiceFixture(metadata: .init(repositoryMetadata: metadata))
            await assertError(CodeCommitError.invalidResponse) {
                _ = try await fixture.service.loadRepository(scope: codeCommitScope(), repositoryName: "example")
            }
        }
    }

    func testBranchAndCommitRequestsUseOneRepositoryAndTheBranchSnapshotSHA() async throws {
        let parent = String(repeating: "b", count: 40)
        let fixture = CodeCommitServiceFixture(commit: .init(commit: .init(
            author: .init(date: "1600000000 +0800", email: "author@example.test", name: "Author"), commitId: codeCommitSHA,
            committer: .init(date: "1600000001 -0700", email: "committer@example.test", name: "Committer"),
            message: "Fixture\nmessage", parents: [parent]
        )))
        let result = try await fixture.service.loadCommit(scope: codeCommitScope(), repositoryName: "example", branchName: "develop")
        XCTAssertEqual(result.id, codeCommitSHA)
        XCTAssertEqual(result.message, "Fixture\nmessage")
        XCTAssertEqual(result.authorName, "Author")
        XCTAssertEqual(result.authorEmail, "author@example.test")
        XCTAssertEqual(result.authorDate, "1600000000 +0800")
        XCTAssertEqual(result.committerName, "Committer")
        XCTAssertEqual(result.committerEmail, "committer@example.test")
        XCTAssertEqual(result.committerDate, "1600000001 -0700")
        XCTAssertEqual(result.parentIDs, [parent])
        let requests = await fixture.requests()
        XCTAssertEqual(requests.branch.map(\.repositoryName), ["example"])
        XCTAssertEqual(requests.branch.map(\.branchName), ["develop"])
        XCTAssertEqual(requests.commit.map(\.repositoryName), ["example"])
        XCTAssertEqual(requests.commit.map(\.commitId), [codeCommitSHA])
        XCTAssertEqual(requests.total, 2)
    }

    func testWrongBranchOrMalformedSHAStopsBeforeGetCommit() async {
        for branch in [CodeCommit.BranchInfo(), .init(branchName: "other", commitId: codeCommitSHA),
                       .init(branchName: "develop", commitId: "a123"), .init(branchName: "develop", commitId: String(repeating: "z", count: 40))] {
            let fixture = CodeCommitServiceFixture(branch: .init(branch: branch))
            await assertError(CodeCommitError.invalidResponse) {
                _ = try await fixture.service.loadCommit(scope: codeCommitScope(), repositoryName: "example", branchName: "develop")
            }
            let requests = await fixture.requests()
            XCTAssertTrue(requests.commit.isEmpty)
        }
    }

    func testWrongCommitSHAAndMalformedParentsAreRejected() async {
        for commit in [CodeCommit.Commit(), .init(commitId: String(repeating: "b", count: 40)), .init(commitId: codeCommitSHA, parents: ["bad"])] {
            let fixture = CodeCommitServiceFixture(commit: .init(commit: commit))
            await assertError(CodeCommitError.invalidResponse) {
                _ = try await fixture.service.loadCommit(scope: codeCommitScope(), repositoryName: "example", branchName: "develop")
            }
        }
    }

    func testInvalidScopesMakeNoRequestsForAnyLoader() async {
        for scope in [codeCommitScope(account: "bad"), codeCommitScope(region: "bad"), codeCommitScope(profile: ""),
                      codeCommitScope(region: "cn-north-1", partition: "aws")] {
            let fixture = CodeCommitServiceFixture()
            for operation in 0..<4 {
                await assertError(CodeCommitError.invalidScope) { try await Self.perform(operation, fixture: fixture, scope: scope) }
            }
            let requests = await fixture.requests()
            XCTAssertEqual(requests.total, 0)
        }
    }

    func testInvalidRepositoryNamesMakeNoRequests() async {
        for name in ["", "a/b", "bad name", "line\n", String(repeating: "a", count: 101)] {
            let fixture = CodeCommitServiceFixture()
            await assertError(CodeCommitError.invalidInput) { _ = try await fixture.service.loadRepository(scope: codeCommitScope(), repositoryName: name) }
            await assertError(CodeCommitError.invalidInput) { _ = try await fixture.service.loadBranches(scope: codeCommitScope(), repositoryName: name) }
            await assertError(CodeCommitError.invalidInput) { _ = try await fixture.service.loadCommit(scope: codeCommitScope(), repositoryName: name, branchName: "develop") }
            let requests = await fixture.requests()
            XCTAssertEqual(requests.total, 0)
        }
    }

    func testInvalidBranchNamesAreRejectedLocallyAndInResponses() async {
        for name in ["", "HEAD", "@", ".hidden", "feature/.hidden", "bad..ref", "bad.lock", "a//b", "a/", "a@{b", "a b", "a\nb", "a~b", "a:b", "a\\b", String(repeating: "a", count: 257)] {
            let fixture = CodeCommitServiceFixture(branchPages: [.init(branches: [name])])
            await assertError(CodeCommitError.invalidInput) {
                _ = try await fixture.service.loadCommit(scope: codeCommitScope(), repositoryName: "example", branchName: name)
            }
            await assertError(CodeCommitError.invalidResponse) {
                _ = try await fixture.service.loadBranches(scope: codeCommitScope(), repositoryName: "example")
            }
            let requests = await fixture.requests()
            XCTAssertTrue(requests.branch.isEmpty)
            XCTAssertTrue(requests.commit.isEmpty)
        }
    }

    func testPermissionErrorsIdentifyEachReadAPIAndNeverEchoRawErrors() async {
        let expected: [AWSCodeCommitService.RequestError] = [.repositoriesPermission, .repositoryPermission, .branchesPermission, .branchPermission, .commitPermission]
        for operation in CodeCommitServiceFixture.Operation.allCases {
            let fixture = CodeCommitServiceFixture(failOperation: operation)
            await assertError(expected[operation.rawValue]) { try await Self.perform(min(operation.rawValue, 3), fixture: fixture) }
        }
    }

    func testRepositoryMetadataRemainsReadableWhenBranchesPermissionFails() async throws {
        let fixture = CodeCommitServiceFixture(failOperation: .branches)
        await assertError(AWSCodeCommitService.RequestError.branchesPermission) {
            _ = try await fixture.service.loadBranches(scope: codeCommitScope(), repositoryName: "example")
        }
        let metadata = try await fixture.service.loadRepository(scope: codeCommitScope(), repositoryName: "example")
        XCTAssertEqual(metadata.name, "example")
    }

    func testKnownSDKFailuresAreSafeDistinctFromEmptyRepositories() async {
        let cases: [(String, AWSCodeCommitService.RequestError)] = [
            ("RepositoryDoesNotExistException", .notFound), ("BranchDoesNotExistException", .notFound), ("CommitDoesNotExistException", .notFound),
            ("CommitIdDoesNotExistException", .notFound), ("InvalidCommitIdException", .notFound),
            ("EmptyRepositoryException", .emptyRepository), ("EncryptionKeyAccessDeniedException", .encryption),
            ("EncryptionKeyDisabledException", .encryption), ("EncryptionKeyUnavailableException", .encryption),
            ("ThrottlingException", .throttled), ("UnknownPrivateFailure", .failed)
        ]
        for (code, expected) in cases {
            for operation in [CodeCommitServiceFixture.Operation.branch, .commit] {
                let fixture = CodeCommitServiceFixture(failOperation: operation, failure: CodeCommitFixtureError(code))
                await assertError(expected) {
                    _ = try await fixture.service.loadCommit(scope: codeCommitScope(), repositoryName: "example", branchName: "develop")
                }
            }
        }
    }

    func testUnknownLocalFailuresAndNetworkErrorsAreSanitized() async {
        let cases: [(Error, AWSCodeCommitService.RequestError)] = [
            (NSError(domain: "private-codecommit-token", code: 7, userInfo: [NSLocalizedDescriptionKey: "private-codecommit-token"]), .failed),
            (URLError(.cannotConnectToHost), .network)
        ]
        for (error, expected) in cases {
            let fixture = CodeCommitServiceFixture(failOperation: .list, failure: error)
            await assertError(expected) { _ = try await fixture.service.loadRepositories(scope: codeCommitScope()) }
        }
    }

    func testCredentialsAndInvalidContinuationErrorsAreSanitized() async {
        for code in ["ExpiredToken", "ExpiredTokenException", "InvalidClientTokenId", "InvalidToken"] {
            let fixture = CodeCommitServiceFixture(failOperation: .list, failure: CodeCommitFixtureError(code))
            await assertError(AWSCodeCommitService.RequestError.credentials) {
                _ = try await fixture.service.loadRepositories(scope: codeCommitScope())
            }
        }
        for operation in [CodeCommitServiceFixture.Operation.list, .branches] {
            let fixture = CodeCommitServiceFixture(failOperation: operation, failure: CodeCommitFixtureError("InvalidContinuationTokenException"))
            await assertError(CodeCommitError.incompletePagination) {
                try await Self.perform(operation.rawValue, fixture: fixture)
            }
        }
    }

    func testCancellationBeforeRequestsMakesZeroCalls() async {
        for operation in 0..<4 {
            let gate = CodeCommitRequestGate()
            let fixture = CodeCommitServiceFixture()
            let task = Task { await gate.enter(); try await Self.perform(operation, fixture: fixture) }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
            let requests = await fixture.requests()
            XCTAssertEqual(requests.total, 0)
        }
    }

    func testCancellationAfterEveryReadIgnoresUncooperativeSuccessAndStopsCommitChaining() async {
        for operation in CodeCommitServiceFixture.Operation.allCases {
            let gate = CodeCommitRequestGate()
            let fixture = CodeCommitServiceFixture(listPages: [.init(nextToken: "must-not-follow", repositories: [])],
                                                  branchPages: [.init(branches: [], nextToken: "must-not-follow")],
                                                  gateOperation: operation, gate: gate)
            let task = Task { try await Self.perform(min(operation.rawValue, 3), fixture: fixture) }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
            let requests = await fixture.requests()
            if operation == .list { XCTAssertEqual(requests.list.count, 1) }
            if operation == .branches { XCTAssertEqual(requests.branches.count, 1) }
            if operation == .branch { XCTAssertTrue(requests.commit.isEmpty) }
        }
    }

    private static func perform(_ operation: Int, fixture: CodeCommitServiceFixture, scope: MonitoringScope = codeCommitScope()) async throws {
        switch operation {
        case 0: _ = try await fixture.service.loadRepositories(scope: scope)
        case 1: _ = try await fixture.service.loadRepository(scope: scope, repositoryName: "example")
        case 2: _ = try await fixture.service.loadBranches(scope: scope, repositoryName: "example")
        default: _ = try await fixture.service.loadCommit(scope: scope, repositoryName: "example", branchName: "develop")
        }
    }

    private func assertError<E: Error & Equatable>(_ expected: E, file: StaticString = #filePath, line: UInt = #line,
                                                  operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected error", file: file, line: line) }
        catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("private-codecommit-token"), file: file, line: line)
        }
    }
}
