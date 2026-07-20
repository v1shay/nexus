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
    case parakeetEndpoint

    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleSpeech: "Apple Speech"
        case .parakeetEndpoint: "NVIDIA Parakeet (local endpoint)"
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
    static func instant(for prompt: String) -> String {
        let normalized = prompt.lowercased()
        let options: [String]
        if normalized.contains("remember") || normalized.contains("my ") || normalized.contains("i ") {
            options = ["Searching the archives…", "Replaying old records…", "Checking your vault…", "Following the memory trail…"]
        } else if normalized.contains("current") || normalized.contains("latest") || normalized.contains("news") || normalized.contains("weather") || normalized.contains("find") {
            options = ["Scanning the horizon…", "Chasing the signal…", "Tracking that down…", "Surveying the field…"]
        } else if normalized.contains("code") || normalized.contains("debug") || normalized.contains("build") {
            options = ["Tinkering with that…", "Tracing the circuitry…", "Inspecting the machinery…", "Patching the matrix…"]
        } else if normalized.contains("math") || normalized.contains("calculate") || normalized.contains("compare") {
            options = ["Running the numbers…", "Testing the angles…", "Reading the figures…", "Calibrating the math…"]
        } else if normalized.contains("write") || normalized.contains("create") || normalized.contains("draft") {
            options = ["Shaping that up…", "Assembling the pieces…", "Warming up the workshop…", "Sketching the blueprint…"]
        } else if normalized.contains("explain") || normalized.contains("why") || normalized.contains("how") {
            options = ["Piecing that together…", "Unpacking the gears…", "Mapping the idea…", "Looking through my neural nets…"]
        } else {
            options = ["Looking into that…", "Reading the room…", "Spinning up a thought…", "Following the thread…"]
        }
        // `abs(Int.min)` traps. Converting through UInt keeps the stable choice
        // while making this hot path safe for every possible String hash.
        let index = Int(UInt(bitPattern: prompt.hashValue) % UInt(options.count))
        return options[index]
    }

    static func prompt(for request: String) -> [NexusChatMessage] {
        [
            .init(role: "system", content: """
            Generate one short Nex status line for the request. It must describe work beginning, feel like a capable whimsical JARVIS-style assistant, contain 2–8 words, and never mention models, tools, prompts, or completion. Use a concrete noun from the request only when it is unambiguous. Return only the status line.
            """),
            .init(role: "user", content: request)
        ]
    }

    static func sanitize(_ raw: String) -> String? {
        let line = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " `\"'“”.,:;")) ?? ""
        guard line.count >= 4, line.count <= 100,
              !line.localizedCaseInsensitiveContains("status") else { return nil }
        return line.hasSuffix("…") ? line : line + "…"
    }
}
