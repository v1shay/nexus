import SwiftUI
import Foundation

struct ModelAggregatorView: View {
    @StateObject private var store = ModelStore()
    @State private var query = ""
    @State private var backend: ModelBackend = .ollama
    @State private var selectedID: String?

    private var results: [LocalModel] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return store.catalog }
        let catalogMatches = store.catalog.filter {
            $0.name.localizedCaseInsensitiveContains(normalized) ||
            $0.identifier.localizedCaseInsensitiveContains(normalized) ||
            $0.family.localizedCaseInsensitiveContains(normalized)
        }
        if catalogMatches.isEmpty {
            return [LocalModel(customIdentifier: normalized, backend: backend)]
        }
        return catalogMatches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Local models")
                    .font(.headline)
                Spacer()
                Text("(store.memoryGB) GB unified memory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("Search models or paste an Ollama tag / Hugging Face repo", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { installSelectedOrCustom() }
                Picker("Runtime", selection: $backend) {
                    ForEach(ModelBackend.allCases) { backend in
                        Text(backend.title).tag(backend)
                    }
                }
                .frame(width: 125)
            }

            Text("Nexus recommends")
                .font(.headline)
                .padding(.top, 4)

            List(selection: $selectedID) {
                Section("Fits this Mac") {
                    ForEach(store.recommended) { model in
                        ModelRow(model: model, state: store.downloads[model.id])
                            .tag(model.id)
                    }
                }

                Section(query.isEmpty ? "All catalog models" : "Search results") {
                    ForEach(results) { model in
                        ModelRow(model: model, state: store.downloads[model.id])
                            .tag(model.id)
                    }
                }
            }

            HStack {
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Download") { installSelectedOrCustom() }
                    .disabled(selectedModel == nil || store.isDownloading)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .onAppear { selectedID = store.recommended.first?.id }
    }

    private var selectedModel: LocalModel? {
        if let selectedID, let selected = (store.catalog + results).first(where: { $0.id == selectedID }) {
            return selected
        }
        let custom = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? nil : LocalModel(customIdentifier: custom, backend: backend)
    }

    private func installSelectedOrCustom() {
        guard let selectedModel else { return }
        store.install(selectedModel)
    }
}

private struct ModelRow: View {
    let model: LocalModel
    let state: DownloadState?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text("\(model.backend.title) · \(model.minimumRAMGB) GB minimum RAM · \(model.family)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(width: 85)
            case .complete:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .none:
                EmptyView()
            }
        }
    }
}

enum ModelBackend: String, CaseIterable, Identifiable {
    case ollama
    case lmStudio

    var id: String { rawValue }
    var title: String { self == .ollama ? "Ollama" : "LM Studio" }
    var executable: String { self == .ollama ? "ollama" : "lms" }
    var installVerb: String { self == .ollama ? "pull" : "get" }
}

struct LocalModel: Identifiable, Hashable {
    let id: String
    let name: String
    let identifier: String
    let family: String
    let backend: ModelBackend
    let minimumRAMGB: Int

    init(name: String, identifier: String, family: String, backend: ModelBackend, minimumRAMGB: Int) {
        self.id = "\(backend.rawValue):\(identifier)"
        self.name = name
        self.identifier = identifier
        self.family = family
        self.backend = backend
        self.minimumRAMGB = minimumRAMGB
    }

    init(customIdentifier: String, backend: ModelBackend) {
        self.init(name: customIdentifier, identifier: customIdentifier, family: "Custom model", backend: backend, minimumRAMGB: 0)
    }
}

enum DownloadState: Equatable {
    case downloading(Double)
    case complete
    case failed
}

@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published private(set) var statusMessage = "Select a model, then press Download."

    let memoryGB = max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))

    let catalog: [LocalModel] = [
        .init(name: "Llama 3.2 3B", identifier: "llama3.2:3b", family: "Meta Llama", backend: .ollama, minimumRAMGB: 4),
        .init(name: "Qwen 2.5 7B", identifier: "qwen2.5:7b", family: "Qwen", backend: .ollama, minimumRAMGB: 8),
        .init(name: "Qwen 3 8B", identifier: "qwen3:8b", family: "Qwen", backend: .ollama, minimumRAMGB: 10),
        .init(name: "Gemma 3 12B", identifier: "gemma3:12b", family: "Google Gemma", backend: .ollama, minimumRAMGB: 14),
        .init(name: "DeepSeek R1 14B", identifier: "deepseek-r1:14b", family: "DeepSeek", backend: .ollama, minimumRAMGB: 18),
        .init(name: "Mistral Small 24B", identifier: "mistral-small:24b", family: "Mistral", backend: .ollama, minimumRAMGB: 28),
        .init(name: "Llama 3.3 70B", identifier: "llama3.3:70b", family: "Meta Llama", backend: .ollama, minimumRAMGB: 48),
        .init(name: "Qwen 3 8B GGUF", identifier: "lmstudio-community/Qwen3-8B-GGUF", family: "Qwen", backend: .lmStudio, minimumRAMGB: 10),
        .init(name: "Gemma 3 12B GGUF", identifier: "lmstudio-community/gemma-3-12b-it-GGUF", family: "Google Gemma", backend: .lmStudio, minimumRAMGB: 14),
        .init(name: "Llama 3.3 70B GGUF", identifier: "lmstudio-community/Llama-3.3-70B-Instruct-GGUF", family: "Meta Llama", backend: .lmStudio, minimumRAMGB: 48)
    ]

    var recommended: [LocalModel] {
        let availableToModel = Int(Double(memoryGB) * 0.72)
        let models = catalog.filter { $0.minimumRAMGB > 0 && $0.minimumRAMGB <= availableToModel }
        return models.isEmpty ? catalog.filter { $0.minimumRAMGB == catalog.map(\.minimumRAMGB).min() } : models
    }

    var isDownloading: Bool {
        downloads.values.contains { if case .downloading = $0 { return true }; return false }
    }

    func install(_ model: LocalModel) {
        guard !isDownloading else { return }
        downloads[model.id] = .downloading(0)
        statusMessage = "Starting \(model.backend.title) download…"

        let store = self
        Task.detached(priority: .userInitiated) {
            let result = Self.runDownload(model) { progress in
                Task { @MainActor in
                    store.downloads[model.id] = .downloading(progress)
                    store.statusMessage = "Downloading \(model.name): \(Int(progress * 100))%"
                }
            }
            await MainActor.run {
                switch result {
                case .success:
                    store.downloads[model.id] = .complete
                    store.statusMessage = "\(model.name) is ready."
                case .failure(let error):
                    store.downloads[model.id] = .failed
                    store.statusMessage = error.localizedDescription
                }
            }
        }
    }

    nonisolated private static func runDownload(_ model: LocalModel, progress: @escaping (Double) -> Void) -> Result<Void, Error> {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [model.backend.executable, model.backend.installVerb, model.identifier]
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            let percentagePattern = try? NSRegularExpression(pattern: #"\b(\d{1,3})%"#)
            let range = NSRange(text.startIndex..., in: text)
            let matches = percentagePattern?.matches(in: text, range: range) ?? []
            if let last = matches.last,
               let valueRange = Range(last.range(at: 1), in: text),
               let value = Double(text[valueRange]) {
                progress(min(0.99, value / 100))
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            if process.terminationStatus == 0 {
                progress(1)
                return .success(())
            }
            return .failure(ModelDownloadError(message: "\(model.backend.title) could not download \(model.identifier). Check that the CLI is installed and the model identifier is valid."))
        } catch {
            return .failure(ModelDownloadError(message: "Could not run \(model.backend.executable). Install \(model.backend.title) first."))
        }
    }
}

extension ModelStore: @unchecked Sendable {}

private struct ModelDownloadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
