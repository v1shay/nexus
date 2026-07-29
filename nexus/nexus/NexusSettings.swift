import Foundation
import Combine
import SwiftUI

/// The shell uses material-backed, neutral smoked glass on every supported
/// Mac. Themes only change the angle and warmth of a restrained reflection;
/// they deliberately never recolor the entire application.
enum NexusGlassTheme: String, CaseIterable, Identifiable, Codable {
    case graphite
    case silver
    case warmGlass
    case frost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .graphite: "Graphite"
        case .silver: "Frost"
        case .warmGlass: "Sage"
        case .frost: "Onyx"
        }
    }

    var mainLight: Color {
        switch self {
        case .graphite: Color(white: 0.84)
        case .silver: Color(red: 0.89, green: 0.94, blue: 0.95)
        case .warmGlass: Color(red: 0.89, green: 0.92, blue: 0.86)
        case .frost: Color(white: 0.70)
        }
    }

    var sidebarLight: Color {
        switch self {
        case .graphite: Color(white: 0.58)
        case .silver: Color(red: 0.67, green: 0.76, blue: 0.79)
        case .warmGlass: Color(red: 0.65, green: 0.72, blue: 0.62)
        case .frost: Color(white: 0.46)
        }
    }
}

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

/// The duplex engine is deliberately independent from dictation and the main
/// response model.  A duplex model owns the live audio conversation, while
/// Nex's selected model continues to own tools, memory, and final answers.
///
/// PersonaPlex is intentionally *not* offered as a local Apple-silicon mode:
/// NVIDIA's reference runtime needs CUDA.  Selecting it is only meaningful
/// after a compatible CUDA host has been configured.
enum NexusDuplexVoiceEngine: String, CaseIterable, Identifiable, Codable {
    case disabled
    case moshiMLXQ4
    case personaPlexRemoteCUDA

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: "Off"
        case .moshiMLXQ4: "Moshi MLX (4-bit)"
        case .personaPlexRemoteCUDA: "PersonaPlex (remote CUDA)"
        }
    }

    var detail: String {
        switch self {
        case .disabled: "Use Nex's existing dictation and Piper response voice."
        case .moshiMLXQ4: "Runs Moshiko/Moshika Q4 locally on Apple silicon (about 8 GB)."
        case .personaPlexRemoteCUDA: "Requires a separately configured NVIDIA CUDA host; Mac Studio itself is not CUDA-capable."
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
    @Published var duplexVoiceEngine: NexusDuplexVoiceEngine { didSet { persist() } }
    @Published var personaPlexRemoteEndpoint: String { didSet { persist() } }
    @Published var glassTheme: NexusGlassTheme { didSet { persist() } }
    /// Hold Command once to enter a hands-free conversation. A double Command
    /// leaves the session and returns the gesture to its normal behavior.
    @Published var alwaysOnVoiceMode: Bool { didSet { persist() } }
    /// When the selected local model advertises vision support, attach one
    /// current-screen image to each new user request.
    @Published var shareScreenWithVisionModels: Bool { didSet { persist() } }
    /// Global, focused-field dictation. Accessibility permission is requested
    /// only when the user actually invokes the Option-Command shortcut.
    @Published var globalPasteDictationEnabled: Bool { didSet { persist() } }
    /// Empty keeps the automatic Jarvis/Piper discovery behavior. A non-empty
    /// value is the absolute path to a user-selected Piper ONNX model.
    @Published var piperVoiceModelPath: String { didSet { persist() } }
    /// Folders explicitly added through Settings in addition to Nexus Voice
    /// and Downloads. These are local paths; no voice is uploaded or copied.
    @Published var piperVoiceDirectories: [String] { didSet { persist() } }

    private let defaults = UserDefaults.standard
    private let key = "nexus.app.settings.v1"

    init() {
        let saved = defaults.dictionary(forKey: key) ?? [:]
        statusMode = NexusStatusGenerationMode(rawValue: saved["statusMode"] as? String ?? "") ?? .deterministic
        secondaryStatusModelID = saved["secondaryStatusModelID"] as? String ?? ""
        speechEngine = NexusSpeechEngine(rawValue: saved["speechEngine"] as? String ?? "") ?? .appleSpeech
        localSpeechEndpoint = saved["localSpeechEndpoint"] as? String ?? "http://127.0.0.1:8000/v1/audio/transcriptions"
        localSpeechModel = saved["localSpeechModel"] as? String ?? "nvidia/parakeet-tdt-0.6b-v2"
        duplexVoiceEngine = NexusDuplexVoiceEngine(rawValue: saved["duplexVoiceEngine"] as? String ?? "") ?? .disabled
        personaPlexRemoteEndpoint = saved["personaPlexRemoteEndpoint"] as? String ?? ""
        glassTheme = NexusGlassTheme(rawValue: saved["glassTheme"] as? String ?? "") ?? .graphite
        alwaysOnVoiceMode = saved["alwaysOnVoiceMode"] as? Bool ?? false
        // Screen context shipped disabled in early builds. Migrate that old
        // default to enabled once, while still honoring a deliberate choice
        // made in a current build.
        let screenContextVersion = saved["screenContextVersion"] as? Int ?? 0
        shareScreenWithVisionModels = screenContextVersion >= 2
            ? (saved["shareScreenWithVisionModels"] as? Bool ?? true)
            : true
        globalPasteDictationEnabled = saved["globalPasteDictationEnabled"] as? Bool ?? true
        piperVoiceModelPath = saved["piperVoiceModelPath"] as? String ?? ""
        piperVoiceDirectories = saved["piperVoiceDirectories"] as? [String] ?? []
    }

    private func persist() {
        defaults.set([
            "statusMode": statusMode.rawValue,
            "secondaryStatusModelID": secondaryStatusModelID,
            "speechEngine": speechEngine.rawValue,
            "localSpeechEndpoint": localSpeechEndpoint,
            "localSpeechModel": localSpeechModel,
            "duplexVoiceEngine": duplexVoiceEngine.rawValue,
            "personaPlexRemoteEndpoint": personaPlexRemoteEndpoint,
            "glassTheme": glassTheme.rawValue,
            "alwaysOnVoiceMode": alwaysOnVoiceMode,
            "shareScreenWithVisionModels": shareScreenWithVisionModels,
            "screenContextVersion": 2,
            "globalPasteDictationEnabled": globalPasteDictationEnabled,
            "piperVoiceModelPath": piperVoiceModelPath,
            "piperVoiceDirectories": piperVoiceDirectories
        ], forKey: key)
    }
}

/// Manages the official `moshi_mlx.local_web` server without using a shell.
/// The server is kept warm once started so its 4-bit weights are not reloaded
/// for every voice session.  It is intentionally a local, user-scoped process
/// and is stopped when Nexus quits.
@MainActor
final class NexusDuplexVoiceRuntime: ObservableObject {
    static let shared = NexusDuplexVoiceRuntime()

    enum State: Equatable {
        case stopped
        case installing
        case starting
        case ready
        case unavailable(String)
        case failed(String)

        var label: String {
            switch self {
            case .stopped: "Not running"
            case .installing: "Installing Moshi MLX…"
            case .starting: "Starting Moshi MLX…"
            case .ready: "Ready locally"
            case .unavailable(let message), .failed(let message): message
            }
        }
    }

    @Published private(set) var state: State = .stopped
    private var process: Process?
    private let port = 8998

    private init() {}

    var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    private var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Nexus/MoshiMLX", isDirectory: true)
    }

    private var virtualEnvironmentPython: URL {
        supportDirectory.appendingPathComponent("venv/bin/python")
    }

    func reconcile(with engine: NexusDuplexVoiceEngine, personaPlexEndpoint: String) async {
        switch engine {
        case .disabled:
            stop()
        case .moshiMLXQ4:
            guard isAppleSilicon else {
                state = .unavailable("Moshi MLX requires Apple silicon")
                return
            }
            guard FileManager.default.isExecutableFile(atPath: virtualEnvironmentPython.path) else {
                state = .unavailable("Install Moshi MLX to enable duplex voice")
                return
            }
            await startMoshiIfNeeded()
        case .personaPlexRemoteCUDA:
            stop()
            state = personaPlexEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .unavailable("PersonaPlex needs a configured CUDA host")
                : .unavailable("PersonaPlex remote bridge is not configured")
        }
    }

    /// Installs only after an explicit button press in Settings.  This avoids a
    /// surprise Python environment and the later Q4 model download appearing
    /// simply because Nexus launched.
    func installMoshiAndStart() async {
        guard isAppleSilicon else {
            state = .unavailable("Moshi MLX requires Apple silicon")
            return
        }
        do {
            state = .installing
            let bootstrapPython = try await resolvePython312()
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: virtualEnvironmentPython.path) {
                try await run(executable: bootstrapPython, arguments: ["-m", "venv", supportDirectory.appendingPathComponent("venv").path])
            }
            try await run(executable: virtualEnvironmentPython, arguments: ["-m", "pip", "install", "--disable-pip-version-check", "--upgrade", "pip"])
            try await run(executable: virtualEnvironmentPython, arguments: ["-m", "pip", "install", "--disable-pip-version-check", "moshi_mlx"])
            await startMoshiIfNeeded()
        } catch {
            state = .failed("Moshi MLX installation failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        state = .stopped
    }

    private func startMoshiIfNeeded() async {
        if await isHealthy() {
            state = .ready
            return
        }
        guard process == nil || process?.isRunning == false else {
            state = .starting
            return
        }
        guard FileManager.default.isExecutableFile(atPath: virtualEnvironmentPython.path) else {
            state = .unavailable("Install Moshi MLX to enable duplex voice")
            return
        }
        do {
            state = .starting
            let server = Process()
            let output = Pipe()
            server.executableURL = virtualEnvironmentPython
            server.arguments = [
                "-m", "moshi_mlx.local_web",
                "-q", "4",
                "--host", "127.0.0.1",
                "--no-browser",
                "--port", "\(port)"
            ]
            server.standardOutput = output
            server.standardError = output
            try server.run()
            process = server
            for _ in 0..<80 {
                if await isHealthy() {
                    state = .ready
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            state = .failed("Moshi MLX did not become ready on localhost:\(port)")
            server.terminate()
            process = nil
        } catch {
            state = .failed("Could not start Moshi MLX: \(error.localizedDescription)")
        }
    }

    private func isHealthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// `moshi_mlx` 0.3 currently supports the Python 3.12 MLX wheel on this
    /// app's Apple-silicon target.  Do not silently fall through to newer
    /// interpreters: that looks installed but fails later when pip resolves
    /// the package. Homebrew is used only after the user explicitly chooses
    /// "Install & start" in Settings.
    private func resolvePython312() async throws -> URL {
        if let existing = findPython312() { return existing }

        let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        guard FileManager.default.isExecutableFile(atPath: homebrew.path) else {
            throw NSError(
                domain: "NexusDuplexVoice",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Moshi MLX needs Python 3.12. Install Homebrew Python 3.12, then try again."]
            )
        }
        try await run(executable: homebrew, arguments: ["install", "python@3.12"])
        guard let installed = findPython312() else {
            throw NSError(
                domain: "NexusDuplexVoice",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Homebrew finished, but Python 3.12 was not found."]
            )
        }
        return installed
    }

    private func findPython312() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/python3.12",
            "/usr/local/bin/python3.12",
            "/opt/anaconda3/bin/python3.12"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func run(executable: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            let output = Pipe()
            task.executableURL = executable
            task.arguments = arguments
            task.standardOutput = output
            task.standardError = output
            task.terminationHandler = { task in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                if task.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(domain: "NexusDuplexVoice", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "Process exited with status \(task.terminationStatus)" : text]))
                }
            }
            do { try task.run() } catch { continuation.resume(throwing: error) }
        }
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
            You write the tiny first line Nex shows while work begins. Return
            exactly one natural, readable JARVIS-style status for the user’s
            request. It must be specific when the subject is clear, calm and
            capable, 2–9 words, and describe beginning work rather than an
            answer or completed work. Examples: "Mapping your project…",
            "Tracing that signal…", "Building the first pass…". Do not
            repeat the request, quote it, name a model or tool, explain your
            reasoning, or output markdown. Return only JSON:
            {"status":"…"}.
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
        guard line.count >= 4, line.count <= 110,
              (2...9).contains(words.count) else { return nil }
        // Small local models often answer with a good sentence that does not
        // start with an -ing verb. Preserve its inference instead of masking
        // it behind the old generic "Reviewing …" fallback.
        return line.hasSuffix("…") ? line : line + "…"
    }
}
