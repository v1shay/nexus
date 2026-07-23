import Foundation

/// Keeps the real cloud-chain failure visible if the final local fallback also
/// fails. Without this, a user sees only an unrelated Ollama/LM Studio error
/// and cannot tell which cloud fallbacks were attempted.
struct NexusInferenceFallbackError: LocalizedError {
    let cloudMessage: String
    let localError: Error

    var errorDescription: String? {
        "Cloud route failed: \(cloudMessage) Local fallback also failed: \(localError.localizedDescription)"
    }
}
