import Foundation

/// Keeps paid-provider routing explicit and testable. Cloud providers are used
/// only after the user explicitly selects one. Every cloud failure goes to the
/// currently selected local runtime; Nexus never silently starts a paid cloud
/// chain just because credentials happen to be present in Keychain.
enum NexusCloudRoutingPolicy {
    static func usesAutomaticCloudChain(apiProviderIsExplicitlyEnabled: Bool) -> Bool {
        false
    }
}

/// The built-in, low-latency cloud chain. These identifiers and endpoints are
/// public configuration; only the provider API keys are stored in the local
/// Keychain. A missing key simply removes that provider from the chain.
enum NexusManagedCloudProvider: String, CaseIterable, Sendable {
    case inception
    case nvidiaNIM
    case gemini
    case groq

    var title: String {
        switch self {
        case .inception: "Inception Mercury"
        case .nvidiaNIM: "NVIDIA NIM GPT-OSS"
        case .gemini: "Gemini"
        case .groq: "Groq"
        }
    }

    var model: String {
        switch self {
        case .inception: "mercury-2"
        // Kimi K2.6 is listed by NVIDIA's model catalogue for this account,
        // but its inference deployment currently returns a provider-side 404
        // before producing a token. GPT-OSS 120B is verified against the same
        // NIM key and is therefore the safe managed route. Keep the provider
        // separate so Kimi can be re-enabled once NVIDIA provisions it.
        case .nvidiaNIM: "openai/gpt-oss-120b"
        case .gemini: NexusAPIProviderKind.gemini.defaultModel
        case .groq: NexusAPIProviderKind.groq.defaultModel
        }
    }

    var baseURL: URL {
        switch self {
        case .inception: URL(string: "https://api.inceptionlabs.ai/v1")!
        case .nvidiaNIM: URL(string: "https://integrate.api.nvidia.com/v1")!
        case .gemini: URL(string: NexusAPIProviderKind.gemini.defaultBaseURL)!
        case .groq: URL(string: NexusAPIProviderKind.groq.defaultBaseURL)!
        }
    }

    /// `nexus` is intentionally the Inception key's stable local name, as
    /// requested. The Keychain service keeps it distinct from account tokens
    /// and all other Nexus secrets.
    var keyAccount: String {
        switch self {
        case .inception: "nexus"
        case .nvidiaNIM: "nvidia.nim.v1"
        case .gemini: NexusAPIProviderKind.gemini.keyAccount
        case .groq: NexusAPIProviderKind.groq.keyAccount
        }
    }

    var apiProviderKind: NexusAPIProviderKind {
        switch self {
        case .inception: .openAICompatible
        case .nvidiaNIM: .nvidiaNIM
        case .gemini: .gemini
        case .groq: .groq
        }
    }

    /// Inception and NIM historically kept their managed credentials in a
    /// separate Keychain service. User-selected API providers use the normal
    /// model-provider service, and the automatic chain reads those keys
    /// without copying them anywhere else.
    var usesManagedKeychain: Bool {
        switch self {
        case .inception, .nvidiaNIM: true
        case .gemini, .groq: false
        }
    }
}

struct NexusManagedCloudInferenceStore: Sendable {
    static let keychainService = "na.nexus.managed-inference"

    private let standardSecrets: NexusSecretStore
    private let managedSecrets: NexusSecretStore

    init(
        secrets: NexusSecretStore? = nil,
        standardSecrets: NexusSecretStore = NexusKeychainSecretStore(service: "na.nexus.model-provider"),
        managedSecrets: NexusSecretStore = NexusKeychainSecretStore(service: Self.keychainService)
    ) {
        // A single injected store preserves deterministic unit tests while
        // production keeps previously saved keys in their respective service.
        self.standardSecrets = secrets ?? standardSecrets
        self.managedSecrets = secrets ?? managedSecrets
    }

    /// Ordered primary-to-secondary configurations. This is deliberately
    /// deterministic: Inception is the fast default and the verified NVIDIA
    /// GPT-OSS deployment is tried only when Inception rejects the request
    /// before streaming.
    func configurations() throws -> [(provider: NexusManagedCloudProvider, configuration: NexusAPIProviderConfiguration)] {
        try NexusManagedCloudProvider.allCases.compactMap { provider in
            let secrets = provider.usesManagedKeychain ? managedSecrets : standardSecrets
            guard let data = try secrets.data(for: provider.keyAccount),
                  let key = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else {
                return nil
            }
            return (
                provider,
                .init(
                    kind: provider.apiProviderKind,
                    baseURL: provider.baseURL,
                    model: provider.model,
                    apiKey: key
                )
            )
        }
    }
}

enum NexusManagedCloudInferenceError: LocalizedError {
    case allProvidersFailed([String])
    case interruptedStream(provider: NexusManagedCloudProvider, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .allProvidersFailed(let failures):
            "Cloud inference is unavailable: \(failures.joined(separator: " • "))"
        case .interruptedStream(let provider, let underlying):
            "\(provider.title) stopped after it had started responding: \(underlying.localizedDescription)"
        }
    }
}

private actor NexusCloudStreamStart {
    private var didReceiveDelta = false

    func markStarted() { didReceiveDelta = true }
    func started() -> Bool { didReceiveDelta }
}

struct NexusManagedCloudInferenceResponse: Sendable {
    let provider: NexusManagedCloudProvider
    let text: String
}

enum NexusManagedCloudInferenceClient {
    static func streamChat(
        attempts: [(provider: NexusManagedCloudProvider, configuration: NexusAPIProviderConfiguration)],
        messages: [NexusChatMessage],
        temperature: Double?,
        maximumTokens: Int?,
        onProviderAttempt: @escaping @Sendable (NexusManagedCloudProvider) async -> Void = { _ in },
        onDelta: @escaping @Sendable (String, String) async -> Void
    ) async throws -> NexusManagedCloudInferenceResponse {
        var failures: [String] = []

        for attempt in attempts {
            let streamStart = NexusCloudStreamStart()
            do {
                // The UI must describe the provider actually receiving this
                // request, rather than merely the first configured provider.
                await onProviderAttempt(attempt.provider)
                let text = try await NexusAPIProviderClient.streamChat(
                    configuration: attempt.configuration,
                    messages: messages,
                    // Mercury rejects temperatures below 0.5. Supplying its
                    // supported deterministic floor prevents a warning-only
                    // completion from consuming the small planning budget.
                    temperature: attempt.provider == .inception
                        ? max(temperature ?? 0.5, 0.5)
                        : temperature,
                    maximumTokens: maximumTokens
                ) { delta, accumulated in
                    await streamStart.markStarted()
                    await onDelta(delta, accumulated)
                }
                return .init(provider: attempt.provider, text: text)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Once visible text has been emitted, silently switching to a
                // second model would splice two answers together. Surface that
                // honest failure instead of corrupting the user's response.
                if await streamStart.started() {
                    throw NexusManagedCloudInferenceError.interruptedStream(provider: attempt.provider, underlying: error)
                }
                failures.append("\(attempt.provider.title): \(error.localizedDescription)")
            }
        }

        throw NexusManagedCloudInferenceError.allProvidersFailed(failures)
    }
}
