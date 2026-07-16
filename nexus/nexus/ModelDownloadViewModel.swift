import Foundation

@MainActor
final class ModelDownloadViewModel: ObservableObject {
    @Published var query = ""
    @Published var backend: ModelBackend = .ollama
    @Published var selectedModelID: String?
    @Published private(set) var catalog: [LocalModel] = []
    @Published private(set) var states: [String: ModelDownloadState] = [:]
    @Published private(set) var catalogMessage = "Loading the model registry…"
    @Published var pendingOllamaInstall: LocalModel?

    let memoryGB = max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))

    private let ollama: OllamaManager
    private let lmStudio: LMStudioManager
    private let catalogService: ModelCatalogService
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private let installedDefaultsKey = "nexus.installed-model-ids"

    init(ollama: OllamaManager = .init(), lmStudio: LMStudioManager = .init(), catalogService: ModelCatalogService = .init()) {
        self.ollama = ollama
        self.lmStudio = lmStudio
        self.catalogService = catalogService
        let persisted = UserDefaults.standard.stringArray(forKey: installedDefaultsKey) ?? []
        persisted.forEach { states[$0] = .installed }
        Task { await refreshCatalog() }
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
        let all = ModelCatalog.starterModels + catalog
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
        if model.backend == .ollama && ollama.executableURL() == nil {
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

    func shutdown() {
        downloadTasks.values.forEach { $0.cancel() }
        downloadTasks.removeAll()
        lmStudio.stopManagedProcesses()
        ollama.stopManagedServer()
    }

    private func startDownload(_ model: LocalModel, installOllamaFirst: Bool) {
        states[model.id] = .preparing("Preparing \(model.backend.title)…")
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                if installOllamaFirst {
                    states[model.id] = .preparing("Installing the official Ollama app…")
                    try await ollama.installOfficialMacApp()
                }
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
                states[model.id] = .installed
                persistInstalledModelIDs()
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

    private func persistInstalledModelIDs() {
        UserDefaults.standard.set(states.compactMap { $0.value == .installed ? $0.key : nil }, forKey: installedDefaultsKey)
    }
}
