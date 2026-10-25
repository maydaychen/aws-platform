import Foundation
import SotoCore
import SotoEC2

@MainActor
final class EC2ViewModel: ObservableObject {
    typealias InstanceLoader = () async throws -> [EC2InstanceModel]
    typealias ImageNameLoader = ([String]) async throws -> [String: String]
    typealias DetailLoader = (String) async throws -> EC2InstanceDetailModel
    typealias SectionLoader = (EC2InstanceDetailModel, EC2DetailSection) async throws -> EC2DetailSectionResult

    @Published var instances: [EC2InstanceModel] = []
    @Published var selectedInstance: EC2InstanceModel? {
        didSet {
            guard oldValue?.instanceId != selectedInstance?.instanceId else { return }
            displayedDetailSection = nil
            loadDetailForSelection()
        }
    }
    @Published var isImageNameLoading = false
    @Published private(set) var sectionStates: [EC2DetailSection: EC2DetailSectionState] = [:]
    @Published var instanceDetail: EC2InstanceDetailModel?
    @Published var isLoading = false
    @Published private(set) var isStale = false
    @Published var isDetailLoading = false
    @Published var error: String?
    @Published var detailError: String?
    private(set) var scope: MonitoringScope?
    @Published var searchText = ""
    @Published var stateFilter = "All"

    private var loadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var instanceLoader: InstanceLoader?
    private var imageNameLoader: ImageNameLoader?
    private var detailLoader: DetailLoader?
    private var sectionLoader: SectionLoader?
    private var sectionTasks: [EC2DetailSection: Task<Void, Never>] = [:]
    private var sectionGenerations: [EC2DetailSection: Int] = [:]
    private var requestedSections: Set<EC2DetailSection> = []
    private var displayedDetailSection: EC2DetailSection?
    private var detailGeneration = 0
    private var listGeneration = 0
    private var hasAttemptedLoad = false
    private var hasLoadedList = false

    init(
        instanceLoader: InstanceLoader? = nil,
        imageNameLoader: ImageNameLoader? = nil,
        detailLoader: DetailLoader? = nil,
        sectionLoader: SectionLoader? = nil
    ) {
        self.instanceLoader = instanceLoader
        self.imageNameLoader = imageNameLoader
        self.detailLoader = detailLoader
        self.sectionLoader = sectionLoader
    }

    var availableStates: [String] {
        ["All"] + Set(instances.map(\.state)).sorted()
    }

    var otherStates: [String] {
        availableStates.filter { !["All", "running", "stopped"].contains($0) }
    }

    func loadedCount(for state: String) -> Int {
        state == "All" ? instances.count : instances.filter { $0.state == state }.count
    }

    var filteredInstances: [EC2InstanceModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return instances.filter { instance in
            let matchesState = stateFilter == "All" || instance.state == stateFilter
            let matchesSearch = query.isEmpty || [
                instance.name,
                instance.instanceId,
                instance.instanceType,
                instance.state,
                instance.privateIP,
                instance.publicIP,
                instance.vpcId,
                instance.subnetId,
                instance.availabilityZone
            ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
            || instance.tags.contains { key, value in
                key.lowercased().contains(query) || value.lowercased().contains(query)
            }
            return matchesState && matchesSearch
        }
    }

    func configure(provider: AWSServiceProvider, scope: MonitoringScope, refreshImmediately: Bool = true) {
        instanceLoader = {
            let client = try await provider.ec2Client(scope: scope)
            return try await EC2DataLoader.fetchInstances(client: client)
        }
        imageNameLoader = { ids in
            let client = try await provider.ec2Client(scope: scope)
            return try await EC2DataLoader.fetchImageNames(ids: ids, client: client)
        }
        detailLoader = { instanceId in
            let client = try await provider.ec2Client(scope: scope)
            return try await EC2DataLoader.fetchDetail(instanceId: instanceId, client: client)
        }
        sectionLoader = { base, section in
            let client = try await provider.ec2Client(scope: scope)
            return try await EC2DataLoader.fetchSection(base: base, section: section, client: client)
        }
        reset()
        self.scope = scope
        if refreshImmediately { refresh() }
    }

    func loadIfNeeded() {
        guard !hasAttemptedLoad else { return }
        refresh()
    }

    func refresh() {
        guard instanceLoader != nil else { return }
        hasAttemptedLoad = true
        listGeneration += 1
        loadTask?.cancel()
        invalidateDetail()
        loadTask = Task { await loadInstances() }
    }

    func waitForCurrentLoad() async { await loadTask?.value }

    func cancelLoading() {
        listGeneration += 1
        loadTask?.cancel()
        detailGeneration += 1
        detailTask?.cancel()
        if isDetailLoading { detailError = "Loading cancelled. Use Refresh to try again." }
        for section in requestedSections where sectionStates[section] == nil {
            sectionStates[section] = .failed("Loading cancelled. Use Refresh to try again.")
        }
        for (section, task) in sectionTasks {
            task.cancel()
            if sectionStates[section] == .loading {
                sectionStates[section] = .failed("Loading cancelled. Use Refresh to try again.")
            }
        }
        sectionTasks = [:]
        requestedSections = []
        isLoading = false
        isDetailLoading = false
        isImageNameLoading = false
    }

    func reset() {
        scope = nil
        cancelLoading()
        hasAttemptedLoad = false
        hasLoadedList = false
        isStale = false
        instances = []
        selectedInstance = nil
        instanceDetail = nil
        sectionStates = [:]
        displayedDetailSection = nil
        error = nil
        detailError = nil
        stateFilter = "All"
    }

    func loadInstances(selectFirstIfNeeded: Bool = true) async {
        guard !Task.isCancelled, let instanceLoader else { return }
        hasAttemptedLoad = true
        listGeneration += 1
        let generation = listGeneration
        invalidateDetail()
        isImageNameLoading = false
        isLoading = true
        error = nil
        defer {
            if generation == listGeneration {
                isLoading = false
                isImageNameLoading = false
            }
        }

        do {
            let rows = try await instanceLoader()
            try Task.checkCancellation()
            guard generation == listGeneration else { return }
            let selectedID = selectedInstance?.instanceId
            instances = rows
            hasLoadedList = true
            isStale = false
            selectedInstance = selectedID.flatMap { id in rows.first { $0.instanceId == id } }
                ?? (selectFirstIfNeeded ? rows.first : nil)
            if selectedID == selectedInstance?.instanceId, selectedInstance != nil {
                loadDetailForSelection()
            }
            if !availableStates.contains(stateFilter) { stateFilter = "All" }

            // Publish the basic list before optional AMI name enrichment finishes.
            await loadImageNames(rows: rows, generation: generation)
        } catch {
            guard generation == listGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            isStale = hasLoadedList
            self.error = UserFacingError.message(for: error)
        }
    }

    private func loadImageNames(rows: [EC2InstanceModel], generation: Int) async {
        guard let imageNameLoader, !Task.isCancelled, generation == listGeneration else { return }
        isImageNameLoading = true
        defer { if generation == listGeneration { isImageNameLoading = false } }
        do {
            let names = try await imageNameLoader(Array(Set(rows.compactMap(\.imageId))))
            try Task.checkCancellation()
            guard generation == listGeneration else { return }
            let selectedID = selectedInstance?.instanceId
            instances = rows.map { row in
                EC2InstanceModel(
                    instanceId: row.instanceId, name: row.name, instanceType: row.instanceType, state: row.state,
                    privateIP: row.privateIP, publicIP: row.publicIP, platformDetails: row.platformDetails,
                    architecture: row.architecture, vpcId: row.vpcId, subnetId: row.subnetId,
                    availabilityZone: row.availabilityZone, securityGroups: row.securityGroups, imageId: row.imageId,
                    imageName: row.imageId.flatMap { names[$0] } ?? row.imageName,
                    keyName: row.keyName, launchTime: row.launchTime, tags: row.tags
                )
            }
            selectedInstance = selectedID.flatMap { id in instances.first { $0.instanceId == id } }
        } catch {
            // AMI names are optional; the instance rows remain usable.
        }
    }

    private func invalidateDetail() {
        detailGeneration += 1
        detailTask?.cancel()
        sectionTasks.values.forEach { $0.cancel() }
        sectionTasks = [:]
        sectionGenerations = [:]
        sectionStates = [:]
        requestedSections = Set(displayedDetailSection.map { [$0] } ?? [])
        instanceDetail = nil
        detailError = nil
        isDetailLoading = false
    }

    @discardableResult
    func loadDetailForSelection() -> Task<Void, Never>? {
        invalidateDetail()
        guard let instanceID = selectedInstance?.instanceId, detailLoader != nil else { return nil }
        isDetailLoading = true
        let list = listGeneration, detail = detailGeneration
        let task = Task { await performLoadDetail(instanceId: instanceID, list: list, detail: detail) }
        detailTask = task
        return task
    }

    func loadDetail(instanceId: String) async {
        guard selectedInstance?.instanceId == instanceId, detailLoader != nil, !Task.isCancelled else { return }
        invalidateDetail()
        isDetailLoading = true
        await performLoadDetail(instanceId: instanceId, list: listGeneration, detail: detailGeneration)
    }

    private func performLoadDetail(instanceId: String, list: Int, detail: Int) async {
        guard let detailLoader, !Task.isCancelled,
              isCurrent(instanceId: instanceId, list: list, detail: detail) else { return }
        do {
            let value = try await detailLoader(instanceId)
            try Task.checkCancellation()
            guard isCurrent(instanceId: instanceId, list: list, detail: detail) else { return }
            instanceDetail = value
            isDetailLoading = false
            for section in requestedSections { startSectionIfNeeded(section) }
        } catch {
            guard isCurrent(instanceId: instanceId, list: list, detail: detail) else { return }
            isDetailLoading = false
            detailError = error is CancellationError
                ? "Loading cancelled. Use Refresh to try again." : UserFacingError.message(for: error)
        }
    }

    func showDetailSection(_ section: EC2DetailSection?) {
        displayedDetailSection = section
        if instanceDetail == nil { requestedSections = Set(section.map { [$0] } ?? []) }
        guard let section else { return }
        requestedSections.insert(section)
        startSectionIfNeeded(section)
    }

    @discardableResult
    func loadDetailSectionIfNeeded(_ section: EC2DetailSection) -> Task<Void, Never>? {
        requestedSections.insert(section)
        startSectionIfNeeded(section)
        return sectionTasks[section]
    }

    func retryDetailSection(_ section: EC2DetailSection) {
        guard sectionStates[section] != .loading else { return }
        sectionStates[section] = .notLoaded
        loadDetailSectionIfNeeded(section)
    }

    func waitForCurrentDetail() async { await detailTask?.value }
    func waitForDetailSection(_ section: EC2DetailSection) async { await sectionTasks[section]?.value }

    private func startSectionIfNeeded(_ section: EC2DetailSection) {
        guard sectionStates[section] == nil || sectionStates[section] == .notLoaded,
              let base = instanceDetail, base.instanceId == selectedInstance?.instanceId else { return }
        // Legacy injected DetailLoader values are complete snapshots and need no second loader.
        guard let sectionLoader else { sectionStates[section] = .loaded; return }
        sectionStates[section] = .loading
        let list = listGeneration, detail = detailGeneration
        let request = (sectionGenerations[section] ?? 0) + 1
        sectionGenerations[section] = request
        sectionTasks[section] = Task {
            guard !Task.isCancelled, self.isCurrent(instanceId: base.instanceId, list: list, detail: detail),
                  self.sectionGenerations[section] == request else { return }
            do {
                let result = try await sectionLoader(base, section)
                try Task.checkCancellation()
                guard self.isCurrent(instanceId: base.instanceId, list: list, detail: detail),
                      self.sectionGenerations[section] == request else { return }
                guard result.section == section else { throw EC2SectionError.unexpectedSection }
                switch result {
                case .storage(let volumes): self.instanceDetail?.volumes = volumes
                case .security(let groups): self.instanceDetail?.securityGroups = groups
                }
                self.sectionStates[section] = .loaded
            } catch {
                guard self.isCurrent(instanceId: base.instanceId, list: list, detail: detail),
                      self.sectionGenerations[section] == request else { return }
                self.sectionStates[section] = .failed(error is CancellationError
                    ? "Loading cancelled. Use Refresh to try again." : UserFacingError.message(for: error))
            }
        }
    }

    private func isCurrent(instanceId: String, list: Int, detail: Int) -> Bool {
        list == listGeneration && detail == detailGeneration && selectedInstance?.instanceId == instanceId
    }

    static func fetchCPUCreditMode(
        instanceId: String,
        instanceType: String,
        request: (EC2.DescribeInstanceCreditSpecificationsRequest) async throws -> EC2.DescribeInstanceCreditSpecificationsResult
    ) async throws -> EC2CPUCreditMode? {
        try await EC2DataLoader.fetchCPUCreditMode(instanceId: instanceId, instanceType: instanceType, request: request)
    }
}

private enum EC2SectionError: LocalizedError {
    case unexpectedSection
    var errorDescription: String? {
        switch self {
        case .unexpectedSection: return "Unable to load EC2 detail section."
        }
    }
}
