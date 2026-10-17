import SotoCore
import XCTest
@testable import AWSPlatform

final class AWSAssumeRoleProviderTests: XCTestCase {
    func testSourceOnlyRoleUsesCLIWithDefaultConfigurationLayout() async throws {
        let fixture = try ConfigurationFixture(config: Self.roleConfig(source: "base"), credentials: """
        [base]
        aws_access_key_id = OFFLINE-SOURCE
        aws_secret_access_key = OFFLINE-SOURCE
        """, usesCustomConfig: false)
        defer { fixture.remove() }
        XCTAssertFalse(fixture.paths.usesCustomConfig)
        let profile = try fixture.profile("target")
        let recorder = ExportRecorder()
        let provider = AWSServiceProvider(cliCredentialRunner: { try await recorder.run($0, $1) },
            identityVerifier: { credential, _ in
                XCTAssertEqual(credential.accessKeyId, "OFFLINE-ROLE")
                XCTAssertNotNil(credential.sessionToken)
                return Self.roleIdentity
            })
        try await provider.configureVerified(profile: profile, region: profile.region, paths: fixture.paths)
        // This fixture uses an isolated home. MonitoringScope reconstructs paths
        // against the real home, so verify factory/identity without that mismatch.
        let identity = try await provider.validateIdentity()
        XCTAssertEqual(identity, Self.roleIdentity)
        await provider.shutdown()
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(Array(calls[0].arguments.prefix(4)), ["configure", "export-credentials", "--profile", "target"])
        XCTAssertEqual(calls[0].environment["AWS_CONFIG_FILE"], fixture.paths.config)
        XCTAssertEqual(calls[0].environment["AWS_SHARED_CREDENTIALS_FILE"], fixture.paths.credentials)
        XCTAssertNil(calls[0].environment["AWS_ACCESS_KEY_ID"])
    }

    func testSourceOnlyRoleSupportsDefaultSourceAndCustomPaths() async throws {
        let fixture = try ConfigurationFixture(config: Self.roleConfig(source: "default"), credentials: """
        [default]
        aws_access_key_id = OFFLINE-SOURCE
        aws_secret_access_key = OFFLINE-SOURCE
        """)
        defer { fixture.remove() }
        let recorder = ExportRecorder()
        let provider = AWSServiceProvider(cliCredentialRunner: { try await recorder.run($0, $1) },
            identityVerifier: { _, _ in Self.roleIdentity })
        try await provider.configureVerified(profile: fixture.profile("target"), region: "us-east-1", paths: fixture.paths)
        await provider.shutdown()
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].environment["AWS_CONFIG_FILE"], fixture.paths.config)
    }

    func testOrdinaryStaticProfileKeepsSotoConfigPathWithoutCLI() async throws {
        let fixture = try ConfigurationFixture(config: "[profile target]\nregion = eu-west-1", credentials: """
        [target]
        aws_access_key_id = OFFLINE-STATIC
        aws_secret_access_key = OFFLINE-STATIC
        """)
        defer { fixture.remove() }
        let provider = AWSServiceProvider(cliCredentialRunner: { _, _ in
            XCTFail("Static profiles must keep their existing Soto provider")
            throw TestError.exportFailed
        }, identityVerifier: { credential, _ in
            XCTAssertEqual(credential.accessKeyId, "OFFLINE-STATIC")
            XCTAssertNil(credential.sessionToken)
            return Self.roleIdentity
        })
        try await provider.configureVerified(profile: fixture.profile("target"), region: "eu-west-1", paths: fixture.paths)
        await provider.shutdown()
    }

    func testCustomSSOKeepsCLIPathAndSameNamedProfilesUseSelectedFiles() async throws {
        let config = """
        [profile target]
        sso_session = company
        sso_account_id = 444455556666
        sso_role_name = ReadOnly
        """
        let first = try ConfigurationFixture(config: config, credentials: "")
        let second = try ConfigurationFixture(config: config, credentials: "")
        defer { first.remove(); second.remove() }
        let recorder = ExportRecorder()
        let provider = AWSServiceProvider(cliCredentialRunner: { try await recorder.run($0, $1) },
            identityVerifier: { _, _ in Self.roleIdentity })
        let profile = try first.profile("target")
        try await provider.configureVerified(profile: profile, region: "us-east-1", paths: first.paths)
        let firstClient = try await provider.ec2Client(scope: Self.scope(profile, first.paths)).client
        try await provider.configureVerified(profile: profile, region: "us-east-1", paths: second.paths)
        let secondClient = try await provider.ec2Client(scope: Self.scope(profile, second.paths)).client
        XCTAssertFalse(firstClient === secondClient)
        await provider.shutdown()
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map { $0.environment["AWS_CONFIG_FILE"] }, [first.paths.config, second.paths.config])
        XCTAssertEqual(calls.map { $0.environment["AWS_SHARED_CREDENTIALS_FILE"] },
            [first.paths.credentials, second.paths.credentials])
    }

    func testRoleAndSourceChangesReplaceClientAndRejectPreviousScope() async throws {
        let fixture = try ConfigurationFixture(config: Self.roleConfig(source: "base"), credentials: "[base]")
        defer { fixture.remove() }
        let recorder = ExportRecorder()
        let identities = RoleIdentitySequence([Self.roleIdentity, Self.identity(role: "Other"), Self.identity(role: "Other")])
        let provider = AWSServiceProvider(cliCredentialRunner: { try await recorder.run($0, $1) },
            identityVerifier: { _, _ in try await identities.next() })
        let original = try fixture.profile("target")
        try await provider.configureVerified(profile: original, region: "us-east-1", paths: fixture.paths)
        var previousClient = try await provider.ec2Client(scope: Self.scope(original, fixture.paths)).client
        let changedRole = try XCTUnwrap(ConfigReader.readProfiles(configContent:
            Self.roleConfig(source: "base", role: "Other")).first)
        let changedSource = try XCTUnwrap(ConfigReader.readProfiles(configContent:
            Self.roleConfig(source: "default", role: "Other")).first)
        for profile in [changedRole, changedSource] {
            try await provider.configureVerified(profile: profile, region: "us-east-1", paths: fixture.paths)
            let client = try await provider.ec2Client(scope:
                Self.scope(profile, fixture.paths, identity: Self.identity(role: "Other"))).client
            XCTAssertFalse(client === previousClient)
            previousClient = client
            do {
                _ = try await provider.ec2Client(scope: Self.scope(original, fixture.paths))
                XCTFail("Changed role metadata must invalidate the previous scope")
            } catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
        }
        await provider.shutdown()
        let count = await recorder.calls.count
        XCTAssertEqual(count, 3)
    }

    func testRoleAccountComesFromTargetARNRatherThanSourceSSOAccount() async throws {
        let fixture = try ConfigurationFixture(config: Self.roleConfig(source: "base") + """

        sso_session = company
        sso_account_id = 111122223333
        sso_role_name = SourceAccess
        """, credentials: "[base]")
        defer { fixture.remove() }
        let recorder = ExportRecorder()
        let profile = try fixture.profile("target")
        let provider = AWSServiceProvider(cliCredentialRunner: { try await recorder.run($0, $1) },
            identityVerifier: { _, _ in Self.roleIdentity })
        try await provider.configureVerified(profile: profile, region: "us-east-1", paths: fixture.paths)
        await provider.shutdown()

        let wrongAccountProvider = AWSServiceProvider(cliCredentialRunner: { try await recorder.run($0, $1) },
            identityVerifier: { _, _ in .init(account: "111122223333",
                arn: "arn:aws:sts::111122223333:assumed-role/ReadOnly/offline", userID: "SOURCE:offline") })
        await wrongAccountProvider.configure(profile: profile, region: "us-east-1", paths: fixture.paths)
        do {
            _ = try await wrongAccountProvider.validateIdentity()
            XCTFail("The exported identity must match the target role account")
        } catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
        await wrongAccountProvider.shutdown()
    }

    func testRoleProfileRejectsDifferentRoleOrPartitionInSameAccount() async throws {
        let fixture = try ConfigurationFixture(config: Self.roleConfig(source: "base"), credentials: "[base]")
        defer { fixture.remove() }
        let recorder = ExportRecorder()
        let mismatches = [
            Self.identity(role: "Other"),
            Self.identity(role: "ReadOnly", partition: "aws-cn"),
            AWSIdentity(account: "444455556666", arn: "arn:aws:iam::444455556666:user/ReadOnly", userID: "USER")
        ]
        for identity in mismatches {
            let provider = AWSServiceProvider(cliCredentialRunner: { try await recorder.run($0, $1) },
                identityVerifier: { _, _ in identity })
            await provider.configure(profile: try fixture.profile("target"), region: "us-east-1", paths: fixture.paths)
            do {
                _ = try await provider.validateIdentity()
                XCTFail("Matching only the role account must not authorize another principal")
            } catch { XCTAssertEqual(error as? AWSServiceError, .identityChanged) }
            await provider.shutdown()
        }
    }

    func testRolePathMatchesSTSRoleNameAcrossPartitions() async throws {
        for partition in ["aws", "aws-cn", "aws-us-gov"] {
            let region = partition == "aws-cn" ? "cn-north-1" : partition == "aws-us-gov" ? "us-gov-west-1" : "us-east-1"
            let config = Self.roleConfig(source: "base", role: "team/service/ReadOnly")
                .replacingOccurrences(of: "arn:aws:", with: "arn:\(partition):")
            let fixture = try ConfigurationFixture(config: config, credentials: "[base]")
            defer { fixture.remove() }
            let recorder = ExportRecorder()
            let identity = Self.identity(role: "ReadOnly", partition: partition)
            let provider = AWSServiceProvider(cliCredentialRunner: { try await recorder.run($0, $1) },
                identityVerifier: { _, _ in identity })
            let profile = try fixture.profile("target")
            try await provider.configureVerified(profile: profile, region: region, paths: fixture.paths)
            _ = try await provider.ec2Client(scope: Self.scope(profile, fixture.paths, identity: identity, region: region))
            await provider.shutdown()
        }
    }

    func testOrdinarySSOProfileKeepsExistingIdentityVerification() async throws {
        let fixture = try ConfigurationFixture(config: """
        [profile target]
        sso_session = company
        sso_account_id = 444455556666
        sso_role_name = ReadOnly
        """, credentials: "")
        defer { fixture.remove() }
        let recorder = ExportRecorder()
        let ssoIdentity = Self.identity(role: "AWSReservedSSO_ReadOnly_offline")
        let provider = AWSServiceProvider(cliCredentialRunner: { try await recorder.run($0, $1) },
            identityVerifier: { _, _ in ssoIdentity })
        let profile = try fixture.profile("target")
        try await provider.configureVerified(profile: profile, region: "us-east-1", paths: fixture.paths)
        _ = try await provider.ec2Client(scope: Self.scope(profile, fixture.paths, identity: ssoIdentity))
        await provider.shutdown()
    }

    func testRoleExportFailureAndMissingTokenDoNotFallBackToStaticTarget() async throws {
        let fixture = try ConfigurationFixture(config: Self.roleConfig(source: "missing"), credentials: """
        [target]
        aws_access_key_id = OFFLINE-STATIC
        aws_secret_access_key = OFFLINE-STATIC
        """)
        defer { fixture.remove() }
        let profile = try fixture.profile("target")
        let runners: [AWSCLICredentialProvider.Runner] = [
            { _, _ in throw TestError.exportFailed },
            { _, _ in Data("{\"Version\":1,\"AccessKeyId\":\"OFFLINE\",\"SecretAccessKey\":\"OFFLINE\"}".utf8) }
        ]
        for runner in runners {
            let provider = AWSServiceProvider(cliCredentialRunner: runner, identityVerifier: { _, _ in
                XCTFail("Failed role export must not reach identity validation")
                throw TestError.unexpectedVerification
            })
            await provider.configure(profile: profile, region: "us-east-1", paths: fixture.paths)
            do {
                _ = try await provider.validateIdentity()
                XCTFail("Invalid role export must fail")
            } catch { XCTAssertTrue(error is AWSCLICredentialProvider.ExportError) }
            do {
                _ = try await provider.ec2Client(scope: Self.scope(profile, fixture.paths))
                XCTFail("Failed role export must not create a verified scope")
            } catch { XCTAssertEqual(error as? AWSServiceError, .notConfigured) }
            await provider.shutdown()
        }
    }

    func testInvalidRoleARNFailsBeforeCLIExportOrIdentityVerification() async throws {
        let fixture = try ConfigurationFixture(config: """
        [profile target]
        role_arn = arn:aws:iam::invalid:role/ReadOnly
        source_profile = base
        """, credentials: "[base]")
        defer { fixture.remove() }
        let provider = AWSServiceProvider(cliCredentialRunner: { _, _ in
            XCTFail("Invalid role ARN must not run the CLI")
            throw TestError.exportFailed
        }, identityVerifier: { _, _ in
            XCTFail("Invalid role ARN must not reach identity validation")
            throw TestError.unexpectedVerification
        })
        await provider.configure(profile: try fixture.profile("target"), region: "us-east-1", paths: fixture.paths)
        do {
            _ = try await provider.validateIdentity()
            XCTFail("Invalid role metadata must fail")
        } catch { XCTAssertEqual(error as? AWSServiceError, .identityUnavailable) }
        await provider.shutdown()
    }

    private static let roleIdentity = AWSIdentity(account: "444455556666",
        arn: "arn:aws:sts::444455556666:assumed-role/ReadOnly/offline", userID: "ROLE:offline")

    private static func roleConfig(source: String, role: String = "ReadOnly") -> String {
        """
        [profile target]
        role_arn = arn:aws:iam::444455556666:role/\(role)
        source_profile = \(source)
        region = us-east-1
        """
    }

    private static func scope(_ profile: AWSProfile, _ paths: AWSConfigurationPaths,
                              identity: AWSIdentity? = nil, region: String = "us-east-1") -> MonitoringScope {
        MonitoringScope(profile: profile, identity: identity ?? roleIdentity, region: region, paths: paths)
    }

    private static func identity(role: String, partition: String = "aws") -> AWSIdentity {
        AWSIdentity(account: "444455556666",
            arn: "arn:\(partition):sts::444455556666:assumed-role/\(role)/offline", userID: "ROLE:offline")
    }

    private enum TestError: Error { case exportFailed, unexpectedVerification }

    private actor RoleIdentitySequence {
        private var identities: [AWSIdentity]
        init(_ identities: [AWSIdentity]) { self.identities = identities }
        func next() throws -> AWSIdentity {
            guard !identities.isEmpty else { throw TestError.unexpectedVerification }
            return identities.removeFirst()
        }
    }

    private actor ExportRecorder {
        struct Call: Sendable {
            let arguments: [String]
            let environment: [String: String]
        }
        var calls: [Call] = []

        func run(_ arguments: [String], _ environment: [String: String]) throws -> Data {
            calls.append(Call(arguments: arguments, environment: environment))
            return Data("""
            {"Version":1,"AccessKeyId":"OFFLINE-ROLE","SecretAccessKey":"OFFLINE-ROLE","SessionToken":"OFFLINE-ROLE","Expiration":"2099-01-01T00:00:00Z"}
            """.utf8)
        }
    }

    private struct ConfigurationFixture {
        let root: URL
        let paths: AWSConfigurationPaths

        init(config: String, credentials: String, usesCustomConfig: Bool = true) throws {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".tmp/audit-fixes/f4/\(UUID().uuidString)", isDirectory: true)
            let directory = root.appendingPathComponent(usesCustomConfig ? "custom" : ".aws", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configURL = directory.appendingPathComponent("config")
            let credentialsURL = directory.appendingPathComponent("credentials")
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            try credentials.write(to: credentialsURL, atomically: true, encoding: .utf8)
            paths = AWSConfigurationPaths(environment: usesCustomConfig ? [
                "AWS_CONFIG_FILE": configURL.path,
                "AWS_SHARED_CREDENTIALS_FILE": credentialsURL.path
            ] : [:], homeDirectory: root)
        }

        func profile(_ name: String) throws -> AWSProfile {
            try XCTUnwrap(ConfigReader.readProfiles(paths: paths).first { $0.name == name })
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
