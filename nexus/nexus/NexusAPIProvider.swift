import Foundation

enum NexusAPIProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Kept for previously saved custom configurations and internal managed
    /// OpenAI-compatible providers. The API sheet intentionally exposes only
    /// the two verified presets below.
    case openAICompatible
    case gemini
    case nvidiaNIM

    var id: String { rawValue }
    static let supportedPresets: [Self] = [.gemini, .nvidiaNIM]

    var title: String {
        switch self {
        case .openAICompatible: "OpenAI-compatible"
        case .gemini: "Gemini"
        case .nvidiaNIM: "NVIDIA NIM"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: "https://api.openai.com/v1"
        // Gemini's OpenAI-compatible endpoint is deliberate. It is the path
        // that works with Nexus's streaming tool-plan and response transport.
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .nvidiaNIM: "https://integrate.api.nvidia.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAICompatible: ""
        case .gemini: "gemini-2.5-flash"
        case .nvidiaNIM: "openai/gpt-oss-120b"
        }
    }

    var keyAccount: String {
        switch self {
        case .openAICompatible: "primary-model-api-key.v1"
        case .gemini: "gemini-api-key.v1"
        case .nvidiaNIM: "nvidia.nim.v1"
        }
    }

    var helpText: String {
        switch self {
        case .gemini:
            "Gemini via Google’s OpenAI-compatible endpoint. Use a Google AI Studio API key."
        case .nvidiaNIM:
            "NVIDIA NIM GPT-OSS 120B via NVIDIA’s OpenAI-compatible inference endpoint."
        case .openAICompatible:
            "Custom OpenAI-compatible endpoint."
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
    @Published private(set) var connectionMessage: String?
    @Published private(set) var isTestingConnection = false

    private let defaults: UserDefaults
    private let secretStore: NexusSecretStore
    private let managedSecretStore: NexusSecretStore
    private let settingsKey = "nexus.api-provider.settings.v1"
    private let legacyGeminiKeyAccount = "primary-model-api-key.v1"

    init(
        defaults: UserDefaults = .standard,
        secretStore: NexusSecretStore = NexusKeychainSecretStore(service: "na.nexus.model-provider"),
        managedSecretStore: NexusSecretStore = NexusKeychainSecretStore(service: NexusManagedCloudInferenceStore.keychainService)
    ) {
        self.defaults = defaults
        self.secretStore = secretStore
        self.managedSecretStore = managedSecretStore
        let stored = defaults.dictionary(forKey: settingsKey)
        let storedBaseURL = stored?["baseURL"] as? String ?? ""
        let storedModel = stored?["model"] as? String ?? ""
        let restoredKind = NexusAPIProviderKind(rawValue: stored?["kind"] as? String ?? "") ?? .gemini
        // Earlier releases could save Gemini as a generic OpenAI-compatible
        // provider. Identify that specific legacy configuration so the user
        // lands on the working, named Gemini preset rather than a blank picker.
        let inferredKind: NexusAPIProviderKind
        if restoredKind == .openAICompatible,
           storedBaseURL.localizedCaseInsensitiveContains("generativelanguage.googleapis.com") || storedModel.lowercased().contains("gemini") {
            inferredKind = .gemini
        } else if restoredKind == .openAICompatible,
                  storedBaseURL.localizedCaseInsensitiveContains("integrate.api.nvidia.com") {
            inferredKind = .nvidiaNIM
        } else {
            inferredKind = restoredKind
        }
        self.enabled = stored?["enabled"] as? Bool ?? false
        self.kind = inferredKind
        // The visible Gemini and NIM choices are verified presets, not loose
        // endpoint fields. Normalize old saved native-Gemini URLs on launch.
        self.baseURL = inferredKind == .openAICompatible
            ? (storedBaseURL.isEmpty ? inferredKind.defaultBaseURL : storedBaseURL)
            : inferredKind.defaultBaseURL
        self.model = inferredKind == .openAICompatible
            ? (storedModel.isEmpty ? inferredKind.defaultModel : storedModel)
            : inferredKind.defaultModel
        self.savedKey = false
        self.savedKey = (try? self.keyData(for: inferredKind)) != nil
        if inferredKind != .openAICompatible { persist() }
    }

    func selectKind(_ newKind: NexusAPIProviderKind, replacing previous: NexusAPIProviderKind) {
        kind = newKind
        baseURL = newKind.defaultBaseURL
        model = newKind.defaultModel
        savedKey = (try? keyData(for: newKind)) != nil
        errorMessage = nil
        connectionMessage = nil
    }

    func save() throws {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else { throw LocalModelError.invalidResponse("Enter an API model ID") }
        guard URL(string: normalizedBaseURL()) != nil else {
            throw LocalModelError.invalidResponse("Enter a valid API base URL")
        }
        if !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try keyStore(for: kind).set(Data(apiKeyInput.utf8), for: kind.keyAccount)
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
        guard let data = try keyData(for: kind),
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

    /// Saves the current configuration and verifies that the provider streams
    /// a real response. This is deliberately local to the settings screen so
    /// a bad endpoint/key is discovered before it is placed in the fallback
    /// chain.
    func testConnection() async {
        connectionMessage = nil
        do {
            try save()
            let configuration = try configuration()
            isTestingConnection = true
            defer { isTestingConnection = false }
            _ = try await NexusAPIProviderClient.streamChat(
                configuration: configuration,
                messages: [.init(role: "user", content: "Reply with exactly: Nexus API connection verified")],
                temperature: 0,
                maximumTokens: 32
            ) { _, _ in }
            connectionMessage = "Connected — streaming verified"
            errorMessage = nil
        } catch {
            recordError(error)
        }
    }

    private func normalizedBaseURL() -> String {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return kind.defaultBaseURL }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func keyStore(for provider: NexusAPIProviderKind) -> NexusSecretStore {
        provider == .nvidiaNIM ? managedSecretStore : secretStore
    }

    private func keyData(for provider: NexusAPIProviderKind) throws -> Data? {
        if let data = try keyStore(for: provider).data(for: provider.keyAccount), !data.isEmpty {
            return data
        }
        // Migrate the earlier single Gemini field once, without exposing or
        // duplicating the secret outside Keychain.
        guard provider == .gemini,
              let legacy = try secretStore.data(for: legacyGeminiKeyAccount), !legacy.isEmpty else {
            return nil
        }
        try secretStore.set(legacy, for: provider.keyAccount)
        return legacy
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
    private static let inferenceRequestTimeout: TimeInterval = 7 * 24 * 60 * 60
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
        struct GenerationConfig: Encodable {
            struct ThinkingConfig: Encodable {
                let thinkingBudget: Int
            }

            let temperature: Double?
            let maxOutputTokens: Int?
            let thinkingConfig: ThinkingConfig?

            enum CodingKeys: String, CodingKey {
                case temperature
                case maxOutputTokens = "maxOutputTokens"
                case thinkingConfig
            }
        }
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
        case .openAICompatible, .nvidiaNIM:
            try await openAICompatible(configuration, messages, temperature, maximumTokens, onDelta)
        case .gemini:
            // The configured Gemini preset is Google's OpenAI-compatible API.
            // Keep native Gemini support for callers that supply the native
            // base URL programmatically.
            if isGeminiOpenAICompatibleEndpoint(configuration.baseURL) {
                try await openAICompatible(configuration, messages, temperature, maximumTokens, onDelta)
            } else {
                try await gemini(configuration, messages, temperature, maximumTokens, onDelta)
            }
        }
    }

    private static func isGeminiOpenAICompatibleEndpoint(_ url: URL) -> Bool {
        url.host?.localizedCaseInsensitiveCompare("generativelanguage.googleapis.com") == .orderedSame
            && url.path.lowercased().hasSuffix("/openai")
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
        request.timeoutInterval = inferenceRequestTimeout
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
        try await requireSuccess(response, bytes: bytes, provider: "API")
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
        request.timeoutInterval = inferenceRequestTimeout
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
            // Gemini 2.5 Flash reserves a hidden thinking budget by default.
            // Nexus does not surface that hidden chain of thought and users can
            // explicitly enable visible thinking only for a supporting local
            // model, so leave Gemini's invisible budget at zero. This also
            // prevents a small planning request from spending its entire token
            // limit before it produces the required JSON plan.
            generationConfig: .init(
                temperature: temperature,
                maxOutputTokens: maximumTokens,
                thinkingConfig: configuration.model.hasPrefix("gemini-2.5")
                    ? .init(thinkingBudget: 0)
                    : nil
            )
        ))
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await requireSuccess(response, bytes: bytes, provider: "Gemini")
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

    private static func requireSuccess(
        _ response: URLResponse,
        bytes: URLSession.AsyncBytes,
        provider: String
    ) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelError.invalidResponse("\(provider) returned an invalid response")
        }
        guard !(200..<300).contains(http.statusCode) else { return }

        var body = ""
        for try await line in bytes.lines {
            body += line
            if body.count >= 2_000 { break }
        }
        let providerMessage: String? = {
            guard let data = body.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: data).error.message
        }()
        throw LocalModelError.invalidResponse(providerMessage ?? "\(provider) HTTP \(http.statusCode)")
    }

    private struct ProviderErrorEnvelope: Decodable {
        struct APIError: Decodable { let message: String }
        let error: APIError
    }

    private static func completed(_ raw: String, provider: String) throws -> String {
        let answer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw LocalModelError.invalidResponse("\(provider) returned an empty answer") }
        return answer
    }
}
