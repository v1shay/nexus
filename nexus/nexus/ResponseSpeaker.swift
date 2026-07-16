import AVFoundation
import Foundation

/// Owns one warm Piper process for an entire answer and schedules its raw PCM
/// output directly into AVAudioEngine. This removes the per-sentence model-load
/// delay and lets speech follow the model's token stream.
@MainActor
final class ResponseSpeaker {
    private let systemSynthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat?
    private var piperProcess: Process?
    private var piperInput: FileHandle?
    private var piperOutput: Pipe?
    private var piperConfiguration: PiperVoiceConfiguration?
    private var pendingPCM = Data()
    private var chunker = SpeechSentenceChunker()
    private var flushTask: Task<Void, Never>?
    private var streamingSessionIsActive = false
    private var isMuted = false

    init() {
        audioEngine.attach(playerNode)
    }

    func beginStreaming() {
        stopPipeline()
        streamingSessionIsActive = true
        chunker = SpeechSentenceChunker()
        guard !isMuted else { return }
        piperConfiguration = PiperVoiceConfiguration.detect()
        if let configuration = piperConfiguration {
            do { try startPiperStream(configuration) }
            catch { piperConfiguration = nil }
        }
    }

    /// Bypasses phrase buffering for acknowledgements and tool-status speech.
    func speakImmediately(_ text: String) {
        guard !isMuted else { return }
        enqueue(text)
    }

    func append(_ delta: String) {
        guard streamingSessionIsActive, !isMuted else { return }
        chunker.append(delta).forEach(enqueue)
        schedulePendingPhraseFlush()
    }

    func finishStreaming() {
        flushTask?.cancel()
        flushTask = nil
        guard streamingSessionIsActive, !isMuted else { return }
        if let remainder = chunker.flush() { enqueue(remainder) }
        finishPiperInput()
    }

    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        if muted {
            stopPipeline()
            chunker = SpeechSentenceChunker()
        } else if streamingSessionIsActive {
            piperConfiguration = PiperVoiceConfiguration.detect()
            if let configuration = piperConfiguration {
                do { try startPiperStream(configuration) }
                catch { piperConfiguration = nil }
            }
        }
    }

    func stop() {
        streamingSessionIsActive = false
        chunker = SpeechSentenceChunker()
        stopPipeline()
    }

    private func schedulePendingPhraseFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, let self, !self.isMuted,
                  let phrase = self.chunker.flush() else { return }
            self.enqueue(phrase)
        }
    }

    private func enqueue(_ phrase: String) {
        let cleaned = SpeechSanitizer.forSpeech(phrase)
        guard !cleaned.isEmpty, !isMuted else { return }
        if let input = piperInput {
            do { try input.write(contentsOf: Data((cleaned + "\n").utf8)) }
            catch {
                piperConfiguration = nil
                speakWithSystemVoice(cleaned)
            }
        } else {
            speakWithSystemVoice(cleaned)
        }
    }

    private func startPiperStream(_ configuration: PiperVoiceConfiguration) throws {
        guard piperProcess == nil else { return }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: configuration.sampleRate,
            channels: 1,
            interleaved: false
        )!
        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        audioEngine.prepare()
        try audioEngine.start()
        playerNode.play()
        audioFormat = format

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = configuration.executable
        process.arguments = [
            "--model", configuration.model.path,
            "--config", configuration.config.path,
            "--output_raw",
            "--length-scale", "0.78",
            "--sentence-silence", "0.04"
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in self?.schedulePCM(data) }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor [weak self, weak process] in
                guard let self, self.piperProcess === process else { return }
                self.piperProcess = nil
                self.piperInput = nil
                self.piperOutput = nil
            }
        }
        try process.run()
        piperProcess = process
        piperInput = input.fileHandleForWriting
        piperOutput = output
    }

    private func schedulePCM(_ incoming: Data) {
        guard !isMuted, let audioFormat else { return }
        pendingPCM.append(incoming)
        let byteCount = pendingPCM.count - (pendingPCM.count % MemoryLayout<Int16>.size)
        guard byteCount > 0 else { return }
        let audio = pendingPCM.prefix(byteCount)
        pendingPCM.removeFirst(byteCount)
        let frames = AVAudioFrameCount(byteCount / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frames),
              let destination = buffer.int16ChannelData?.pointee else { return }
        buffer.frameLength = frames
        audio.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(destination, source, byteCount)
        }
        playerNode.scheduleBuffer(buffer)
        if !playerNode.isPlaying { playerNode.play() }
    }

    private func finishPiperInput() {
        try? piperInput?.close()
        piperInput = nil
    }

    private func stopPipeline() {
        flushTask?.cancel()
        flushTask = nil
        systemSynthesizer.stopSpeaking(at: .immediate)
        piperOutput?.fileHandleForReading.readabilityHandler = nil
        try? piperInput?.close()
        piperInput = nil
        if piperProcess?.isRunning == true { piperProcess?.terminate() }
        piperProcess = nil
        piperOutput = nil
        playerNode.stop()
        audioEngine.stop()
        audioEngine.reset()
        audioFormat = nil
        pendingPCM.removeAll(keepingCapacity: true)
    }

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.56
        utterance.pitchMultiplier = 1.02
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US")
        systemSynthesizer.speak(utterance)
    }
}

struct SpeechSentenceChunker: Equatable {
    private var storage = ""
    private let maximumCharacters = 56

    mutating func append(_ text: String) -> [String] {
        storage += text
        var chunks: [String] = []
        while let boundary = storage.firstIndex(where: { ".!?;:\n".contains($0) }) {
            let end = storage.index(after: boundary)
            if let phrase = takePrefix(through: end) { chunks.append(phrase) }
        }
        while storage.count >= maximumCharacters {
            let limit = storage.index(storage.startIndex, offsetBy: maximumCharacters)
            let candidate = storage[..<limit]
            let split = candidate.lastIndex(where: { $0.isWhitespace }) ?? limit
            if let phrase = takePrefix(through: split) { chunks.append(phrase) }
        }
        return chunks
    }

    mutating func flush() -> String? {
        let remainder = storage.trimmingCharacters(in: .whitespacesAndNewlines)
        storage = ""
        return remainder.isEmpty ? nil : remainder
    }

    private mutating func takePrefix(through end: String.Index) -> String? {
        let phrase = String(storage[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        storage = String(storage[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return phrase.isEmpty ? nil : phrase
    }
}

enum SpeechSanitizer {
    static func forSpeech(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"```[\s\S]*?```"#, with: " code block ", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[*_>#]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PiperVoiceConfiguration: Sendable, Equatable {
    let executable: URL
    let model: URL
    let config: URL
    let sampleRate: Double

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
        return PiperVoiceConfiguration(
            executable: executable,
            model: pair.0,
            config: pair.1,
            sampleRate: sampleRate(from: pair.1, fileManager: fileManager)
        )
    }

    private static func sampleRate(from config: URL, fileManager: FileManager) -> Double {
        guard let data = fileManager.contents(atPath: config.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let audio = json["audio"] as? [String: Any],
              let rate = audio["sample_rate"] as? NSNumber else { return 22_050 }
        return rate.doubleValue
    }
}
