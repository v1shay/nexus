import Foundation

/// The built-in, low-latency cloud chain. These identifiers and endpoints are
/// public configuration; only the two API keys are stored in the local
/// Keychain. A missing key simply removes that provider from the chain.
enum NexusManagedCloudProvider: String, CaseIterable, Sendable {
    case cerebras
    case inception

    var title: String {
        switch self {
        case .cerebras: "Cerebras GPT-OSS"
        case .inception: "Inception Mercury"
        }
    }

    var model: String {
        switch self {
        case .cerebras: "gpt-oss-120b"
        case .inception: "mercury-2"
        }
    }

    var baseURL: URL {
        switch self {
        case .cerebras: URL(string: "https://api.cerebras.ai/v1")!
        case .inception: URL(string: "https://api.inceptionlabs.ai/v1")!
        }
    }

    /// `nexus` is intentionally the Inception key's stable local name, as
    /// requested. The Keychain service keeps it distinct from account tokens
    /// and all other Nexus secrets.
    var keyAccount: String {
        switch self {
        case .cerebras: "cerebras.gpt-oss.v1"
        case .inception: "nexus"
        }
    }
}

struct NexusManagedCloudInferenceStore: Sendable {
    static let keychainService = "na.nexus.managed-inference"

    private let secrets: NexusSecretStore

    init(secrets: NexusSecretStore = NexusKeychainSecretStore(service: Self.keychainService)) {
        self.secrets = secrets
    }

    /// Ordered primary-to-secondary configurations. This is deliberately
    /// deterministic: Cerebras always gets the first attempt and Inception
    /// never runs unless Cerebras is unavailable or rejects the request before
    /// it begins streaming.
    func configurations() throws -> [(provider: NexusManagedCloudProvider, configuration: NexusAPIProviderConfiguration)] {
        try NexusManagedCloudProvider.allCases.compactMap { provider in
            guard let data = try secrets.data(for: provider.keyAccount),
                  let key = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else {
                return nil
            }
            return (
                provider,
                .init(
                    kind: .openAICompatible,
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
                    temperature: temperature,
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
