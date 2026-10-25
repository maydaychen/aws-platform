import Foundation

struct AWSCLIVersionCatalog: Sendable {
    private let client: AWSCLIHTTPClient

    init(client: AWSCLIHTTPClient = AWSCLIHTTPClient()) { self.client = client }

    func latest(for source: AWSCLIInstallSource) async throws -> AWSCLIVersion {
        do {
            switch source {
            case .homebrew:
                let url = URL(string: "https://formulae.brew.sh/api/formula/awscli.json")!
                let data = try await client.data(from: url, maximumBytes: 256 * 1024)
                return try Self.parseHomebrew(data)
            case .officialPackage, .unmanaged:
                let url = URL(string: "https://awscli.amazonaws.com/v2/version.txt")!
                let data = try await client.data(from: url, maximumBytes: 1024)
                return try Self.parseOfficial(data)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw AWSCLIUpdateError.checkFailed }
    }

    static func parseOfficial(_ data: Data) throws -> AWSCLIVersion {
        guard let value = String(data: data, encoding: .utf8),
              let version = AWSCLIVersion(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              version.major == 2 else { throw AWSCLIUpdateError.invalidVersion }
        return version
    }

    static func parseHomebrew(_ data: Data) throws -> AWSCLIVersion {
        struct Formula: Decodable {
            struct Versions: Decodable { let stable: String }
            let name: String
            let versions: Versions
        }
        guard let formula = try? JSONDecoder().decode(Formula.self, from: data),
              formula.name == "awscli", let version = AWSCLIVersion(formula.versions.stable),
              version.major == 2 else { throw AWSCLIUpdateError.invalidVersion }
        return version
    }
}
