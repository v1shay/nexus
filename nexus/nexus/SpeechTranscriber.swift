import AVFoundation
import FluidAudio
import Speech

final class SpeechTranscriber: NSObject, @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: .current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInputTap = false
    private var wantsRecording = false
    private var onUpdate: ((String) -> Void)?
    private var localRecordingURL: URL?
    private var localRecordingFile: AVAudioFile?
    private var localSessionID = UUID()
    private var parakeetManager: AsrManager?
    private var parakeetLoadingTask: Task<AsrManager, Error>?

    func start(
        engine: NexusSpeechEngine = .appleSpeech,
        onUpdate: @escaping (String) -> Void
    ) {
        wantsRecording = true
        self.onUpdate = onUpdate

        if engine == .parakeetLocal {
            startLocalParakeetRecording()
            return
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            beginRecording()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self, self.wantsRecording else { return }
                    if status == .authorized {
                        self.beginRecording()
                    } else {
                        self.onUpdate?("Speech recognition permission is required in System Settings.")
                    }
                }
            }
        case .denied, .restricted:
            onUpdate("Speech recognition permission is required in System Settings.")
        @unknown default:
            onUpdate("Speech recognition is unavailable on this Mac.")
        }
    }

    func stop() {
        wantsRecording = false
        if let localJob = stopRecording() {
            // Dismissal and shutdown intentionally discard endpoint audio.
            // A completed dictation turn uses `stopAndTranscribe()` instead.
            try? FileManager.default.removeItem(at: localJob.recording)
        }
    }

    /// Stops a local Parakeet recording and awaits its final transcript.
    /// Apple Speech remains streaming and therefore returns nil here.
    func stopAndTranscribe() async -> String? {
        wantsRecording = false
        guard let localJob = stopRecording() else { return nil }
        defer { try? FileManager.default.removeItem(at: localJob.recording) }
        do {
            return try await transcribe(recording: localJob.recording)
        } catch {
            onUpdate?("Local Parakeet transcription failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func beginRecording() {
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeInputTap()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasInputTap = true

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                DispatchQueue.main.async { self?.onUpdate?(text) }
            }
            if error != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.wantsRecording else { return }
                    self.onUpdate?("Speech recognition stopped unexpectedly.")
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            removeInputTap()
            onUpdate?("Nexus could not start the microphone.")
        }
    }

    private func removeInputTap() {
        guard hasInputTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        hasInputTap = false
    }

    private func startLocalParakeetRecording() {
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeInputTap()

        localSessionID = UUID()
        // Start model preparation in parallel with microphone capture. The
        // first run downloads Hugging Face CoreML weights; later runs reuse
        // the loaded ANE-backed model without an HTTP transcription service.
        Task { [weak self] in _ = try? await self?.preparedParakeetManager() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nex-dictation-\(localSessionID.uuidString).wav")
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        do {
            localRecordingFile = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            localRecordingURL = url
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                try? self?.localRecordingFile?.write(from: buffer)
            }
            hasInputTap = true
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            removeInputTap()
            localRecordingFile = nil
            localRecordingURL = nil
            onUpdate?("Nexus could not start local Parakeet dictation.")
        }
    }

    private struct LocalTranscriptionJob {
        let recording: URL
    }

    private func stopRecording() -> LocalTranscriptionJob? {
        if audioEngine.isRunning { audioEngine.stop() }
        removeInputTap()
        recognitionRequest?.endAudio()

        guard let recording = localRecordingURL else { return nil }
        localRecordingFile = nil
        localRecordingURL = nil
        return LocalTranscriptionJob(recording: recording)
    }

    private func preparedParakeetManager() async throws -> AsrManager {
        if let parakeetManager { return parakeetManager }
        if let parakeetLoadingTask { return try await parakeetLoadingTask.value }
        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.downloadAndLoad()
            let manager = AsrManager()
            try await manager.initialize(models: models)
            return manager
        }
        parakeetLoadingTask = task
        do {
            let manager = try await task.value
            parakeetManager = manager
            parakeetLoadingTask = nil
            return manager
        } catch {
            parakeetLoadingTask = nil
            throw error
        }
    }

    private func transcribe(recording: URL) async throws -> String {
        let manager = try await preparedParakeetManager()
        let result = try await manager.transcribe(recording, source: .microphone)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalizedErrorMessage("Parakeet returned an empty transcript.")
        }
        return result.text
    }
}
private struct LocalizedErrorMessage: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A small local wake-phrase listener used until Nex has a trained
/// openWakeWord model. It intentionally listens only for multi-word phrases:
/// bare “Nex”/“next” would produce far too many false activations in normal
/// conversation. The listener gives up the microphone before the existing
/// dictation transcriber starts, so the two AVAudioEngines never compete.
@MainActor
final class WakePhraseListener: NSObject {
    enum Phrase: String, CaseIterable {
        case heyNext = "hey next"
        case wakeUpNext = "wake up next"
    }

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: .current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInputTap = false
    private var wantsListening = false
    private var isTriggered = false
    private var restartTask: Task<Void, Never>?
    private var onDetected: ((Phrase) -> Void)?

    func start(onDetected: @escaping (Phrase) -> Void) {
        self.onDetected = onDetected
        wantsListening = true
        isTriggered = false
        restartTask?.cancel()

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            beginListening()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    guard let self, self.wantsListening, status == .authorized else { return }
                    self.beginListening()
                }
            }
        case .denied, .restricted:
            NSLog("Nex wake phrase listener needs Speech Recognition permission")
        @unknown default:
            NSLog("Nex wake phrase listener is unavailable on this Mac")
        }
    }

    func stop() {
        wantsListening = false
        restartTask?.cancel()
        restartTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeInputTap()
    }

    private func beginListening() {
        guard wantsListening, !isTriggered else { return }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeInputTap()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        hasInputTap = true

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.wantsListening, !self.isTriggered else { return }
                if let phrase = result.flatMap({ Self.match(in: $0.bestTranscription.formattedString) }) {
                    self.isTriggered = true
                    self.stop()
                    self.onDetected?(phrase)
                } else if error != nil {
                    self.scheduleRestart()
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            removeInputTap()
            scheduleRestart()
            NSLog("Nex wake phrase listener could not start the microphone: %@", error.localizedDescription)
        }
    }

    private func scheduleRestart() {
        guard wantsListening, !isTriggered, restartTask == nil else { return }
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil
            self.beginListening()
        }
    }

    private func removeInputTap() {
        guard hasInputTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        hasInputTap = false
    }

    static func match(in transcription: String) -> Phrase? {
        let words = transcription
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        let normalized = String(words).split(whereSeparator: \.isWhitespace)
        let text = normalized.joined(separator: " ")
        return Phrase.allCases.first { text.contains($0.rawValue) }
    }
}
