import AVFoundation
import Speech

final class SpeechTranscriber: NSObject, @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: .current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasInputTap = false
    private var wantsRecording = false
    private var onUpdate: ((String) -> Void)?

    func start(onUpdate: @escaping (String) -> Void) {
        wantsRecording = true
        self.onUpdate = onUpdate

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
        if audioEngine.isRunning { audioEngine.stop() }
        removeInputTap()
        recognitionRequest?.endAudio()
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
}
