import AVFoundation
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

/// Controls the compact selector shown when several Codex tasks are active.
/// Pets remain animated so concurrent work reads as a small live queue rather
/// than a static set of thumbnails.
enum NexusCodexTaskMarkStyle: String, CaseIterable, Identifiable, Codable {
    case codexMarks
    case pets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codexMarks: "Codex marks"
        case .pets: "Animated pets"
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
    case nemotronVoiceChatRemoteCUDA

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: "Off"
        case .moshiMLXQ4: "Moshi MLX (4-bit)"
        case .personaPlexRemoteCUDA: "PersonaPlex (remote CUDA)"
        case .nemotronVoiceChatRemoteCUDA: "Nemotron VoiceChat 11B (remote CUDA)"
        }
    }

    var detail: String {
        switch self {
        case .disabled: "Use Nex's existing dictation and Piper response voice."
        case .moshiMLXQ4: "Runs Moshiko/Moshika Q4 locally on Apple silicon (about 8 GB)."
        case .personaPlexRemoteCUDA: "Requires a separately configured NVIDIA CUDA host; Mac Studio itself is not CUDA-capable."
        case .nemotronVoiceChatRemoteCUDA: "Native full-duplex audio, barge-in, and function calls through NVIDIA's realtime CUDA server."
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
    @Published var nemotronVoiceChatRemoteEndpoint: String { didSet { persist() } }
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
    /// The compact multi-task selector can use the colored Codex logo or the
    /// installed animated pet artwork.
    @Published var codexTaskMarkStyle: NexusCodexTaskMarkStyle { didSet { persist() } }
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
        nemotronVoiceChatRemoteEndpoint = saved["nemotronVoiceChatRemoteEndpoint"] as? String ?? ""
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
        codexTaskMarkStyle = NexusCodexTaskMarkStyle(rawValue: saved["codexTaskMarkStyle"] as? String ?? "") ?? .codexMarks
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
            "nemotronVoiceChatRemoteEndpoint": nemotronVoiceChatRemoteEndpoint,
            "glassTheme": glassTheme.rawValue,
            "alwaysOnVoiceMode": alwaysOnVoiceMode,
            "shareScreenWithVisionModels": shareScreenWithVisionModels,
            "screenContextVersion": 2,
            "globalPasteDictationEnabled": globalPasteDictationEnabled,
            "codexTaskMarkStyle": codexTaskMarkStyle.rawValue,
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
    private var nemotronSession: NexusNemotronVoiceChatSession?
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

    func reconcile(
        with engine: NexusDuplexVoiceEngine,
        personaPlexEndpoint: String,
        nemotronVoiceChatEndpoint: String = ""
    ) async {
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
        case .nemotronVoiceChatRemoteCUDA:
            stop()
            state = nemotronVoiceChatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .unavailable("Configure the Nemotron VoiceChat CUDA endpoint in Settings")
                : .stopped
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
        nemotronSession?.stop()
        nemotronSession = nil
        process?.terminate()
        process = nil
        state = .stopped
    }

    func startNemotronVoiceChat(
        endpoint: String,
        tools: [NexRegisteredTool],
        onUserTranscript: @escaping @MainActor (String, Bool) async -> Void,
        onAssistantTranscript: @escaping @MainActor (String, Bool) async -> Void,
        onToolStatus: @escaping @MainActor (String) -> Void,
        executeTool: @escaping @MainActor (NexPrimaryToolPlan.Action) async throws -> NexJSONValue
    ) async -> Bool {
        guard let url = Self.nemotronRealtimeURL(from: endpoint) else {
            state = .unavailable("Enter the HTTPS or WSS address of the Nemotron VoiceChat server")
            return false
        }
        nemotronSession?.stop()
        let session = NexusNemotronVoiceChatSession(
            endpoint: url,
            tools: tools,
            onUserTranscript: onUserTranscript,
            onAssistantTranscript: onAssistantTranscript,
            onToolStatus: onToolStatus,
            executeTool: executeTool
        )
        nemotronSession = session
        state = .starting
        do {
            try await session.start()
            state = .ready
            return true
        } catch {
            session.stop()
            nemotronSession = nil
            state = .failed("Nemotron VoiceChat could not start: \(error.localizedDescription)")
            return false
        }
    }

    func stopNemotronVoiceChat() {
        nemotronSession?.stop()
        nemotronSession = nil
        if process == nil { state = .stopped }
    }

    private static func nemotronRealtimeURL(from raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased() else { return nil }
        switch scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.hasSuffix("v1/realtime") || path == "realtime"
            ? "/" + path
            : "/" + (path.isEmpty ? "v1/realtime" : path + "/v1/realtime")
        return components.url
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

/// Bridges the official Nemotron VoiceChat realtime protocol to Nexus's live
/// audio, transcript, and tool lifecycle. The CUDA server owns speech timing;
/// Nexus validates every requested tool against its already-live registry.
///
/// `AVAudioEngine` invokes input taps off the main actor. Keeping this small
/// converter owned by that serial audio callback avoids allocating a new
/// converter for every 80 ms audio frame.
private final class NexusNemotronPCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(source: AVAudioFormat) {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: source, to: target) else {
            return nil
        }
        self.target = target
        self.converter = converter
    }

    func convert(_ input: AVAudioPCMBuffer) -> Data {
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return Data() }
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            status.pointee = .haveData
            return input
        }
        guard error == nil, let samples = output.int16ChannelData?.pointee else { return Data() }
        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

@MainActor
final class NexusNemotronVoiceChatSession {
    private let endpoint: URL
    private let tools: [NexRegisteredTool]
    private let onUserTranscript: @MainActor (String, Bool) async -> Void
    private let onAssistantTranscript: @MainActor (String, Bool) async -> Void
    private let onToolStatus: @MainActor (String) -> Void
    private let executeTool: @MainActor (NexPrimaryToolPlan.Action) async throws -> NexJSONValue
    private let inputEngine = AVAudioEngine()
    private let outputEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var inputTapInstalled = false
    private var didReceiveSession = false
    private var sessionReadyContinuation: CheckedContinuation<Void, Error>?
    private var userTranscript = ""
    private var assistantTranscript = ""

    init(
        endpoint: URL,
        tools: [NexRegisteredTool],
        onUserTranscript: @escaping @MainActor (String, Bool) async -> Void,
        onAssistantTranscript: @escaping @MainActor (String, Bool) async -> Void,
        onToolStatus: @escaping @MainActor (String) -> Void,
        executeTool: @escaping @MainActor (NexPrimaryToolPlan.Action) async throws -> NexJSONValue
    ) {
        self.endpoint = endpoint
        self.tools = tools
        self.onUserTranscript = onUserTranscript
        self.onAssistantTranscript = onAssistantTranscript
        self.onToolStatus = onToolStatus
        self.executeTool = executeTool
    }

    func start() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NSError(domain: "NexusNemotronVoiceChat", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission is required for duplex voice."])
        }
        let task = URLSession.shared.webSocketTask(with: endpoint)
        socket = task
        task.resume()
        try configurePlayback()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        try await send(sessionConfiguration())
        try await waitForSessionUpdate()
        try configureCapture()
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        if inputTapInstalled {
            inputEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        inputEngine.stop()
        player.stop()
        outputEngine.stop()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        didReceiveSession = false
        sessionReadyContinuation?.resume(throwing: CancellationError())
        sessionReadyContinuation = nil
        userTranscript = ""
        assistantTranscript = ""
    }

    private func configurePlayback() throws {
        outputEngine.attach(player)
        outputEngine.connect(player, to: outputEngine.mainMixerNode, format: pcmFormat)
        outputEngine.prepare()
        try outputEngine.start()
        player.play()
    }

    private func configureCapture() throws {
        let node = inputEngine.inputNode
        let sourceFormat = node.outputFormat(forBus: 0)
        guard let converter = NexusNemotronPCMConverter(source: sourceFormat) else {
            throw NSError(domain: "NexusNemotronVoiceChat", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nexus could not configure 24 kHz voice capture."])
        }
        node.installTap(onBus: 0, bufferSize: 1_920, format: sourceFormat) { [weak self, converter] buffer, _ in
            let data = converter.convert(buffer)
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in try? await self?.send(["type": "input_audio_buffer.append", "event_id": UUID().uuidString, "audio": data.base64EncodedString()]) }
        }
        inputTapInstalled = true
        inputEngine.prepare()
        try inputEngine.start()
    }

    private func waitForSessionUpdate() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionReadyContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.sessionReadyContinuation != nil else { return }
                self.sessionReadyContinuation?.resume(throwing: NSError(
                    domain: "NexusNemotronVoiceChat",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "The VoiceChat server did not accept the realtime session in time."]
                ))
                self.sessionReadyContinuation = nil
            }
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                await handle(raw)
            } catch {
                if !Task.isCancelled {
                    sessionReadyContinuation?.resume(throwing: error)
                    sessionReadyContinuation = nil
                    onToolStatus("Nemotron VoiceChat connection closed")
                }
                return
            }
        }
    }

    private func handle(_ event: [String: Any]) async {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "session.created":
            didReceiveSession = true
        case "session.updated":
            didReceiveSession = true
            sessionReadyContinuation?.resume()
            sessionReadyContinuation = nil
            onToolStatus("Nemotron VoiceChat is listening")
        case "input_audio_buffer.speech_started":
            player.stop()
            player.play()
        case "conversation.item.input_audio_transcription.delta":
            if let text = event["delta"] as? String {
                userTranscript += text
                await onUserTranscript(userTranscript, false)
            }
        case "conversation.item.input_audio_transcription.completed":
            let text = event["transcript"] as? String ?? event["text"] as? String ?? userTranscript
            if !text.isEmpty { await onUserTranscript(text, true) }
            userTranscript = ""
        case "response.output_audio.delta":
            if let encoded = event["delta"] as? String, let data = Data(base64Encoded: encoded) { play(data) }
        case "response.output_audio_transcript.delta":
            if let text = event["delta"] as? String {
                assistantTranscript += text
                await onAssistantTranscript(assistantTranscript, false)
            }
        case "response.output_audio_transcript.done":
            let text = (event["transcript"] ?? event["text"] as Any?) as? String ?? assistantTranscript
            if !text.isEmpty { await onAssistantTranscript(text, true) }
            assistantTranscript = ""
        case "response.function_call_arguments.done":
            await handleToolCall(event)
        case "error":
            let message = event["message"] as? String ?? event["error"] as? String ?? "Nemotron VoiceChat reported an error"
            onToolStatus(message)
        default: break
        }
    }

    private func handleToolCall(_ event: [String: Any]) async {
        guard let name = event["name"] as? String,
              let callID = event["call_id"] as? String else { return }
        let arguments: [String: NexJSONValue]
        do {
            let raw = event["arguments"] as? String ?? "{}"
            let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
            arguments = try object.mapValues(Self.nexusValue)
            guard let tool = tools.first(where: { $0.name == name }) else { throw NexToolError.notFound(name) }
            try tool.schema.validate(arguments)
            onToolStatus("Using \(tool.application)…")
            let result = try await executeTool(.init(tool: name, arguments: arguments))
            try await send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID, "output": Self.resultString(result)]])
        } catch {
            try? await send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID, "output": "{\"error\":\"\(error.localizedDescription.replacingOccurrences(of: "\\\"", with: "'"))\"}"]])
        }
    }

    private func play(_ data: Data) {
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames), let output = buffer.int16ChannelData?.pointee else { return }
        buffer.frameLength = frames
        data.copyBytes(to: UnsafeMutableRawPointer(output).assumingMemoryBound(to: UInt8.self), count: data.count)
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func send(_ value: [String: Any]) async throws {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.data(data))
    }

    private func sessionConfiguration() -> [String: Any] {
        [
            "type": "session.update",
            "event_id": UUID().uuidString,
            "session": [
                "audio": ["input": ["format": ["type": "audio/pcm", "rate": 24_000]], "output": ["format": ["type": "audio/pcm", "rate": 24_000]]],
                "instructions": "You are Nexus in a natural live voice conversation. Use registered functions for external actions. While a tool runs, give a short natural on-hold acknowledgement. Never claim a tool succeeded until its function result arrives.",
                "tools": tools.map(Self.realtimeTool)
            ]
        ]
    }

    private static func realtimeTool(_ tool: NexRegisteredTool) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for (name, field) in tool.schema.fields where !field.deprecated {
            var schema: [String: Any] = ["type": jsonType(field.type)]
            if let description = field.description { schema["description"] = description }
            if !field.allowedValues.isEmpty { schema["enum"] = field.allowedValues }
            if let minimum = field.minimum { schema["minimum"] = minimum }
            if let maximum = field.maximum { schema["maximum"] = maximum }
            properties[name] = schema
            if field.required { required.append(name) }
        }
        return ["type": "function", "name": tool.name, "description": tool.description, "parameters": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }

    private static func jsonType(_ type: NexToolFieldType) -> String {
        switch type {
        case .string: "string"
        case .integer: "integer"
        case .number: "number"
        case .boolean: "boolean"
        case .stringArray, .array: "array"
        }
    }

    private static func nexusValue(_ value: Any) throws -> NexJSONValue {
        switch value {
        case let value as String: .string(value)
        case let value as NSNumber: CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [Any]: .array(try value.map(nexusValue))
        case let value as [String: Any]: .object(try value.mapValues(nexusValue))
        case is NSNull: .null
        default: throw NexToolError.executionFailed(code: "invalid_voice_tool_arguments", message: "VoiceChat supplied an unsupported tool argument.")
        }
    }

    private static func resultString(_ value: NexJSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "{\"error\":\"Could not encode tool result\"}" }
        return text
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
