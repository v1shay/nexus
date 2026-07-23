import Foundation

/// The built-in, low-latency cloud chain. These identifiers and endpoints are
/// public configuration; only the provider API keys are stored in the local
/// Keychain. A missing key simply removes that provider from the chain.
enum NexusManagedCloudProvider: String, CaseIterable, Sendable {
    case inception
    case nvidiaNIM

    var title: String {
        switch self {
        case .inception: "Inception Mercury"
        case .nvidiaNIM: "NVIDIA NIM Kimi K2.6"
        }
    }

    var model: String {
        switch self {
        case .inception: "mercury-2"
        case .nvidiaNIM: "moonshotai/kimi-k2.6"
        }
    }

    var baseURL: URL {
        switch self {
        case .inception: URL(string: "https://api.inceptionlabs.ai/v1")!
        case .nvidiaNIM: URL(string: "https://integrate.api.nvidia.com/v1")!
        }
    }

    /// `nexus` is intentionally the Inception key's stable local name, as
    /// requested. The Keychain service keeps it distinct from account tokens
    /// and all other Nexus secrets.
    var keyAccount: String {
        switch self {
        case .inception: "nexus"
        case .nvidiaNIM: "nvidia.nim.v1"
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
    /// deterministic: Inception is the fast default and NVIDIA NIM Kimi K2.6
    /// is tried only when Inception rejects the request before streaming.
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
