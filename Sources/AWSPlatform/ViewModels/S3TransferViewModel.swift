import Foundation
import Combine

@MainActor
final class S3TransferViewModel: ObservableObject {
    typealias Uploader = @Sendable (S3UploadIntent, @escaping S3ProgressHandler) async throws -> Void
    typealias Downloader = @Sendable (S3TransferContext, S3ObjectModel, S3DownloadDestination, @escaping S3ProgressHandler) async throws -> S3DownloadResult
    typealias FilePreparer = @Sendable (URL) async throws -> S3LocalFile
    typealias Picker = @MainActor () async -> URL?
    typealias DropLoader = @MainActor () async throws -> URL

    @Published private(set) var isBusy = false
    @Published var pendingUpload: S3UploadIntent?
    @Published private(set) var progress = S3TransferProgress(bytes: 0, total: nil)
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var activeKey: String?
    @Published private(set) var refreshID: UUID?
    @Published private(set) var completedDownload: S3DownloadResult?
    private(set) var completedContext: S3TransferContext?
    private(set) var scope: MonitoringScope?
    private let uploader: Uploader
    private let downloader: Downloader
    private let filePreparer: FilePreparer
    private let activity: TransferActivity
    private var activityObservation: AnyCancellable?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var accessedURL: URL?
    private var uploading = false
    private var lastProgressTime = Date.distantPast

    init(uploader: @escaping Uploader, downloader: @escaping Downloader, activity: TransferActivity? = nil,
         filePreparer: @escaping FilePreparer = { try await S3LocalFile.prepare(url: $0) }) {
        self.uploader = uploader
        self.downloader = downloader
        self.filePreparer = filePreparer
        self.activity = activity ?? .shared
        activityObservation = self.activity.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    var canStart: Bool { scope?.isValid == true && !isBusy && pendingUpload == nil && !activity.isRestartPending }

    func configure(scope: MonitoringScope?) {
        reset()
        self.scope = scope?.isValid == true ? scope : nil
    }

    func reset() {
        generation = UUID()
        task?.cancel()
        task = nil
        pendingUpload = nil
        releaseAccess()
        isBusy = false
        status = nil
        error = nil
        activeKey = nil
        progress = .init(bytes: 0, total: nil)
        completedContext = nil
        refreshID = nil
        completedDownload = nil
        scope = nil
    }

    /// Invalidate panels and confirmations when the user leaves this Bucket/prefix.
    func leaveBrowser() {
        let current = scope
        reset()
        scope = current
    }

    func chooseUpload(context: S3TransferContext, picker: @escaping Picker) {
        guard canStart, accepts(context) else { return }
        let token = begin(key: nil, uploading: true, status: "Choose a file to upload")
        task = Task { [weak self] in
            guard let self else { return }
            let url = await picker()
            guard current(token, context), !Task.isCancelled else { return }
            guard let url else { finishSelection(); return }
            do {
                try await prepareUpload(url, context: context, token: token)
            } catch { fail(error, token: token, context: context) }
        }
    }

    /// Capture the browsing context before the item provider resolves its file URL.
    @discardableResult
    func receiveUploadDrop(context: S3TransferContext, numberOfFiles: Int, loader: @escaping DropLoader) -> Bool {
        guard canStart, accepts(context), numberOfFiles > 0 else { return false }
        guard numberOfFiles == 1 else {
            status = nil
            error = S3TransferError.multipleFiles.errorDescription
            return false
        }
        let token = begin(key: nil, uploading: true, status: "Preparing upload")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await loader()
                guard current(token, context), !Task.isCancelled else { return }
                try await prepareUpload(url, context: context, token: token)
            } catch { fail(error, token: token, context: context) }
        }
        return true
    }

    func dismissUpload() {
        pendingUpload = nil
        releaseAccess()
    }

    func confirmUpload(_ intent: S3UploadIntent) {
        guard !isBusy, pendingUpload == intent, accepts(intent.context), let lease = activity.begin() else { return }
        pendingUpload = nil
        let token = begin(key: intent.key, uploading: true, status: "Uploading")
        let uploader = self.uploader
        let activity = self.activity
        task = Task { [weak self] in
            defer { activity.finish(lease) }
            do {
                try await uploader(intent) { [weak self] value in
                    await self?.update(value, token: token, context: intent.context)
                }
                guard let self, current(token, intent.context), !Task.isCancelled else { return }
                isBusy = false
                status = "Upload complete"
                releaseAccess()
                task = nil
                completedContext = intent.context
                refreshID = UUID()
            } catch S3TransferError.objectExists(let etag, let region) {
                guard let self, current(token, intent.context), !Task.isCancelled else { return }
                var confirmation = intent
                confirmation.overwriteETag = etag
                confirmation.resolvedRegion = region
                pendingUpload = confirmation
                isBusy = false
                status = nil
                task = nil
            } catch {
                self?.fail(error, token: token, context: intent.context)
            }
        }
    }

    func chooseDownload(context: S3TransferContext, object: S3ObjectModel, picker: @escaping Picker) {
        guard canStart, accepts(context), !object.isPrefix else { return }
        let token = begin(key: object.key, uploading: false, status: "Choose a save location")
        let downloader = self.downloader
        task = Task { [weak self] in
            guard let self else { return }
            let url = await picker()
            guard current(token, context), !Task.isCancelled else { return }
            guard let url else { finishSelection(); return }
            do {
                acquireAccess(url)
                let destination = try S3DownloadDestination(url: url)
                guard let lease = activity.begin() else { finishSelection(); releaseAccess(); return }
                defer { activity.finish(lease) }
                status = "Downloading"
                let result = try await downloader(context, object, destination) { [weak self] value in
                    await self?.update(value, token: token, context: context)
                }
                guard current(token, context), !Task.isCancelled else { return }
                isBusy = false
                status = "Download complete"
                completedDownload = result
                task = nil
                releaseAccess()
            } catch { fail(error, token: token, context: context) }
        }
    }

    func cancel() {
        let warning = uploading
            ? "Upload cancelled. AWS may already have received the file. Refresh to check."
            : "Download stopped. Incomplete files are discarded; a completed file may already be saved."
        let currentScope = scope
        reset()
        scope = currentScope
        status = warning
    }

    private func begin(key: String?, uploading: Bool, status: String) -> UUID {
        generation = UUID()
        self.uploading = uploading
        self.status = status
        completedDownload = nil
        activeKey = key
        isBusy = true
        error = nil
        progress = .init(bytes: 0, total: nil)
        lastProgressTime = .distantPast
        return generation
    }

    private func accepts(_ context: S3TransferContext) -> Bool { context.isValid && scope == context.scope }
    private func current(_ token: UUID, _ context: S3TransferContext) -> Bool {
        token == generation && accepts(context)
    }

    private func update(_ value: S3TransferProgress, token: UUID, context: S3TransferContext) {
        guard current(token, context) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProgressTime) >= 0.1 || value.bytes == value.total else { return }
        progress = value
        lastProgressTime = now
    }

    private func fail(_ failure: Error, token: UUID, context: S3TransferContext) {
        guard current(token, context), !Task.isCancelled else { return }
        isBusy = false
        status = nil
        error = (AWSS3TransferService.map(failure) as? S3TransferError)?.errorDescription ?? S3TransferError.failed.errorDescription
        task = nil
        releaseAccess()
    }

    private func finishSelection() {
        isBusy = false
        status = nil
        task = nil
    }

    private func prepareUpload(_ url: URL, context: S3TransferContext, token: UUID) async throws {
        guard url.isFileURL else { throw S3TransferError.invalidFile }
        acquireAccess(url)
        status = "Preparing upload"
        let file = try await filePreparer(url)
        guard current(token, context), !Task.isCancelled else { return }
        let key = try context.key(filename: url.lastPathComponent)
        pendingUpload = .init(context: context, file: file, key: key)
        isBusy = false
        status = nil
        task = nil
    }

    private func acquireAccess(_ url: URL) {
        if url.startAccessingSecurityScopedResource() { accessedURL = url }
    }

    private func releaseAccess() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }
}
