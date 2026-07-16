import Foundation
import Combine

@MainActor
final class ModelDownloadViewModel: ObservableObject {
    @Published var query = ""
    @Published var backend: ModelBackend = .ollama
    @Published var selectedModelID: String?
    @Published private(set) var catalog: [LocalModel] = []
    @Published private(set) var states: [String: ModelDownloadState] = [:]
    @Published private(set) var catalogMessage = "Loading the model registry…"
    @Published var pendingOllamaInstall: LocalModel?
    @Published private(set) var activeModel: LocalModel?

    var memoryGB: Int {
        connect?.remoteMemoryGB ?? max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
    }

    var connectController: NexusConnectController? { connect }

    private let ollama: OllamaManager
    private let lmStudio: LMStudioManager
    private let catalogService: ModelCatalogService
    private let connect: NexusConnectController?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var installedModelRecords: [String: LocalModel] = [:]
    private var studioModelIDs: Set<String>
    private let installedDefaultsKey = "nexus.installed-model-ids"
    private let installedModelsDefaultsKey = "nexus.installed-model-records"
    private let activeModelDefaultsKey = "nexus.active-model"
    private let studioModelsDefaultsKey = "nexus.connect.studio-model-ids"

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
        studioModelIDs = Set(UserDefaults.standard.stringArray(forKey: studioModelsDefaultsKey) ?? [])
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
        connect?.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                objectWillChange.send()
                if case .ready = state {
                    Task { await self.discoverInstalledStudioModels() }
                }
            }
            .store(in: &cancellables)
        Task {
            await discoverInstalledRuntimeModels()
            await discoverInstalledStudioModels()
            await refreshCatalog()
        }
    }

    var recommended: [LocalModel] {
        let budget = max(4, Int(Double(memoryGB) * 0.72))
        return ModelCatalog.starterModels.filter {
            $0.backend == backend && $0.minimumRAMGB > 0 && $0.minimumRAMGB <= budget
        }
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
        catalogMessage = "Searching the full \(backend.title) registry…"
        do {
            let fetched = try await catalogService.models(for: backend, query: query.trimmingCharacters(in: .whitespacesAndNewlines))
            catalog = fetched
            catalogMessage = fetched.isEmpty ? "No registry matches. You can still download the exact identifier above." : "\(fetched.count) registry models found."
            if selectedModelID == nil { selectedModelID = recommended.first?.id ?? fetched.first?.id }
        } catch {
            catalog = ModelCatalog.starterModels.filter { $0.backend == backend }
            catalogMessage = error.localizedDescription
        }
    }

    func backendChanged() {
        selectedModelID = nil
        Task { await refreshCatalog() }
    }

    func download(_ model: LocalModel) {
        guard downloadTasks[model.id] == nil, !(states[model.id]?.isActive ?? false) else { return }
        if connect?.shouldUseStudio != true, model.backend == .ollama && ollama.executableURL() == nil {
            pendingOllamaInstall = model
            return
        }
        startDownload(model, installOllamaFirst: false)
    }

    func installOllamaAndContinue() {
        guard let model = pendingOllamaInstall else { return }
        pendingOllamaInstall = nil
        startDownload(model, installOllamaFirst: true)
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
        guard states[model.id] == .installed else { return }
        activeModel = model
        if let data = try? JSONEncoder().encode(model) {
            UserDefaults.standard.set(data, forKey: activeModelDefaultsKey)
        }
    }

    func response(
        to prompt: String,
        onDelta: @escaping @Sendable (_ delta: String, _ accumulated: String) async -> Void
    ) async throws -> String {
        guard let activeModel else {
            throw LocalModelError.invalidResponse("Choose an installed model in the model window first")
        }
        if connect?.shouldUseStudio == true, let connect {
            return try await connect.response(model: activeModel, prompt: prompt, onDelta: onDelta)
        }
        switch activeModel.backend {
        case .ollama:
            return try await ollama.streamChat(model: activeModel.identifier, prompt: prompt, onDelta: onDelta)
        case .lmStudio:
            return try await lmStudio.streamChat(model: activeModel.identifier, prompt: prompt, onDelta: onDelta)
        }
    }

    func shutdown() {
        downloadTasks.values.forEach { $0.cancel() }
        downloadTasks.removeAll()
        lmStudio.stopManagedProcesses()
        ollama.stopManagedServer()
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
            states[$0.id] = .installed
        }
        if activeModel == nil, let first = discovered.first {
            use(first)
        }
        if !discovered.isEmpty { persistInstalledModels() }
    }

    private func discoverInstalledStudioModels() async {
        guard let connect, connect.shouldUseStudio,
              let remote = try? await connect.installedStudioModels() else { return }
        let discovered = remote.map {
            LocalModel(
                customIdentifier: $0.identifier,
                backend: $0.runtime == .ollama ? .ollama : .lmStudio
            )
        }
        discovered.forEach {
            installedModelRecords[$0.id] = $0
            studioModelIDs.insert($0.id)
            states[$0.id] = .installed
        }
        if activeModel == nil, let first = discovered.first { use(first) }
        if !discovered.isEmpty { persistInstalledModels() }
    }

    private func startDownload(_ model: LocalModel, installOllamaFirst: Bool) {
        states[model.id] = .preparing("Preparing \(model.backend.title)…")
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let useStudio = connect?.shouldUseStudio == true
                if installOllamaFirst, !useStudio {
                    states[model.id] = .preparing("Installing the official Ollama app…")
                    try await ollama.installOfficialMacApp()
                }
                if useStudio, let connect {
                    states[model.id] = .preparing("Sending download to Mac Studio…")
                    try await connect.pullModel(model) { update in
                        await self.apply(update, to: model)
                    }
                    studioModelIDs.insert(model.id)
                } else {
                    switch model.backend {
                    case .ollama:
                        try await ollama.pull(model: model.identifier) { [weak self] update in
                            Task { @MainActor in self?.apply(update, to: model) }
                        }
                    case .lmStudio:
                        try await lmStudio.download(model) { [weak self] update in
                            Task { @MainActor in self?.apply(update, to: model) }
                        }
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

    private func apply(_ update: ModelDownloadProgress, to model: LocalModel) {
        states[model.id] = .downloading(progress: update.fraction, completedBytes: update.completedBytes, totalBytes: update.totalBytes, status: update.status)
    }

    private func persistInstalledModels() {
        let models = installedModelRecords.values.sorted(by: { $0.id < $1.id })
        UserDefaults.standard.set(models.map(\.id), forKey: installedDefaultsKey)
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: installedModelsDefaultsKey)
        }
        UserDefaults.standard.set(studioModelIDs.sorted(), forKey: studioModelsDefaultsKey)
    }
}
