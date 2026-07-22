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
    /// A status is presentation-only. It must never decide which tools run or
    /// alter the primary-model request; the actual tool planner still owns
    /// that decision. This tiny local classifier simply makes the first line
    /// useful before either model has emitted a token.
    enum Category: String, Sendable {
        case code
        case tool
        case question
    }

    private static let codeSignals = [
        "code", "coding", "build", "create", "implement", "debug", "fix",
        "refactor", "script", "app", "website", "web site", "game", "swift",
        "python", "javascript", "typescript", "html", "css"
    ]
    private static let toolSignals = [
        "search", "look up", "find", "latest", "current", "today", "tomorrow",
        "news", "weather", "price", "stock", "memory", "remember", "forget",
        "obsidian", "previous", "last project", "earlier chat", "school schedule"
    ]

    private static let lines: [Category: [String]] = [
        .code: [
            "Coding that for you now, Sir…",
            "Building that now, Sir…",
            "Tinkering with that now, Sir…",
            "Engineering that for you, Sir…"
        ],
        .tool: [
            "Getting that for you now, Sir…",
            "Tracking that down now, Sir…",
            "Checking the archives, Sir…",
            "Pulling that signal now, Sir…"
        ],
        .question: [
            "Answering that for you now, Sir…",
            "Running that through the circuits, Sir…",
            "Parsing that now, Sir…",
            "Connecting the dots, Sir…"
        ]
    ]

    static let fallback = "Working on that now, Sir…"

    static func status(for request: String) -> String {
        let category = classify(request)
        let choices = lines[category] ?? [fallback]
        return choices[stableIndex(for: request, count: choices.count)]
    }

    static func classify(_ request: String) -> Category {
        let normalized = request.lowercased()
        if codeSignals.contains(where: normalized.contains) { return .code }
        if toolSignals.contains(where: normalized.contains) { return .tool }
        return .question
    }

    private static func stableIndex(for request: String, count: Int) -> Int {
        guard count > 1 else { return 0 }
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in request.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }

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
