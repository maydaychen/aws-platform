import Foundation

@MainActor
final class SecurityGroupsViewModel: ObservableObject {
    typealias Loader = @Sendable (MonitoringScope) async throws -> [SecurityGroupModel]

    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var groups: [SecurityGroupModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var isStale = false
    @Published var selectedGroup: SecurityGroupModel? {
        didSet {
            if let selectedGroup, !groups.contains(selectedGroup) { self.selectedGroup = nil }
        }
    }
    @Published var searchText = ""
    @Published var vpcFilter = "All"

    private let loader: Loader
    private var task: Task<Void, Never>?
    private var generation = 0
    private var attemptedLoad = false
    private var loadedList = false

    init(loader: @escaping Loader) { self.loader = loader }

    var availableVPCs: [String] { ["All"] + Set(groups.compactMap(\.vpcID)).sorted() }

    var filteredGroups: [SecurityGroupModel] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.filter { group in
            guard vpcFilter == "All" || group.vpcID?.caseInsensitiveCompare(vpcFilter) == .orderedSame else { return false }
            guard !search.isEmpty else { return true }
            let metadata = [group.id, group.name] + [group.ownerID, group.vpcID, group.description].compactMap { $0 }
                + group.tags.flatMap { [$0.name, $0.value] }
            if metadata.contains(where: { $0.localizedCaseInsensitiveContains(search) }) { return true }
            return (group.inboundRules + group.outboundRules).contains { rule in
                let fields = [rule.protocolName, rule.portRange, rule.target]
                    + [rule.description, rule.referencedGroupID, rule.referencedAccountID].compactMap { $0 }
                    + rule.fields.flatMap { [$0.name, $0.value] }
                return fields.contains { $0.localizedCaseInsensitiveContains(search) }
            }
        }
    }

    func configure(scope: MonitoringScope?) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func loadIfNeeded() { if !attemptedLoad { refresh() } }

    func loadGroups() async {
        guard !Task.isCancelled else { return }
        if isLoading {
            await task?.value
            return
        }
        refresh()
        let generation = self.generation
        let task = self.task
        await withTaskCancellationHandler {
            await task?.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.cancel()
            }
        }
    }

    func waitForLoad() async { await task?.value }

    func refresh() {
        guard let scope else { return }
        generation += 1
        let generation = self.generation
        task?.cancel()
        task = nil
        attemptedLoad = true
        guard scope.isValid else {
            isLoading = false
            error = SecurityGroupError.invalidScope.localizedDescription
            return
        }
        isLoading = true
        error = nil
        let loader = self.loader
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let groups = try await loader(scope)
                try Task.checkCancellation()
                guard let self, self.scope == scope, self.generation == generation else { return }
                guard groups.allSatisfy({ SecurityGroupModel.validID($0.id) }), Set(groups.map(\.id)).count == groups.count else {
                    throw SecurityGroupError.invalidResponse
                }
                let selectedID = self.selectedGroup?.id
                self.groups = groups
                self.selectedGroup = selectedID.flatMap { id in groups.first { $0.id == id } }
                if !self.availableVPCs.contains(where: { $0.caseInsensitiveCompare(self.vpcFilter) == .orderedSame }) {
                    self.vpcFilter = "All"
                }
                self.loadedList = true
                self.isStale = false
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, self.scope == scope, self.generation == generation else { return }
                self.isLoading = false
                self.isStale = self.loadedList
                self.task = nil
                self.error = self.listMessage(error)
            }
        }
    }

    func cancel() {
        guard isLoading else { return }
        generation += 1
        task?.cancel()
        task = nil
        isLoading = false
        isStale = loadedList
        error = listMessage(CancellationError())
    }

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        scope = nil
        groups = []
        selectedGroup = nil
        isLoading = false
        error = nil
        isStale = false
        searchText = ""
        vpcFilter = "All"
        attemptedLoad = false
        loadedList = false
    }

    private func listMessage(_ error: Error) -> String {
        let message: String
        if error is CancellationError { message = "Loading cancelled. Refresh to try again." }
        else if let error = error as? SecurityGroupError { message = error.localizedDescription }
        else { message = "Unable to load security groups. Refresh to try again." }
        return isStale ? "\(message) Showing the previous security group list; it may be out of date." : message
    }
}
