import CryptoKit
import Foundation

// Public-key-only verification; this tool never accesses the signing Keychain.
guard CommandLine.arguments.count == 4,
      let key = Data(base64Encoded: CommandLine.arguments[1]), key.count == 32,
      let signature = Data(base64Encoded: CommandLine.arguments[2]), signature.count == 64 else {
    fputs("Expected public key, Ed25519 signature and archive path\n", stderr)
    exit(2)
}
do {
    let url = URL(fileURLWithPath: CommandLine.arguments[3])
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 512 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
    let archive = try Data(contentsOf: url, options: .mappedIfSafe)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    guard publicKey.isValidSignature(signature, for: archive) else {
        fputs("Update signature verification failed\n", stderr)
        exit(1)
    }
} catch {
    fputs("Could not verify update archive\n", stderr)
    exit(1)
}
