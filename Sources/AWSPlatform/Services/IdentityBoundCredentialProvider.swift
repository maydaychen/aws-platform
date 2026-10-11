import Foundation
import CryptoKit
import SotoCore
import SotoSTS

/// Session suffixes can change on renewal; the account and principal ID cannot.
struct AWSStablePrincipal: Equatable, Sendable {
    let account: String
    let arn: String
    let principalID: String

    init(_ identity: AWSIdentity) throws {
        let parts = identity.arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard identity.account.range(of: "^[0-9]{12}$", options: .regularExpression) != nil,
              parts.count == 6, parts[0] == "arn", ["iam", "sts"].contains(String(parts[2])),
              parts[4] == identity.account, !parts[5].isEmpty,
              !identity.userID.isEmpty, identity.userID != "-" else { throw AWSServiceError.identityUnavailable }
        account = identity.account
        arn = Self.normalizedARN(identity.arn)
        if parts[5].hasPrefix("assumed-role/") {
            guard let id = identity.userID.split(separator: ":", maxSplits: 1).first else {
                throw AWSServiceError.identityUnavailable
            }
            principalID = String(id)
        } else {
            principalID = identity.userID
        }
    }

    static func normalizedARN(_ arn: String) -> String {
        guard let marker = arn.range(of: ":assumed-role/"),
              let slash = arn[marker.upperBound...].lastIndex(of: "/") else { return arn }
        return String(arn[..<slash])
    }
}

actor IdentityBoundCredentialProvider: CredentialProvider {
    typealias Verifier = @Sendable (Credential, String) async throws -> AWSIdentity
    nonisolated var description: String { "IdentityBoundCredentialProvider" }
    private let source: AWSClient
    private let region: String
    private let expectedAccount: String?
    private let verifier: Verifier
    private let onInvalidation: @Sendable () -> Void
    private var credential: Credential?
    private var boundIdentity: AWSIdentity?
    private var principal: AWSStablePrincipal?
    private var invalidated = false
    private var verifications: [String: Task<AWSIdentity, Error>] = [:]

    init(source: AWSClient, region: String, expectedAccount: String?,
         verifier: @escaping Verifier, onInvalidation: @escaping @Sendable () -> Void) {
        self.source = source
        self.region = region
        self.expectedAccount = expectedAccount
        self.verifier = verifier
        self.onInvalidation = onInvalidation
    }

    func getCredential(logger: Logger) async throws -> Credential {
        guard !invalidated else { throw AWSServiceError.identityChanged }
        let candidate: Credential
        do {
            candidate = try await source.credentialProvider.getCredential(logger: logger)
        } catch {
            if !(error is CancellationError), principal != nil { invalidate(notify: true) }
            throw error
        }
        try Task.checkCancellation()
        guard !invalidated else { throw AWSServiceError.identityChanged }
        if let credential, Self.same(credential, candidate) { return candidate }
        // Opaque, length-delimited fingerprints coalesce only identical candidates.
        let key = Self.verificationKey(candidate)
        let task: Task<AWSIdentity, Error>
        if let pending = verifications[key] {
            task = pending
        } else {
            let verifier = self.verifier
            let region = self.region
            task = Task { try await verifier(candidate, region) }
            verifications[key] = task
        }
        do {
            let identity = try await task.value
            verifications[key] = nil
            try Task.checkCancellation()
            guard !invalidated else { throw AWSServiceError.identityChanged }
            let nextPrincipal = try AWSStablePrincipal(identity)
            guard expectedAccount == nil || expectedAccount == identity.account,
                  principal == nil || principal == nextPrincipal else {
                invalidate(notify: true)
                throw AWSServiceError.identityChanged
            }
            principal = nextPrincipal
            boundIdentity = identity
            credential = candidate
            return candidate
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            invalidate(notify: true)
            throw AWSServiceError.identityChanged
        }
    }

    func identity() throws -> AWSIdentity {
        guard !invalidated, let boundIdentity else { throw AWSServiceError.identityUnavailable }
        return boundIdentity
    }

    func invalidate(notify: Bool = false) {
        guard !invalidated else { return }
        invalidated = true
        credential = nil
        verifications.values.forEach { $0.cancel() }
        verifications.removeAll()
        if notify { onInvalidation() }
    }

    func shutdown() async throws {
        invalidate()
        try await source.shutdown()
    }

    private static func same(_ lhs: Credential, _ rhs: Credential) -> Bool {
        lhs.accessKeyId == rhs.accessKeyId && lhs.secretAccessKey == rhs.secretAccessKey
            && lhs.sessionToken == rhs.sessionToken
    }

    private static func verificationKey(_ credential: Credential) -> String {
        var digest = SHA256()
        digest.update(data: Data([credential.sessionToken == nil ? 0 : 1]))
        for value in [credential.accessKeyId, credential.secretAccessKey, credential.sessionToken ?? ""] {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
            digest.update(data: bytes)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ credential: Credential, region: String) async throws -> AWSIdentity {
        // A separate static provider verifies these exact bytes, not a second profile lookup.
        let client = AWSClient(credentialProvider: .static(accessKeyId: credential.accessKeyId,
            secretAccessKey: credential.secretAccessKey, sessionToken: credential.sessionToken))
        do {
            let response = try await STS(client: client, region: .init(rawValue: region)).getCallerIdentity(.init())
            let identity = AWSIdentity(account: response.account ?? "", arn: response.arn ?? "", userID: response.userId ?? "")
            try await client.shutdown()
            return identity
        } catch {
            try? await client.shutdown()
            if error is CancellationError { throw CancellationError() }
            throw AWSServiceError.identityUnavailable
        }
    }
}
