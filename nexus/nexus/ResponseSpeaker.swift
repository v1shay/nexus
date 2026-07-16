import AVFoundation
import Foundation

/// Speaks streamed model output in natural sentence-sized pieces. Piper is
/// kept off the shell entirely: each chunk is passed through standard input to
/// an explicitly located executable, then played before the next chunk.
@MainActor
final class ResponseSpeaker {
    private let systemSynthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var generatedAudioURL: URL?
    private var piperTask: Task<Void, Never>?
    private var piperProcess: Process?
    private var piperQueue: [String] = []
    private var piperConfiguration: PiperVoiceConfiguration?
    private var chunker = SpeechSentenceChunker()

    func beginStreaming() {
        stop()
        chunker = SpeechSentenceChunker()
        piperConfiguration = PiperVoiceConfiguration.detect()
    }

    func append(_ delta: String) {
        enqueue(chunker.append(delta))
    }

    func finishStreaming() {
        if let remainder = chunker.finish() { enqueue([remainder]) }
    }

    func speak(_ text: String) {
        beginStreaming()
        append(text)
        finishStreaming()
    }

    func stop() {
        systemSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        if let generatedAudioURL { try? FileManager.default.removeItem(at: generatedAudioURL) }
        generatedAudioURL = nil
        piperTask?.cancel()
        piperTask = nil
        if piperProcess?.isRunning == true { piperProcess?.terminate() }
        piperProcess = nil
        piperQueue.removeAll()
        piperConfiguration = nil
        chunker = SpeechSentenceChunker()
    }

    private func enqueue(_ chunks: [String]) {
        guard !chunks.isEmpty else { return }
        guard piperConfiguration != nil else {
            chunks.forEach(speakWithSystemVoice)
            return
        }
        piperQueue.append(contentsOf: chunks)
        startPiperWorkerIfNeeded()
    }

    private func startPiperWorkerIfNeeded() {
        guard piperTask == nil, let configuration = piperConfiguration else { return }
        piperTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !piperQueue.isEmpty {
                let text = piperQueue.removeFirst()
                do {
                    let audio = try await Self.renderWithPiper(
                        text: text,
                        configuration: configuration
                    ) { process in
                        Task { @MainActor [weak self] in self?.piperProcess = process }
                    }
                    try Task.checkCancellation()
                    generatedAudioURL = audio
                    let player = try AVAudioPlayer(contentsOf: audio)
                    audioPlayer = player
                    player.play()
                    while player.isPlaying {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(45))
                    }
                    audioPlayer = nil
                    generatedAudioURL = nil
                    piperProcess = nil
                    try? FileManager.default.removeItem(at: audio)
                } catch is CancellationError {
                    break
                } catch {
                    piperConfiguration = nil
                    speakWithSystemVoice(text)
                    piperQueue.forEach(speakWithSystemVoice)
                    piperQueue.removeAll()
                }
            }
            piperTask = nil
            if !piperQueue.isEmpty { startPiperWorkerIfNeeded() }
        }
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
        process.arguments = [
            "--model", configuration.model.path,
            "--config", configuration.config.path,
            "--output_file", output.path,
            "--sentence-silence", "0.10"
        ]
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
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        }
        guard status == 0, FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            throw LocalModelError.invalidResponse("Piper did not produce audio")
        }
        return output
    }
}

struct SpeechSentenceChunker: Equatable {
    private var storage = ""
    private let maximumCharacters = 150

    mutating func append(_ text: String) -> [String] {
        storage += text
        var chunks: [String] = []

        while let boundary = storage.firstIndex(where: { ".!?\n".contains($0) }) {
            let end = storage.index(after: boundary)
            let sentence = String(storage[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            storage = String(storage[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { chunks.append(sentence) }
        }

        while storage.count >= maximumCharacters {
            let limit = storage.index(storage.startIndex, offsetBy: maximumCharacters)
            let candidate = storage[..<limit]
            let split = candidate.lastIndex(where: { $0.isWhitespace }) ?? limit
            let phrase = String(storage[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            storage = String(storage[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty { chunks.append(phrase) }
        }
        return chunks
    }

    mutating func finish() -> String? {
        let remainder = storage.trimmingCharacters(in: .whitespacesAndNewlines)
        storage = ""
        return remainder.isEmpty ? nil : remainder
    }
}

struct PiperVoiceConfiguration: Sendable, Equatable {
    let executable: URL
    let model: URL
    let config: URL

    static func detect(fileManager: FileManager = .default) -> PiperVoiceConfiguration? {
        let home = fileManager.homeDirectoryForCurrentUser
        let voiceDirectory = home.appendingPathComponent("Library/Application Support/Nexus/Voice", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)

        let executableCandidates = [
            voiceDirectory.appendingPathComponent("piper"),
            URL(fileURLWithPath: "/opt/homebrew/bin/piper"),
            URL(fileURLWithPath: "/usr/local/bin/piper"),
            URL(fileURLWithPath: "/opt/anaconda3/bin/piper"),
            home.appendingPathComponent(".local/bin/piper"),
            home.appendingPathComponent("Library/Python/3.13/bin/piper")
        ]
        guard let executable = executableCandidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            return nil
        }

        var voicePairs: [(URL, URL)] = [
            (voiceDirectory.appendingPathComponent("voice.onnx"), voiceDirectory.appendingPathComponent("voice.onnx.json")),
            (downloads.appendingPathComponent("jarvis-medium.onnx"), downloads.appendingPathComponent("jarvis-medium.onnx.json"))
        ]
        if let files = try? fileManager.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil) {
            voicePairs += files.filter { $0.pathExtension == "onnx" }.map {
                ($0, URL(fileURLWithPath: $0.path + ".json"))
            }
        }
        guard let pair = voicePairs.first(where: {
            fileManager.fileExists(atPath: $0.0.path) && fileManager.fileExists(atPath: $0.1.path)
        }) else { return nil }
        return PiperVoiceConfiguration(executable: executable, model: pair.0, config: pair.1)
    }
}
