import AppKit
import Foundation
import SwiftUI

enum ModelBackend: String, CaseIterable, Identifiable, Codable, Sendable {
    case ollama
    case lmStudio

    var id: String { rawValue }
    var title: String { self == .ollama ? "Ollama" : "LM Studio" }
}

struct LocalModel: Identifiable, Hashable, Codable, Sendable {
    let name: String
    let identifier: String
    let family: String
    let backend: ModelBackend
    let minimumRAMGB: Int
    let quantization: String?

    var id: String { "\(backend.rawValue):\(identifier):\(quantization ?? "default")" }

    var supportsImageInput: Bool {
        let value = "\(name) \(identifier) \(family)".lowercased()
        let knownVisionFamilies = [
            "llava", "bakllava", "moondream", "minicpm-v", "minicpmv",
            "qwen2-vl", "qwen2.5-vl", "qwen3-vl", "qwen-vl", "vision",
            "llama3.2-vision", "llama 3.2 vision", "gemma3", "gemma 3"
        ]
        return knownVisionFamilies.contains(where: value.contains)
    }

    init(name: String, identifier: String, family: String, backend: ModelBackend, minimumRAMGB: Int, quantization: String? = nil) {
        self.name = name
        self.identifier = identifier
        self.family = family
        self.backend = backend
        self.minimumRAMGB = minimumRAMGB
        self.quantization = quantization
    }

    init(customIdentifier: String, backend: ModelBackend) {
        self.init(
            name: customIdentifier,
            identifier: customIdentifier,
            family: backend == .ollama ? "Ollama registry" : "LM Studio / Hugging Face",
            backend: backend,
            minimumRAMGB: ModelCatalog.estimatedMinimumRAM(for: customIdentifier),
            quantization: backend == .lmStudio ? "Q4_K_M" : nil
        )
    }

    /// Restores models saved by releases that persisted only the computed ID.
    static func restoring(legacyID: String) -> LocalModel? {
        if legacyID.hasPrefix("ollama:"), legacyID.hasSuffix(":default") {
            let identifier = String(legacyID.dropFirst("ollama:".count).dropLast(":default".count))
            return identifier.isEmpty ? nil : LocalModel(customIdentifier: identifier, backend: .ollama)
        }
        if legacyID.hasPrefix("lmStudio:"), legacyID.hasSuffix(":Q4_K_M") {
            let identifier = String(legacyID.dropFirst("lmStudio:".count).dropLast(":Q4_K_M".count))
            return identifier.isEmpty ? nil : LocalModel(customIdentifier: identifier, backend: .lmStudio)
        }
        return nil
    }
}

enum ModelProviderIdentity: String, Equatable, Sendable {
    case openAI
    case gemini
    case nvidia
    case qwen
    case mistral
    case deepSeek
    case gemma
    case ollama
    case genericLocal
}

/// One resolver owns provider artwork for model rows, API-provider controls,
/// the active-model banner, and the compact model-to-thinking handoff. Explicit
/// provider metadata wins; identifier inference exists for local runtimes that
/// expose only a model ID (for example Ollama's `gpt-oss:latest`).
enum ModelProviderResolver {
    static func identity(for model: LocalModel?) -> ModelProviderIdentity {
        guard let model else { return .genericLocal }

        if let identity = identity(fromProviderMetadata: model.family) {
            return identity
        }
        if let identity = identity(fromModelIdentifier: model.identifier) {
            return identity
        }
        return model.backend == .ollama ? .ollama : .genericLocal
    }

    static func identity(
        for kind: NexusAPIProviderKind,
        modelID: String,
        baseURL: String
    ) -> ModelProviderIdentity {
        if kind == .gemini { return .gemini }
        if kind == .nvidiaNIM { return .nvidia }
        if URL(string: baseURL)?.host?.lowercased() == "api.openai.com" {
            return .openAI
        }
        return identity(fromModelIdentifier: modelID) ?? .genericLocal
    }

    private static func identity(fromProviderMetadata provider: String) -> ModelProviderIdentity? {
        let normalized = provider
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        if normalized.contains("openai") { return .openAI }
        if normalized.contains("google"), normalized.contains("gemma") { return .gemma }
        if normalized.contains("gemini") { return .gemini }
        if normalized.contains("qwen") { return .qwen }
        if normalized.contains("mistral") { return .mistral }
        if normalized.contains("deepseek") { return .deepSeek }
        if normalized.contains("gemma") { return .gemma }
        return nil
    }

    private static func identity(fromModelIdentifier identifier: String) -> ModelProviderIdentity? {
        let value = identifier.lowercased()
        let namespace = value.split(separator: "/", maxSplits: 1).first.map(String.init)
        if namespace == "openai" { return .openAI }

        let tokens = value
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        if tokens.contains(where: { ["gpt", "chatgpt", "openai", "o1", "o3", "o4"].contains($0) }) {
            return .openAI
        }
        if tokens.contains(where: { $0.hasPrefix("gemini") }) { return .gemini }
        if tokens.contains(where: { $0.hasPrefix("qwen") }) { return .qwen }
        if tokens.contains(where: { $0.hasPrefix("mistral") || $0.hasPrefix("mixtral") }) { return .mistral }
        if tokens.contains(where: { $0.hasPrefix("deepseek") }) { return .deepSeek }
        if tokens.contains(where: { $0.hasPrefix("gemma") }) { return .gemma }
        return nil
    }
}

/// Resolves only the model artwork the user supplied. OpenAI/ChatGPT models
/// use the supplied `openai.webp` directly, with no app-created tile or
/// background.
enum ModelBrandArtwork {
    private static let downloadsDirectory = URL(fileURLWithPath: "/Users/vishayagarwal/Downloads", isDirectory: true)

    static let fallbackSystemName = "cpu"

    private static let chatGPTPNGBase64 = "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"

    static var embeddedChatGPTPNGData: Data? {
        Data(base64Encoded: chatGPTPNGBase64)
    }

    static func assetName(for identity: ModelProviderIdentity) -> String {
        switch identity {
        case .openAI: "openai.webp"
        case .gemini: "gemini-color.svg"
        case .nvidia: "nvidia-color.svg"
        case .qwen: "qwen-color.svg"
        case .mistral: "mistral-color.svg"
        case .deepSeek: "icons8-deepseek-94.png"
        case .gemma: "gemma-color.svg"
        case .ollama: "ollama-dark.svg"
        case .genericLocal: "icons8-linux-48.png"
        }
    }

    static func assetURL(for model: LocalModel?) -> URL {
        downloadsDirectory.appendingPathComponent(assetName(for: ModelProviderResolver.identity(for: model)))
    }

    static func image(for model: LocalModel?) -> NSImage? {
        image(for: ModelProviderResolver.identity(for: model))
    }

    static func image(for identity: ModelProviderIdentity) -> NSImage? {
        if let suppliedArtwork = NSImage(contentsOf: downloadsDirectory.appendingPathComponent(assetName(for: identity))) {
            return suppliedArtwork
        }
        if identity == .openAI, let data = embeddedChatGPTPNGData {
            return NSImage(data: data)
        }
        return nil
    }

    /// AppKit menu items do not consistently honor SwiftUI's resizable frame
    /// when the source is an SVG with CSS `em` dimensions. Rasterizing the
    /// supplied mark into a fixed square before it reaches a Picker prevents
    /// the giant provider-logo menu shown in the API sheet.
    static func icon(for identity: ModelProviderIdentity, size: CGFloat) -> NSImage? {
        guard let source = image(for: identity) else { return nil }
        let target = NSSize(width: size, height: size)
        let rendered = NSImage(size: target)
        rendered.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: target),
                    from: NSRect(origin: .zero, size: source.size),
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high])
        rendered.unlockFocus()
        rendered.isTemplate = false
        return rendered
    }
}

/// Raw model-family artwork for model rows and the compact prompt handoff.
/// It intentionally contains no fallback symbol or decorative container: a
/// missing user asset simply remains empty instead of being replaced by a tile.
struct ModelBrandIcon: View {
    let model: LocalModel?
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let image = ModelBrandArtwork.image(for: model) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: ModelBrandArtwork.fallbackSystemName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ModelProviderIcon: View {
    let identity: ModelProviderIdentity
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = ModelBrandArtwork.icon(for: identity, size: size) {
                Image(nsImage: image)
            } else {
                Image(systemName: ModelBrandArtwork.fallbackSystemName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum ModelDownloadState: Equatable {
    case idle
    case preparing(String)
    case downloading(progress: Double, completedBytes: Int64?, totalBytes: Int64?, status: String)
    case installed
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .downloading: true
        default: false
        }
    }
}

struct ModelDownloadProgress: Sendable {
    let completedBytes: Int64?
    let totalBytes: Int64?
    let status: String

    var fraction: Double {
        guard let completedBytes, let totalBytes, totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

enum ModelCatalog {
    static let starterModels: [LocalModel] = [
        .init(name: "Llama 3.2 1B", identifier: "llama3.2:1b", family: "Meta Llama", backend: .ollama, minimumRAMGB: 4),
        .init(name: "Llama 3.2 3B", identifier: "llama3.2:3b", family: "Meta Llama", backend: .ollama, minimumRAMGB: 6),
        .init(name: "Qwen 2.5 1.5B", identifier: "qwen2.5:1.5b", family: "Qwen", backend: .ollama, minimumRAMGB: 4),
        .init(name: "Qwen 3 4B", identifier: "qwen3:4b", family: "Qwen", backend: .ollama, minimumRAMGB: 8),
        .init(name: "Gemma 3 4B", identifier: "gemma3:4b", family: "Google Gemma", backend: .ollama, minimumRAMGB: 8),
        .init(name: "Qwen 3 8B", identifier: "qwen3:8b", family: "Qwen", backend: .ollama, minimumRAMGB: 12),
        .init(name: "Gemma 3 12B", identifier: "gemma3:12b", family: "Google Gemma", backend: .ollama, minimumRAMGB: 16),
        .init(name: "DeepSeek R1 14B", identifier: "deepseek-r1:14b", family: "DeepSeek", backend: .ollama, minimumRAMGB: 20),
        .init(name: "Mistral Small 24B", identifier: "mistral-small:24b", family: "Mistral", backend: .ollama, minimumRAMGB: 32),
        .init(name: "Qwen 3 8B GGUF", identifier: "lmstudio-community/Qwen3-8B-GGUF", family: "Qwen", backend: .lmStudio, minimumRAMGB: 12, quantization: "Q4_K_M"),
        .init(name: "Gemma 3 12B GGUF", identifier: "lmstudio-community/gemma-3-12b-it-GGUF", family: "Google Gemma", backend: .lmStudio, minimumRAMGB: 16, quantization: "Q4_K_M")
    ]

    static func estimatedMinimumRAM(for identifier: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)(\d+(?:\.\d+)?)\s*[be]"#),
              let match = expression.firstMatch(in: identifier, range: NSRange(identifier.startIndex..., in: identifier)),
              let range = Range(match.range(at: 1), in: identifier),
              let parameters = Double(identifier[range]) else { return 0 }
        return max(4, Int(ceil(parameters * 0.75)) + 2)
    }
}

actor ModelCatalogService {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func models(for backend: ModelBackend, query: String) async throws -> [LocalModel] {
        switch backend {
        case .ollama: try await ollamaModels(query: query)
        case .lmStudio: try await huggingFaceGGUFModels(query: query)
        }
    }

    private func ollamaModels(query: String) async throws -> [LocalModel] {
        var components = URLComponents(string: query.isEmpty ? "https://ollama.com/library" : "https://ollama.com/search")!
        components.queryItems = query.isEmpty ? [.init(name: "sort", value: "popular")] : [.init(name: "q", value: query)]
        let (data, response) = try await session.data(from: components.url!)
        try Self.requireSuccess(response)
        guard let html = String(data: data, encoding: .utf8) else { return [] }

        var identifiers = Self.matches(pattern: ##"href="/library/([^"#?]+)""##, in: html)
        if !query.isEmpty {
            let reserved = Set(["public", "docs", "blog", "download", "search", "pricing"])
            identifiers += Self.matches(pattern: #"href="/([A-Za-z0-9_.-]+/[A-Za-z0-9_.:-]+)""#, in: html)
                .filter { !reserved.contains($0.split(separator: "/").first.map(String.init) ?? "") }
        }
        return Array(Set(identifiers)).sorted().map {
            .init(name: $0.replacingOccurrences(of: "-", with: " ").capitalized, identifier: $0, family: "Ollama registry", backend: .ollama, minimumRAMGB: ModelCatalog.estimatedMinimumRAM(for: $0))
        }
    }

    private func huggingFaceGGUFModels(query: String) async throws -> [LocalModel] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            .init(name: "filter", value: "gguf"), .init(name: "sort", value: "downloads"),
            .init(name: "direction", value: "-1"), .init(name: "limit", value: "200")
        ]
        if !query.isEmpty { components.queryItems?.append(.init(name: "search", value: query)) }
        let (data, response) = try await session.data(from: components.url!)
        try Self.requireSuccess(response)
        return try JSONDecoder().decode([HuggingFaceModel].self, from: data).map {
            .init(name: $0.id.split(separator: "/").last.map(String.init) ?? $0.id, identifier: $0.id, family: "Hugging Face GGUF", backend: .lmStudio, minimumRAMGB: ModelCatalog.estimatedMinimumRAM(for: $0.id), quantization: "Q4_K_M")
        }
    }

    static func matches(pattern: String, in source: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw LocalModelError.catalogUnavailable }
    }
}

private struct HuggingFaceModel: Decodable { let id: String }

enum LocalModelError: LocalizedError, Equatable {
    case ollamaMissing, lmStudioMissing, catalogUnavailable, cancelled
    case installFailed(String), serverUnavailable(String), invalidResponse(String), downloadFailed(String), verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .ollamaMissing: "Ollama is not installed. Nexus can install the official app in your user Applications folder."
        case .lmStudioMissing: "LM Studio's `lms` tool was not found. Install LM Studio and open it once, then retry."
        case .installFailed(let detail): "Ollama installation failed: \(detail)"
        case .serverUnavailable(let runtime): "\(runtime) did not start its local server."
        case .invalidResponse(let detail): "The local model service returned an invalid response: \(detail)"
        case .downloadFailed(let detail): detail
        case .verificationFailed(let model): "The download finished, but \(model) was not found in the installed model list."
        case .catalogUnavailable: "The online model catalog could not be loaded. Exact model identifiers still work."
        case .cancelled: "Download canceled."
        }
    }
}
