import Foundation
import Combine

@MainActor
private final class NexusCloudAttemptReporter {
    weak var viewModel: ModelDownloadViewModel?

    init(viewModel: ModelDownloadViewModel) {
        self.viewModel = viewModel
    }

    func report(_ provider: NexusManagedCloudProvider) {
        viewModel?.activeCloudProvider = provider
    }
}

struct RemoteRuntimeInstallRequest: Identifiable, Equatable {
    let id = UUID()
    let model: LocalModel
    let nodeIDs: [UUID]
    let deviceNames: [String]
    let targets: Set<NexusDownloadTarget>
}

@MainActor
final class ModelDownloadViewModel: ObservableObject {
    @Published var query = ""
    @Published var backend: ModelBackend = .ollama
    @Published var selectedModelID: String?
    @Published private(set) var catalog: [LocalModel] = []
    @Published private(set) var catalogs: [ModelBackend: [LocalModel]] = [:]
    @Published private(set) var states: [String: ModelDownloadState] = [:]
    @Published private(set) var catalogMessage = "Loading the model registry…"
    @Published var pendingOllamaInstall: LocalModel?
    @Published var pendingRemoteRuntimeInstall: RemoteRuntimeInstallRequest?
    @Published private(set) var activeModel: LocalModel?
    @Published private(set) var activeModelSupportsThinking = false
    @Published fileprivate(set) var activeCloudProvider: NexusManagedCloudProvider?
    @Published private(set) var cloudFallbackMessage: String?
    @Published var thinkingModeEnabled: Bool { didSet { persistThinkingMode() } }
    let apiProvider = NexusAPIProviderStore()

    var memoryGB: Int {
        connect?.remoteMemoryGB ?? max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
    }

    var connectController: NexusConnectController? { connect }

    private let ollama: OllamaManager
    private let lmStudio: LMStudioManager
    private let catalogService: ModelCatalogService
    private let connect: NexusConnectController?
    private let managedCloud = NexusManagedCloudInferenceStore()
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var installedModelRecords: [String: LocalModel] = [:]
    private var placements: [String: Set<NexusDownloadTarget>] = [:]
    private var targetProgress: [String: [NexusDownloadTarget: ModelDownloadProgress]] = [:]
    private var pendingResolvedTargets: [String: Set<NexusDownloadTarget>] = [:]
    private let installedDefaultsKey = "nexus.installed-model-ids"
    private let installedModelsDefaultsKey = "nexus.installed-model-records"
    private let activeModelDefaultsKey = "nexus.active-model"
    private let placementsDefaultsKey = "nexus.model-placements.v2"
    private let thinkingModeDefaultsKey = "nexus.thinking-mode-enabled"

    init(
        ollama: OllamaManager = .init(),
        lmStudio: LMStudioManager = .init(),
        catalogService: ModelCatalogService = .init(),
        connect: NexusConnectController? = nil
    ) {
        self.ollama = ollama
        self.lmStudio = lmStudio
        self.catalogService = catalogService
        self.connect = connect
        thinkingModeEnabled = UserDefaults.standard.bool(forKey: thinkingModeDefaultsKey)
        if let data = UserDefaults.standard.data(forKey: placementsDefaultsKey),
           let saved = try? JSONDecoder().decode([String: [NexusDownloadTarget]].self, from: data) {
            placements = saved.mapValues(Set.init)
        }
        if let data = UserDefaults.standard.data(forKey: installedModelsDefaultsKey),
           let models = try? JSONDecoder().decode([LocalModel].self, from: data) {
            models.forEach {
                installedModelRecords[$0.id] = $0
                states[$0.id] = .installed
            }
        }
        let legacyIDs = UserDefaults.standard.stringArray(forKey: installedDefaultsKey) ?? []
        legacyIDs.forEach { id in
            states[id] = .installed
            if installedModelRecords[id] == nil, let model = LocalModel.restoring(legacyID: id) {
                installedModelRecords[id] = model
            }
        }
        if let data = UserDefaults.standard.data(forKey: activeModelDefaultsKey) {
            activeModel = try? JSONDecoder().decode(LocalModel.self, from: data)
        }
        if let activeModel {
            installedModelRecords[activeModel.id] = activeModel
            states[activeModel.id] = .installed
        } else if let fallback = installedModelRecords.values.sorted(by: { $0.id < $1.id }).first {
            use(fallback)
        }
        connect?.$pairedNodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                objectWillChange.send()
                self.reconcileRemoteInventories()
            }
            .store(in: &cancellables)
        connect?.$modelRoute
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        Task {
            await discoverInstalledRuntimeModels()
            await discoverInstalledStudioModels()
            await refreshCatalog(for: .ollama)
            await refreshCatalog(for: .lmStudio)
            await refreshActiveThinkingCapability()
        }
    }

    var recommended: [LocalModel] {
        recommended(for: backend)
    }

    func recommended(for backend: ModelBackend) -> [LocalModel] {
        let budget = max(4, Int(Double(memoryGB) * 0.72))
        return ModelCatalog.starterModels.filter {
            $0.backend == backend && $0.minimumRAMGB > 0 && $0.minimumRAMGB <= budget
        }
    }

    func isRecommended(_ model: LocalModel) -> Bool {
        recommended(for: model.backend).contains { $0.identifier == model.identifier }
    }

    var visibleCatalog: [LocalModel] {
        let matchingBackend = catalog.filter { $0.backend == backend }
        let custom = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.isEmpty else { return matchingBackend }
        if matchingBackend.contains(where: { $0.identifier.caseInsensitiveCompare(custom) == .orderedSame }) { return matchingBackend }
        return [LocalModel(customIdentifier: custom, backend: backend)] + matchingBackend
    }

    var installedModels: [LocalModel] {
        let all = ModelCatalog.starterModels + catalog + Array(installedModelRecords.values)
        return Array(Set(all)).filter { states[$0.id] == .installed }
    }

    func refreshCatalog() async {
        await refreshCatalog(for: backend, query: query)
    }

    func refreshCatalog(for backend: ModelBackend, query: String = "") async {
        catalogMessage = "Searching the full \(backend.title) registry…"
        do {
            let fetched = try await catalogService.models(
                for: backend,
                query: query.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            catalogs[backend] = fetched
            if backend == self.backend { catalog = fetched }
            catalogMessage = fetched.isEmpty ? "No registry matches. You can still download the exact identifier above." : "\(fetched.count) registry models found."
            if selectedModelID == nil { selectedModelID = recommended.first?.id ?? fetched.first?.id }
        } catch {
            let fallback = ModelCatalog.starterModels.filter { $0.backend == backend }
            catalogs[backend] = fallback
            if backend == self.backend { catalog = fallback }
            catalogMessage = error.localizedDescription
        }
    }

    func models(for backend: ModelBackend, matching query: String) -> [LocalModel] {
        let source = catalogs[backend] ?? ModelCatalog.starterModels.filter { $0.backend == backend }
        let installed = installedModels.filter { $0.backend == backend }
        let all = Array(Set(recommended(for: backend) + source + installed)).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        let matches = all.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
            $0.identifier.localizedCaseInsensitiveContains(trimmed)
        }
        if matches.contains(where: { $0.identifier.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return matches
        }
        return [LocalModel(customIdentifier: trimmed, backend: backend)] + matches
    }

    func backendChanged() {
        selectedModelID = nil
        Task { await refreshCatalog() }
    }

    func download(_ model: LocalModel) {
        guard downloadTasks[model.id] == nil, !(states[model.id]?.isActive ?? false) else { return }
        let targets = selectedDownloadTargets
        if targets.contains(.automatic), let connect {
            states[model.id] = .preparing("Choosing the best available Mac…")
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let resolved = try await connect.automaticDownloadTarget(
                        for: model,
                        localHasModel: placements[model.id]?.contains(.thisMac) == true
                    )
                    downloadTasks[model.id] = nil
                    beginDownload(model, targets: [resolved])
                } catch {
                    states[model.id] = .failed(error.localizedDescription)
                    downloadTasks[model.id] = nil
                }
            }
            downloadTasks[model.id] = task
            return
        }
        beginDownload(model, targets: targets)
    }

    private func beginDownload(_ model: LocalModel, targets: Set<NexusDownloadTarget>) {
        if let connect,
           let offline = targets.compactMap({ target -> NexusPairedNode? in
               guard case .pairedNode(let id) = target else { return nil }
               return connect.pairedNodes.first(where: { $0.id == id && $0.status != .online })
           }).first {
            states[model.id] = .failed("\(offline.displayName) is \(offline.status.rawValue). Remote downloads never fall back to this Mac.")
            return
        }
        if targets.contains(.thisMac), model.backend == .ollama && ollama.executableURL() == nil {
            pendingResolvedTargets[model.id] = targets
            pendingOllamaInstall = model
            return
        }
        if let missing = remoteTargetsMissingRuntime(model: model, targets: targets), !missing.isEmpty {
            guard model.backend == .ollama else {
                let names = missing.compactMap(nodeName).joined(separator: ", ")
                states[model.id] = .failed("LM Studio is not installed on \(names). Select Ollama for automatic provisioning, or install LM Studio there.")
                return
            }
            pendingRemoteRuntimeInstall = .init(
                model: model,
                nodeIDs: missing,
                deviceNames: missing.compactMap(nodeName),
                targets: targets
            )
            return
        }
        startDownload(model, targets: targets, installOllamaFirst: false)
    }

    func installOllamaAndContinue() {
        guard let model = pendingOllamaInstall else { return }
        pendingOllamaInstall = nil
        let targets = pendingResolvedTargets.removeValue(forKey: model.id) ?? selectedDownloadTargets
        startDownload(model, targets: targets, installOllamaFirst: true)
    }

    func installRemoteRuntimeAndContinue() {
        guard let request = pendingRemoteRuntimeInstall else { return }
        pendingRemoteRuntimeInstall = nil
        let targets = request.targets
        states[request.model.id] = .preparing("Installing Ollama on selected host\(request.nodeIDs.count == 1 ? "" : "s")…")
        let task = Task { [weak self] in
            guard let self, let connect else { return }
            do {
                for nodeID in request.nodeIDs {
                    _ = try await connect.provisionDefaultRuntime(
                        on: nodeID,
                        preferred: .ollama,
                        userConfirmed: true
                    )
                }
                downloadTasks[request.model.id] = nil
                startDownload(request.model, targets: targets, installOllamaFirst: false)
            } catch {
                states[request.model.id] = .failed(error.localizedDescription)
                downloadTasks[request.model.id] = nil
            }
        }
        downloadTasks[request.model.id] = task
    }

    func cancel(_ model: LocalModel) {
        downloadTasks[model.id]?.cancel()
        if model.backend == .lmStudio { lmStudio.cancel(modelID: model.id) }
        states[model.id] = .idle
    }

    func retry(_ model: LocalModel) {
        states[model.id] = .idle
        download(model)
    }

    func use(_ model: LocalModel) {
        guard isUsable(model) else { return }
        activeModel = model
        if let data = try? JSONEncoder().encode(model) {
            UserDefaults.standard.set(data, forKey: activeModelDefaultsKey)
        }
        Task { await refreshActiveThinkingCapability() }
    }

    func response(
        to prompt: String,
        onDelta: @escaping @Sendable (_ delta: String, _ accumulated: String) async -> Void
    ) async throws -> String {
        try await response(
            messages: [.init(role: "user", content: prompt)],
            onDelta: onDelta
        )
    }

    func response(
        messages: [NexusChatMessage],
        temperature: Double? = nil,
        maximumTokens: Int? = nil,
        onThinkingDelta: (@Sendable (_ delta: String, _ accumulated: String) async -> Void)? = nil,
        onDelta: @escaping @Sendable (_ delta: String, _ accumulated: String) async -> Void
    ) async throws -> String {
        cloudFallbackMessage = nil
        let cloudAttempts: [(provider: NexusManagedCloudProvider, configuration: NexusAPIProviderConfiguration)]
        do {
            cloudAttempts = try managedCloud.configurations()
        } catch {
            cloudAttempts = []
            apiProvider.recordError(error)
        }

        if !cloudAttempts.isEmpty {
            do {
                activeCloudProvider = nil
                let attemptReporter = NexusCloudAttemptReporter(viewModel: self)
                let result = try await NexusManagedCloudInferenceClient.streamChat(
                    attempts: cloudAttempts,
                    messages: messages,
                    temperature: temperature,
                    maximumTokens: maximumTokens,
                    onProviderAttempt: { provider in
                        await attemptReporter.report(provider)
                    },
                    onDelta: onDelta
                )
                activeCloudProvider = result.provider
                return result.text
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NexusManagedCloudInferenceError {
                // A response that visibly began must not be followed by a
                // second model's answer. Only pre-stream provider failures are
                // eligible for the local fallback below.
                if case .interruptedStream = error { throw error }
                activeCloudProvider = nil
                cloudFallbackMessage = error.localizedDescription
                apiProvider.recordError(error)
            } catch {
                // Both cloud providers failed before an answer began. The
                // existing local model path remains the final, offline-safe
                // fallback exactly as before.
                activeCloudProvider = nil
                cloudFallbackMessage = error.localizedDescription
                apiProvider.recordError(error)
            }
        }

        if apiProvider.enabled {
            do {
                return try await NexusAPIProviderClient.streamChat(
                    configuration: try apiProvider.configuration(),
                    messages: messages,
                    temperature: temperature,
                    maximumTokens: maximumTokens,
                    onDelta: onDelta
                )
            } catch {
                // A configured API provider (including Gemini) is an
                // optional cloud fallback, never a dead end. If it rejects a
                // request before output starts, preserve the diagnostic and
                // continue to the selected remote/local model.
                let apiFailure = "API fallback failed: \(error.localizedDescription)"
                if let existingFailure = cloudFallbackMessage, !existingFailure.isEmpty {
                    cloudFallbackMessage = "\(existingFailure) \(apiFailure)"
                } else {
                    cloudFallbackMessage = apiFailure
                }
                apiProvider.recordError(error)
            }
        }
        activeCloudProvider = nil
        guard let activeModel else {
            throw LocalModelError.invalidResponse("Choose an installed model in the model window first")
        }
        if let connect, connect.modelRoute != .thisMac {
            return try await connect.response(
                model: activeModel,
                messages: messages,
                temperature: temperature,
                maximumTokens: maximumTokens,
                onDelta: onDelta
            )
        }
        switch activeModel.backend {
        case .ollama:
            do {
                return try await ollama.streamChat(
                    model: activeModel.identifier,
                    messages: messages,
                    temperature: temperature,
                    maximumTokens: maximumTokens,
                    includeThinking: thinkingModeEnabled && activeModelSupportsThinking,
                    onThinkingDelta: onThinkingDelta,
                    onDelta: onDelta
                )
            } catch {
                throw surfacedFallbackError(localError: error)
            }
        case .lmStudio:
            do {
                return try await lmStudio.streamChat(
                    model: activeModel.identifier,
                    messages: messages,
                    temperature: temperature,
                    maximumTokens: maximumTokens,
                    onDelta: onDelta
                )
            } catch {
                throw surfacedFallbackError(localError: error)
            }
        }
    }

    private func surfacedFallbackError(localError: Error) -> Error {
        guard let cloudFallbackMessage, !cloudFallbackMessage.isEmpty else { return localError }
        return NexusInferenceFallbackError(cloudMessage: cloudFallbackMessage, localError: localError)
    }

    /// Planning is routed through native Ollama tools when the active local
    /// model advertises support. Other providers retain the JSON contract so
    /// existing local, remote, and API-backed inference stays compatible.
    func toolPlan(
        messages: [NexusChatMessage],
        registeredTools: [NexRegisteredTool]
    ) async throws -> NexPrimaryToolPlan {
        guard let activeModel else {
            throw LocalModelError.invalidResponse("Choose an installed model in the model window first")
        }
        let cloudConfigured = (try? managedCloud.configurations().isEmpty == false) ?? false
        if !cloudConfigured,
           !apiProvider.enabled,
           activeModel.backend == .ollama,
           (connect == nil || connect?.modelRoute == .thisMac) {
            return try await ollama.planTools(
                model: activeModel.identifier,
                messages: messages,
                registeredTools: registeredTools
            )
        }
        let raw = try await response(
            messages: messages,
            temperature: 0,
            maximumTokens: 360,
            onDelta: { _, _ in }
        )
        if let plan = NexPrimaryToolPlanner.parseStrict(raw, registeredTools: registeredTools) {
            return plan
        }

        // Planning is advisory. A second repair request used to make every
        // malformed plan consume another full cloud response, then could still
        // strand an ordinary greeting before generation began. Fall through
        // immediately: the actual response path still gets the unmodified
        // conversation and can answer normally.
        NSLog("Nex tool planner returned invalid JSON; continuing without planned tools.")
        return .fallback
    }

    /// Used only for optional, non-blocking status-line generation. It never
    /// changes the user's active conversational model or routing selection.
    func response(
        using model: LocalModel,
        messages: [NexusChatMessage],
        temperature: Double? = nil,
        maximumTokens: Int? = nil,
        onDelta: @escaping @Sendable (_ delta: String, _ accumulated: String) async -> Void
    ) async throws -> String {
        guard isUsable(model) else {
            throw LocalModelError.invalidResponse("Choose an installed local status model")
        }
        switch model.backend {
        case .ollama:
            return try await ollama.streamChat(
                model: model.identifier,
                messages: messages,
                temperature: temperature,
                maximumTokens: maximumTokens,
                onDelta: onDelta
            )
        case .lmStudio:
            return try await lmStudio.streamChat(
                model: model.identifier,
                messages: messages,
                temperature: temperature,
                maximumTokens: maximumTokens,
                onDelta: onDelta
            )
        }
    }

    func shutdown() {
        downloadTasks.values.forEach { $0.cancel() }
        downloadTasks.removeAll()
        lmStudio.stopManagedProcesses()
        ollama.stopManagedServer()
    }

    private func persistThinkingMode() {
        UserDefaults.standard.set(thinkingModeEnabled, forKey: thinkingModeDefaultsKey)
    }

    private func refreshActiveThinkingCapability() async {
        guard let activeModel,
              activeModel.backend == .ollama,
              (connect == nil || connect?.modelRoute == .thisMac) else {
            activeModelSupportsThinking = false
            thinkingModeEnabled = false
            return
        }
        activeModelSupportsThinking = await ollama.supportsThinking(model: activeModel.identifier)
        if !activeModelSupportsThinking { thinkingModeEnabled = false }
    }

    /// Reconciles preferences with the runtimes themselves. This makes models
    /// downloaded by an older Nexus build (or directly by Ollama/LM Studio)
    /// immediately usable even when that older build never saved model data.
    private func discoverInstalledRuntimeModels() async {
        var discovered: [LocalModel] = []
        if ollama.executableURL() != nil, let names = try? await ollama.installedModelNames() {
            discovered += names.map { LocalModel(customIdentifier: $0, backend: .ollama) }
        }
        if lmStudio.executableURL() != nil, let names = try? await lmStudio.installedModelNames() {
            discovered += names
                .filter { !$0.localizedCaseInsensitiveContains("embed") }
                .map { LocalModel(customIdentifier: $0, backend: .lmStudio) }
        }
        discovered.forEach {
            installedModelRecords[$0.id] = $0
            placements[$0.id, default: []].insert(.thisMac)
            states[$0.id] = .installed
        }
        if activeModel == nil, let first = discovered.first {
            use(first)
        }
        if !discovered.isEmpty { persistInstalledModels() }
    }

    private func discoverInstalledStudioModels() async {
        reconcileRemoteInventories()
        guard let connect else { return }
        for node in connect.pairedNodes where node.status == .online {
            _ = try? await connect.installedModels(on: node.id)
        }
        reconcileRemoteInventories()
    }

    private func startDownload(
        _ model: LocalModel,
        targets: Set<NexusDownloadTarget>,
        installOllamaFirst: Bool
    ) {
        states[model.id] = .preparing("Preparing \(model.backend.title)…")
        targetProgress[model.id] = [:]
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                if installOllamaFirst, targets.contains(.thisMac) {
                    states[model.id] = .preparing("Installing the official Ollama app…")
                    try await ollama.installOfficialMacApp()
                }
                let ollama = self.ollama
                let lmStudio = self.lmStudio
                let connect = self.connect
                try await withThrowingTaskGroup(of: NexusDownloadTarget.self) { group in
                    for target in targets where self.placements[model.id]?.contains(target) != true {
                        group.addTask { [weak self, ollama, lmStudio, connect] in
                            guard let self else { throw CancellationError() }
                            switch target {
                            case .automatic:
                                throw NexusConnectError.requestFailed("Automatic target was not resolved before download")
                            case .thisMac:
                                switch model.backend {
                                case .ollama:
                                    try await ollama.pull(model: model.identifier) { update in
                                        Task { @MainActor in self.apply(update, to: model, target: target) }
                                    }
                                case .lmStudio:
                                    try await lmStudio.download(model) { update in
                                        Task { @MainActor in self.apply(update, to: model, target: target) }
                                    }
                                }
                            case .pairedNode(let nodeID):
                                guard let connect else {
                                    throw NexusConnectError.unavailable("Nexus Connect is unavailable")
                                }
                                try await connect.pullModel(model, on: nodeID) { update in
                                    await self.apply(update, to: model, target: target)
                                }
                            }
                            return target
                        }
                    }
                    for try await completedTarget in group {
                        self.placements[model.id, default: []].insert(completedTarget)
                        self.persistInstalledModels()
                    }
                }
                states[model.id] = .installed
                installedModelRecords[model.id] = model
                persistInstalledModels()
                use(model)
            } catch {
                states[model.id] = (error as? LocalModelError) == .cancelled ? .idle : .failed(error.localizedDescription)
            }
            downloadTasks[model.id] = nil
        }
        downloadTasks[model.id] = task
    }

    private func apply(
        _ update: ModelDownloadProgress,
        to model: LocalModel,
        target: NexusDownloadTarget
    ) {
        targetProgress[model.id, default: [:]][target] = update
        let updates = Array(targetProgress[model.id, default: [:]].values)
        let fraction = updates.isEmpty ? update.fraction : updates.map(\.fraction).reduce(0, +) / Double(updates.count)
        let completed = updates.compactMap(\.completedBytes).reduce(0, +)
        let totalValues = updates.compactMap(\.totalBytes)
        let total = totalValues.isEmpty ? nil : totalValues.reduce(0, +)
        states[model.id] = .downloading(
            progress: fraction,
            completedBytes: completed > 0 ? completed : nil,
            totalBytes: total,
            status: updates.count > 1 ? "Downloading to \(updates.count) devices" : update.status
        )
    }

    private func persistInstalledModels() {
        let models = installedModelRecords.values.sorted(by: { $0.id < $1.id })
        UserDefaults.standard.set(models.map(\.id), forKey: installedDefaultsKey)
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: installedModelsDefaultsKey)
        }
        let encodedPlacements = placements.mapValues(Array.init)
        if let data = try? JSONEncoder().encode(encodedPlacements) {
            UserDefaults.standard.set(data, forKey: placementsDefaultsKey)
        }
    }

    func isUsable(_ model: LocalModel) -> Bool {
        guard let targets = placements[model.id], !targets.isEmpty else { return false }
        guard let connect else { return targets.contains(.thisMac) }
        switch connect.modelRoute {
        case .thisMac:
            return targets.contains(.thisMac)
        case .pairedNode(let id):
            return targets.contains(.pairedNode(id)) && connect.pairedNodes.first(where: { $0.id == id })?.status == .online
        case .automatic:
            if targets.contains(.thisMac) { return true }
            return connect.pairedNodes.contains { $0.status == .online && targets.contains(.pairedNode($0.id)) }
        }
    }

    func placementDescription(for model: LocalModel) -> String? {
        guard let targets = placements[model.id], !targets.isEmpty else { return nil }
        return targets.map(targetName).sorted().joined(separator: ", ")
    }

    private var selectedDownloadTargets: Set<NexusDownloadTarget> {
        connect?.downloadTargets ?? [.thisMac]
    }

    private func remoteTargetsMissingRuntime(
        model: LocalModel,
        targets: Set<NexusDownloadTarget>
    ) -> [UUID]? {
        guard let connect else { return nil }
        let runtime: NexusRuntimeKind = model.backend == .ollama ? .ollama : .lmStudio
        return targets.compactMap { target in
            guard case .pairedNode(let id) = target,
                  let node = connect.pairedNodes.first(where: { $0.id == id }) else { return nil }
            guard node.status == .online else { return nil }
            // Protocol-v1 hosts do not advertise runtime inventory. Preserve
            // their existing pull behavior and let their clear host error win.
            guard node.capabilities.contains(.runtimeStatus) else { return nil }
            return node.runtimes.contains(where: { $0.kind == runtime }) ? nil : id
        }
    }

    private func reconcileRemoteInventories() {
        guard let connect else { return }
        for node in connect.pairedNodes {
            let target = NexusDownloadTarget.pairedNode(node.id)
            for descriptor in node.modelInventory {
                let model = LocalModel(
                    customIdentifier: descriptor.identifier,
                    backend: descriptor.runtime == .ollama ? .ollama : .lmStudio
                )
                installedModelRecords[model.id] = model
                placements[model.id, default: []].insert(target)
                states[model.id] = .installed
            }
        }
        persistInstalledModels()
    }

    private func nodeName(_ id: UUID) -> String? {
        connect?.pairedNodes.first(where: { $0.id == id })?.displayName
    }

    private func targetName(_ target: NexusDownloadTarget) -> String {
        switch target {
        case .automatic: "Automatic"
        case .thisMac: "This Mac"
        case .pairedNode(let id): nodeName(id) ?? "Forgotten device"
        }
    }
}
