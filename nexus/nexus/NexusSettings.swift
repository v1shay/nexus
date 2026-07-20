import Foundation
import Combine

enum NexusStatusGenerationMode: String, CaseIterable, Identifiable, Codable {
    case deterministic
    case primaryModel
    case secondaryModel

    var id: String { rawValue }
    var title: String {
        switch self {
        case .deterministic: "Instant"
        case .primaryModel: "Primary model"
        case .secondaryModel: "Status model"
        }
    }
}

enum NexusSpeechEngine: String, CaseIterable, Identifiable, Codable {
    case appleSpeech
    case parakeetLocal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .parakeetLocal: "Parakeet (local)"
        }
    }
}

@MainActor
final class NexusAppSettings: ObservableObject {
    @Published var statusMode: NexusStatusGenerationMode { didSet { persist() } }
    @Published var secondaryStatusModelID: String { didSet { persist() } }
    @Published var speechEngine: NexusSpeechEngine { didSet { persist() } }
    @Published var localSpeechEndpoint: String { didSet { persist() } }
    @Published var localSpeechModel: String { didSet { persist() } }

    private let defaults = UserDefaults.standard
    private let key = "nexus.app.settings.v1"

    init() {
        let saved = defaults.dictionary(forKey: key) ?? [:]
        statusMode = NexusStatusGenerationMode(rawValue: saved["statusMode"] as? String ?? "") ?? .deterministic
        secondaryStatusModelID = saved["secondaryStatusModelID"] as? String ?? ""
        speechEngine = NexusSpeechEngine(rawValue: saved["speechEngine"] as? String ?? "") ?? .appleSpeech
        localSpeechEndpoint = saved["localSpeechEndpoint"] as? String ?? "http://127.0.0.1:8000/v1/audio/transcriptions"
        localSpeechModel = saved["localSpeechModel"] as? String ?? "nvidia/parakeet-tdt-0.6b-v2"
    }

    private func persist() {
        defaults.set([
            "statusMode": statusMode.rawValue,
            "secondaryStatusModelID": secondaryStatusModelID,
            "speechEngine": speechEngine.rawValue,
            "localSpeechEndpoint": localSpeechEndpoint,
            "localSpeechModel": localSpeechModel
        ], forKey: key)
    }
}

/// Immediate, local status generation. This is deliberately separate from
/// tool routing so status never holds up the primary model or a tool call.
enum NexusStatusLineGenerator {
    /// The only synchronous fallback.  It deliberately carries no inferred
    /// meaning: all request-specific status text comes from the selected model.
    /// This avoids a second, keyword-based routing system that can disagree
    /// with the model's actual tool decision.
    static let fallback = "Thinking…"

    static func prompt(for request: String) -> [NexusChatMessage] {
        [
            .init(role: "system", content: """
            Generate one short Nex status line for the request. It must describe work beginning, not answer the request. Make it a specific, capable, slightly whimsical JARVIS-style phrase of 2–8 words. The first word must end in "ing" (for example: "Reviewing…", "Mapping…", "Checking…"). Use a concrete noun only when it is unambiguous. Never mention models, tools, prompts, implementation, or completion. Return only JSON: {"status":"…"}.
            """),
            .init(role: "user", content: request)
        ]
    }

    static func sanitize(_ raw: String) -> String? {
        let candidate: String
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = object["status"] as? String {
            candidate = status
        } else {
            candidate = raw
        }
        let line = candidate
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " `\"'“”.,:;")) ?? ""
        let words = line.split(whereSeparator: \.isWhitespace)
        guard line.count >= 4, line.count <= 100,
              (2...8).contains(words.count),
              !line.localizedCaseInsensitiveContains("status") else { return nil }
        if words.first?.lowercased().hasSuffix("ing") == true {
            return line.hasSuffix("…") ? line : line + "…"
        }
        // Some small local models return a concise inferred subject in
        // snake_case despite the requested surface form. Preserve that model
        // inference and supply only the grammatical beginning; no request
        // keywords or tool-routing rules are involved here.
        return "Reviewing \(line)…"
    }
}
