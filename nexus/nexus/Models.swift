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

/// Resolves only the model artwork the user has supplied.  These are deliberately
/// rendered as the source image—no app-created tile, circle, or background is
/// placed behind them.
enum ModelBrandArtwork {
    private static let downloadsDirectory = URL(fileURLWithPath: "/Users/vishayagarwal/Downloads", isDirectory: true)

    static func assetURL(for model: LocalModel?) -> URL {
        let modelText = [
            model?.name,
            model?.identifier,
            model?.family,
            model?.backend.rawValue
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        let assetName: String
        if modelText.contains("qwen") {
            assetName = "qwen-color.svg"
        } else if modelText.contains("mistral") {
            assetName = "mistral-color.svg"
        } else if modelText.contains("deepseek") {
            assetName = "icons8-deepseek-94.png"
        } else if modelText.contains("gemma") {
            assetName = "gemma-color.svg"
        } else if modelText.contains("ollama") {
            assetName = "ollama-dark.svg"
        } else {
            // The Linux mark is the requested neutral classification for any
            // local model without a dedicated family mark.
            assetName = "icons8-linux-48.png"
        }
        return downloadsDirectory.appendingPathComponent(assetName)
    }

    static func image(for model: LocalModel?) -> NSImage? {
        NSImage(contentsOf: assetURL(for: model))
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
                Color.clear
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
