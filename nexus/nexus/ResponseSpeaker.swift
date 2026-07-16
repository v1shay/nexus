import AVFoundation
import Foundation

@MainActor
final class ResponseSpeaker {
    private let systemSynthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var generatedAudioURL: URL?
    private var piperTask: Task<Void, Never>?
    private var piperProcess: Process?

    func speak(_ text: String) {
        stop()
        if let configuration = PiperVoiceConfiguration.detect() {
            piperTask = Task { [weak self] in
                do {
                    let audio = try await Self.renderWithPiper(text: text, configuration: configuration) { process in
                        Task { @MainActor in self?.piperProcess = process }
                    }
                    guard !Task.isCancelled else { return }
                    let player = try AVAudioPlayer(contentsOf: audio)
                    self?.audioPlayer = player
                    self?.generatedAudioURL = audio
                    player.play()
                } catch {
                    self?.speakWithSystemVoice(text)
                }
            }
        } else {
            speakWithSystemVoice(text)
        }
    }

    func stop() {
        systemSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        if let generatedAudioURL { try? FileManager.default.removeItem(at: generatedAudioURL) }
        generatedAudioURL = nil
        piperTask?.cancel()
        if piperProcess?.isRunning == true { piperProcess?.terminate() }
        piperProcess = nil
    }

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.02
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US")
        systemSynthesizer.speak(utterance)
    }

    private nonisolated static func renderWithPiper(
        text: String,
        configuration: PiperVoiceConfiguration,
        processStarted: @escaping @Sendable (Process) -> Void
    ) async throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-response-\(UUID().uuidString).wav")
        let process = Process()
        let input = Pipe()
        process.executableURL = configuration.executable
        process.arguments = ["--model", configuration.model.path, "--config", configuration.config.path, "--output_file", output.path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        processStarted(process)
        input.fileHandleForWriting.write(Data((text + "\n").utf8))
        try input.fileHandleForWriting.close()
        let status = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        guard status == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw LocalModelError.invalidResponse("Piper did not produce audio")
        }
        return output
    }
}

struct PiperVoiceConfiguration: Sendable {
    let executable: URL
    let model: URL
    let config: URL

    static func detect(fileManager: FileManager = .default) -> PiperVoiceConfiguration? {
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Nexus/Voice", isDirectory: true)
        let configuration = PiperVoiceConfiguration(
            executable: directory.appendingPathComponent("piper"),
            model: directory.appendingPathComponent("voice.onnx"),
            config: directory.appendingPathComponent("voice.onnx.json")
        )
        guard fileManager.isExecutableFile(atPath: configuration.executable.path),
              fileManager.fileExists(atPath: configuration.model.path),
              fileManager.fileExists(atPath: configuration.config.path) else { return nil }
        return configuration
    }
}
