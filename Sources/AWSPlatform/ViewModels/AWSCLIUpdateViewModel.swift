import Combine
import Foundation

@MainActor
final class AWSCLIUpdateViewModel: ObservableObject {
    typealias Detector = @Sendable () async throws -> AWSCLIInstallation?
    typealias Catalog = @Sendable (AWSCLIInstallSource) async throws -> AWSCLIVersion
    typealias Installer = @Sendable (AWSCLIInstallation, AWSCLIVersion,
                                     @escaping @Sendable (AWSCLIUpdatePhase) -> Void) async throws -> Void

    @Published private(set) var installation: AWSCLIInstallation?
    @Published private(set) var latestVersion: AWSCLIVersion?
    @Published private(set) var isChecking = false
    @Published private(set) var isUpdating = false
    @Published private(set) var phase: AWSCLIUpdatePhase?
    @Published private(set) var error: String?
    @Published private(set) var status = "Check the AWS CLI version to see available updates."

    private let detect: Detector
    private let latest: Catalog
    private let install: Installer
    private let activity: TransferActivity
    private let gate: AWSCLIOperationGate
    private var observation: AnyCancellable?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var checkedOnce = false

    init(detect: @escaping Detector = { try await AWSCLIInspector().inspect() },
         latest: @escaping Catalog = { try await AWSCLIVersionCatalog().latest(for: $0) },
         install: @escaping Installer = { try await AWSCLIInstaller().update($0, to: $1, progress: $2) },
         activity: TransferActivity? = nil, gate: AWSCLIOperationGate = .shared) {
        self.detect = detect
        self.latest = latest
        self.install = install
        self.activity = activity ?? .shared
        self.gate = gate
        observation = self.activity.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var canCheck: Bool { !isChecking && !isUpdating && !activity.isRestartPending }

    var canUpdate: Bool {
        guard let installation, let latestVersion else { return false }
        return canCheck && installation.source.supportsAutomaticUpdate && installation.version.major == 2
            && latestVersion.major == 2 && latestVersion > installation.version
            && activity.activeCount == 0 && !activity.cliMaintenanceActive && !gate.isUpdating
    }

    func checkIfNeeded() {
        guard !checkedOnce else { return }
        check()
    }

    func check() {
        guard canCheck else { return }
        checkedOnce = true
        isChecking = true
        error = nil
        installation = nil
        latestVersion = nil
        status = "Checking AWS CLI version…"
        let id = UUID()
        generation = id
        task = Task { [self] in
            defer {
                if generation == id { isChecking = false; task = nil }
            }
            do {
                installation = try await detect()
                guard let installation else {
                    status = "AWS CLI was not found."
                    return
                }
                guard installation.source.supportsAutomaticUpdate, installation.version.major == 2 else {
                    status = "This AWS CLI installation must be updated manually."
                    return
                }
                let available = try await latest(installation.source)
                guard available.major == 2 else { throw AWSCLIUpdateError.invalidVersion }
                latestVersion = available
                status = available > installation.version ? "An AWS CLI update is available." : "AWS CLI is up to date."
            } catch {
                self.error = Self.message(error, fallback: .checkFailed)
                status = "AWS CLI version check failed."
            }
        }
    }

    func update() {
        guard canUpdate, let snapshot = installation, let target = latestVersion else { return }
        let operation: UUID
        do { operation = try gate.beginUpdate() }
        catch { self.error = Self.message(error, fallback: .busy); return }
        guard let maintenance = activity.beginCLIMaintenance() else {
            gate.endUpdate(operation)
            error = AWSCLIUpdateError.busy.localizedDescription
            return
        }
        isUpdating = true
        error = nil
        phase = nil
        status = "Preparing the AWS CLI update…"
        let id = UUID()
        generation = id
        // App-owned state retains the task when Settings is closed. Once installation
        // starts, the process runner waits for completion rather than killing its parent.
        task = Task { [self] in
            defer {
                isUpdating = false
                phase = nil
                task = nil
                gate.endUpdate(operation)
                activity.finishCLIMaintenance(maintenance)
            }
            do {
                guard try await detect() == snapshot else { throw AWSCLIUpdateError.installationChanged }
                try await install(snapshot, target) { [weak self] phase in
                    Task { @MainActor in
                        guard let self, self.generation == id, self.isUpdating else { return }
                        self.phase = phase
                    }
                }
                phase = .verifyingInstallation
                let actual = try await detect()
                installation = actual
                guard let actual, actual.executableURL == snapshot.executableURL,
                      actual.source == snapshot.source, actual.version.major == 2,
                      actual.version >= target else { throw AWSCLIUpdateError.updateFailed }
                status = "AWS CLI was updated successfully."
            } catch {
                self.error = Self.message(error, fallback: .updateFailed)
                status = error as? AWSCLIUpdateError == .authorizationCancelled
                    ? "AWS CLI update authorization was cancelled." : "AWS CLI update failed."
            }
        }
    }

    func waitForCurrentTask() async { await task?.value }

    private static func message(_ error: Error, fallback: AWSCLIUpdateError) -> String {
        (error as? AWSCLIUpdateError ?? fallback).localizedDescription
    }
}
