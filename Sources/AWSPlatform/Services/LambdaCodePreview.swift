import Foundation

/// Preview limits, deliberately independent of AWS deployment quotas.
struct LambdaCodePreviewLimits: Sendable {
    var maximumDownloadBytes = 50 * 1_024 * 1_024
    var maximumExpandedBytes = 250 * 1_024 * 1_024
    var maximumEntries = 10_000
    var maximumFilePreviewBytes = 200_000
    var maximumTotalPreviewBytes = 10 * 1_024 * 1_024
    var maximumPathBytes = 1_024
    var maximumPathDepth = 32
    var downloadTimeout: TimeInterval = 60
    var extractionTimeout: TimeInterval = 30
}

struct LambdaCodePreview: Sendable {
    var limits = LambdaCodePreviewLimits()
    var downloader = LambdaCodeDownloader()
    var temporaryDirectory = FileManager.default.temporaryDirectory

    func load(from location: String) async throws -> [LambdaCodeFile] {
        guard let url = URL(string: location), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil else {
            throw LambdaCodeError.invalidDownloadURL
        }
        try Task.checkCancellation()
        // The ZIP is the only on-disk payload. Archive entry paths are never used
        // for filesystem operations, including links, resource forks or metadata.
        let root = temporaryDirectory
            .appendingPathComponent("AWSPlatformLambdaCode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("function.zip")
        try await downloader.download(
            from: url, to: archive,
            maximumBytes: limits.maximumDownloadBytes, timeout: limits.downloadTimeout
        )
        try Task.checkCancellation()
        let limits = limits
        let reader = Task.detached(priority: .userInitiated) {
            try LambdaZIPReader.read(at: archive, limits: limits)
        }
        return try await withTaskCancellationHandler {
            let files = try await reader.value
            try Task.checkCancellation()
            return files
        } onCancel: {
            reader.cancel()
        }
    }
}

enum LambdaCodeError: LocalizedError, Equatable {
    case invalidDownloadURL
    case downloadFailed(Int?)
    case downloadTooLarge
    case downloadTimedOut
    case invalidArchive
    case unsupportedArchive
    case unsafeArchivePath
    case archiveTooLarge
    case tooManyFiles
    case previewTooLarge
    case extractionTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidDownloadURL:
            return "Lambda code download URL is invalid."
        case .downloadFailed(let code):
            return code.map { "Lambda code download failed with HTTP \($0)." }
                ?? "Lambda code download failed."
        case .downloadTooLarge:
            return "Lambda deployment package exceeds the download size limit."
        case .downloadTimedOut:
            return "Lambda code download timed out. Try again."
        case .invalidArchive:
            return "Lambda deployment package is damaged or has inconsistent ZIP metadata."
        case .unsupportedArchive:
            return "Lambda source preview supports only unencrypted, single-disk ZIP files using Store or Deflate, without ZIP64 or special file entries."
        case .unsafeArchivePath:
            return "Lambda deployment package contains unsafe, duplicate, or unsupported file paths."
        case .archiveTooLarge:
            return "Lambda deployment package exceeds the expanded size limit."
        case .tooManyFiles:
            return "Lambda deployment package contains too many files or directories."
        case .previewTooLarge:
            return "Lambda source files exceed the total text preview limit."
        case .extractionTimedOut:
            return "Lambda source preview timed out while reading the ZIP."
        }
    }
}
