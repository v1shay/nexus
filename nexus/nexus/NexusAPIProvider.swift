import Foundation

enum NexusAPIProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAICompatible
    case gemini

    var id: String { rawValue }
    var title: String { self == .openAICompatible ? "OpenAI-compatible" : "Gemini" }
    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: "https://api.openai.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        }
    }
}

struct NexusAPIProviderConfiguration: Sendable {
    let kind: NexusAPIProviderKind
    let baseURL: URL
    let model: String
    let apiKey: String
}

/// Stores endpoint metadata locally and the actual provider secret in Keychain.
/// No API key is placed in UserDefaults, logs, the vault, or model messages.
@MainActor
final class NexusAPIProviderStore: ObservableObject {
    @Published var enabled: Bool
    @Published var kind: NexusAPIProviderKind
    @Published var baseURL: String
    @Published var model: String
    @Published var apiKeyInput = ""
    @Published private(set) var savedKey = false
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let secretStore: NexusSecretStore
    private let settingsKey = "nexus.api-provider.settings.v1"
    private let keyAccount = "primary-model-api-key.v1"

    init(
        defaults: UserDefaults = .standard,
        secretStore: NexusSecretStore = NexusKeychainSecretStore(service: "na.nexus.model-provider")
    ) {
        self.defaults = defaults
        self.secretStore = secretStore
        let stored = defaults.dictionary(forKey: settingsKey)
        self.enabled = stored?["enabled"] as? Bool ?? false
        self.kind = NexusAPIProviderKind(rawValue: stored?["kind"] as? String ?? "") ?? .openAICompatible
        self.baseURL = stored?["baseURL"] as? String ?? NexusAPIProviderKind.openAICompatible.defaultBaseURL
        self.model = stored?["model"] as? String ?? ""
        self.savedKey = stored?["hasKey"] as? Bool ?? false
    }

    func selectKind(_ newKind: NexusAPIProviderKind) {
        let previous = kind
        kind = newKind
        if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL == previous.defaultBaseURL {
            baseURL = newKind.defaultBaseURL
        }
    }

    func save() throws {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else { throw LocalModelError.invalidResponse("Enter an API model ID") }
        guard URL(string: normalizedBaseURL()) != nil else {
            throw LocalModelError.invalidResponse("Enter a valid API base URL")
        }
        if !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try secretStore.set(Data(apiKeyInput.utf8), for: keyAccount)
            apiKeyInput = ""
            savedKey = true
        }
        guard savedKey else { throw LocalModelError.invalidResponse("Enter an API key") }
        persist()
        errorMessage = nil
    }

    func disable() {
        enabled = false
        persist()
    }

    func configuration() throws -> NexusAPIProviderConfiguration {
        guard enabled else { throw LocalModelError.invalidResponse("The API provider is not enabled") }
        guard let data = try secretStore.data(for: keyAccount),
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            savedKey = false
            persist()
            throw LocalModelError.invalidResponse("Add an API key in the model window")
        }
        guard let endpoint = URL(string: normalizedBaseURL()) else {
            throw LocalModelError.invalidResponse("Enter a valid API base URL")
        }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else { throw LocalModelError.invalidResponse("Enter an API model ID") }
        return .init(kind: kind, baseURL: endpoint, model: normalizedModel, apiKey: key)
    }

    func recordError(_ error: Error) { errorMessage = error.localizedDescription }

    private func normalizedBaseURL() -> String {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? kind.defaultBaseURL : value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func persist() {
        defaults.set([
            "enabled": enabled,
            "kind": kind.rawValue,
            "baseURL": normalizedBaseURL(),
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "hasKey": savedKey
        ], forKey: settingsKey)
    }
}

enum NexusAPIProviderClient {
    private struct OpenAIRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let stream: Bool
        let temperature: Double?
        let maxTokens: Int?
        enum CodingKeys: String, CodingKey { case model, messages, stream, temperature; case maxTokens = "max_tokens" }
    }

    private struct OpenAIEvent: Decodable {
        struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta }
        struct APIError: Decodable { let message: String }
        let choices: [Choice]?
        let error: APIError?
    }

    private struct GeminiRequest: Encodable {
        struct Part: Encodable { let text: String }
        struct Content: Encodable { let role: String?; let parts: [Part] }
        struct GenerationConfig: Encodable { let temperature: Double?; let maxOutputTokens: Int?; enum CodingKeys: String, CodingKey { case temperature; case maxOutputTokens = "maxOutputTokens" } }
        let systemInstruction: Content
        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    private struct GeminiEvent: Decodable {
        struct Candidate: Decodable { struct Content: Decodable { struct Part: Decodable { let text: String? }; let parts: [Part] }; let content: Content? }
        let candidates: [Candidate]?
        struct APIError: Decodable { let message: String }
        let error: APIError?
    }

    static func streamChat(
        configuration: NexusAPIProviderConfiguration,
        messages: [NexusChatMessage],
        temperature: Double?,
        maximumTokens: Int?,
        onDelta: @escaping @Sendable (String, String) async -> Void
    ) async throws -> String {
        switch configuration.kind {
        case .openAICompatible:
            try await openAICompatible(configuration, messages, temperature, maximumTokens, onDelta)
        case .gemini:
            try await gemini(configuration, messages, temperature, maximumTokens, onDelta)
        }
    }

    private static func openAICompatible(
        _ configuration: NexusAPIProviderConfiguration,
        _ messages: [NexusChatMessage],
        _ temperature: Double?,
        _ maximumTokens: Int?,
        _ onDelta: @escaping @Sendable (String, String) async -> Void
    ) async throws -> String {
        var url = configuration.baseURL
        if !url.path.hasSuffix("/chat/completions") { url.appendPathComponent("chat/completions") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(OpenAIRequest(
            model: configuration.model,
            messages: [.init(role: "system", content: NexusResponseInstructions.conciseSystemPrompt)]
                + messages.map { .init(role: $0.role, content: $0.content) },
            stream: true,
            temperature: temperature,
            maxTokens: maximumTokens
        ))
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try requireSuccess(response, provider: "API")
        var answer = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            let event = try JSONDecoder().decode(OpenAIEvent.self, from: data)
            if let error = event.error { throw LocalModelError.invalidResponse(error.message) }
            if let delta = event.choices?.first?.delta.content, !delta.isEmpty {
                answer += delta
                await onDelta(delta, answer)
            }
        }
        return try completed(answer, provider: "API")
    }

    private static func gemini(
        _ configuration: NexusAPIProviderConfiguration,
        _ messages: [NexusChatMessage],
        _ temperature: Double?,
        _ maximumTokens: Int?,
        _ onDelta: @escaping @Sendable (String, String) async -> Void
    ) async throws -> String {
        var url = configuration.baseURL
        url.appendPathComponent("models/\(configuration.model):streamGenerateContent")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "alt", value: "sse")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        let system = ([NexusResponseInstructions.conciseSystemPrompt]
            + messages.filter { $0.role == "system" }.map(\.content)).joined(separator: "\n\n")
        let contents = messages.filter { $0.role != "system" }.map {
            GeminiRequest.Content(role: $0.role == "assistant" ? "model" : "user", parts: [.init(text: $0.content)])
        }
        request.httpBody = try JSONEncoder().encode(GeminiRequest(
            systemInstruction: .init(role: nil, parts: [.init(text: system)]),
            contents: contents,
            generationConfig: .init(temperature: temperature, maxOutputTokens: maximumTokens)
        ))
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try requireSuccess(response, provider: "Gemini")
        var answer = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"), let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8) else { continue }
            let event = try JSONDecoder().decode(GeminiEvent.self, from: data)
            if let error = event.error { throw LocalModelError.invalidResponse(error.message) }
            for part in event.candidates?.first?.content?.parts ?? [] where !(part.text ?? "").isEmpty {
                let delta = part.text!
                answer += delta
                await onDelta(delta, answer)
            }
        }
        return try completed(answer, provider: "Gemini")
    }

    private static func requireSuccess(_ response: URLResponse, provider: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalModelError.invalidResponse("\(provider) HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
    }

    private static func completed(_ raw: String, provider: String) throws -> String {
        let answer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw LocalModelError.invalidResponse("\(provider) returned an empty answer") }
        return answer
    }
}
