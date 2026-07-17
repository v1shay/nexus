import AVFoundation
import Foundation

/// Owns one Piper process for an entire answer and schedules its raw PCM
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
    private var markdownFilter = StreamingSpeechMarkdownFilter()
    private var flushTask: Task<Void, Never>?
    private var streamingSessionIsActive = false
    private var isMuted = false
    private var scheduledBufferCount = 0
    private var pcmEmissionEpoch: UInt64 = 0
    private var lastPCMActivityUptime: TimeInterval = 0
    private var pipelineGeneration = UUID()
    private var orderedPCM = OrderedDataChunkBuffer()

    init() {
        audioEngine.attach(playerNode)
    }

    func beginStreaming() {
        streamingSessionIsActive = true
        chunker = SpeechSentenceChunker()
        markdownFilter = StreamingSpeechMarkdownFilter()
        guard !isMuted, piperProcess == nil,
              let configuration = PiperVoiceConfiguration.detect() else { return }
        piperConfiguration = configuration
        do {
            try startPiperStream(configuration)
        } catch {
            piperConfiguration = nil
            NSLog("Nexus could not start Piper; using the system voice: %@", error.localizedDescription)
        }
    }

    /// Bypasses phrase buffering for acknowledgements and tool-status speech.
    func speakImmediately(_ text: String) {
        guard !isMuted else { return }
        enqueue(text)
    }

    /// Speaks an acknowledgement and does not return until its audio has
    /// drained. The notch uses this gate so thinking never appears while the
    /// acknowledgement is still being spoken.
    func speakImmediatelyAndWait(_ text: String) async {
        guard !isMuted else { return }
        let startingEpoch = pcmEmissionEpoch
        let expectsPiperAudio = piperInput != nil
        enqueue(text)
        if expectsPiperAudio {
            await waitForPiperPlayback(after: startingEpoch, text: text)
        } else {
            await waitForSystemVoice()
        }
    }

    func append(_ delta: String) {
        guard streamingSessionIsActive, !isMuted else { return }
        let speakableText = markdownFilter.append(delta)
        chunker.append(speakableText).forEach(enqueue)
        schedulePendingPhraseFlush()
    }

    func finishStreaming() {
        flushTask?.cancel()
        flushTask = nil
        guard streamingSessionIsActive else { return }
        streamingSessionIsActive = false
        let finalSpeakableText = markdownFilter.finish()
        guard !isMuted else { return }
        chunker.append(finalSpeakableText).forEach(enqueue)
        if let remainder = chunker.flush() { enqueue(remainder) }
        try? piperInput?.close()
        piperInput = nil
    }

    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        if muted {
            stopPipeline()
            chunker = SpeechSentenceChunker()
            markdownFilter = StreamingSpeechMarkdownFilter()
        }
    }

    func stop() {
        streamingSessionIsActive = false
        chunker = SpeechSentenceChunker()
        markdownFilter = StreamingSpeechMarkdownFilter()
        stopPipeline()
    }

    private func schedulePendingPhraseFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, !self.isMuted,
                  let phrase = self.chunker.flushReadyPrefix() else { return }
            self.enqueue(phrase)
        }
    }

    private func waitForPiperPlayback(after startingEpoch: UInt64, text: String) async {
        let wordCount = max(1, text.split(whereSeparator: { $0.isWhitespace }).count)
        // The old five-second minimum made a completed two-word
        // acknowledgement look frozen whenever Piper's final buffer callback
        // arrived late. Keep the real playback drain check, but bound its
        // fallback to the phrase's expected speaking time.
        let timeout = min(8.0, max(2.5, Double(wordCount) / 2.2 + 1.5))
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var observedAudio = false

        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !Task.isCancelled, !isMuted else { return }
            if systemSynthesizer.isSpeaking {
                await waitForSystemVoice()
                return
            }
            if pcmEmissionEpoch > startingEpoch { observedAudio = true }
            let quietFor = ProcessInfo.processInfo.systemUptime - lastPCMActivityUptime
            if observedAudio, scheduledBufferCount == 0, quietFor >= 0.20 { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func waitForSystemVoice() async {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        await Task.yield()
        while systemSynthesizer.isSpeaking,
              ProcessInfo.processInfo.systemUptime < deadline {
            guard !Task.isCancelled, !isMuted else { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func enqueue(_ phrase: String) {
        let cleaned = SpeechSanitizer.forSpeech(phrase)
        guard !cleaned.isEmpty, !isMuted else { return }
        if let input = piperInput {
            do {
                try input.write(contentsOf: Data((cleaned + "\n").utf8))
            }
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
        let generation = UUID()
        let sequence = LockedSequenceCounter()
        pipelineGeneration = generation
        orderedPCM = OrderedDataChunkBuffer()
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: configuration.sampleRate,
            channels: 1,
            interleaved: false
        )!
        if audioEngine.isRunning { audioEngine.stop() }
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
            let index = sequence.next()
            Task { @MainActor [weak self] in
                self?.receivePCM(data, sequence: index, generation: generation)
            }
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

    private func receivePCM(_ incoming: Data, sequence: UInt64, generation: UUID) {
        guard generation == pipelineGeneration else { return }
        for orderedChunk in orderedPCM.insert(incoming, sequence: sequence) {
            schedulePCM(orderedChunk, generation: generation)
        }
    }

    private func schedulePCM(_ incoming: Data, generation: UUID) {
        guard generation == pipelineGeneration, !isMuted, let audioFormat else { return }
        pcmEmissionEpoch &+= 1
        lastPCMActivityUptime = ProcessInfo.processInfo.systemUptime
        pendingPCM.append(incoming)
        let byteCount = pendingPCM.count - (pendingPCM.count % MemoryLayout<Int16>.size)
        guard byteCount > 0 else { return }
        let audio = pendingPCM.prefix(byteCount)
        pendingPCM.removeFirst(byteCount)
        let frames = AVAudioFrameCount(byteCount / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frames),
              let destination = buffer.floatChannelData?.pointee else { return }
        buffer.frameLength = frames
        audio.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            for index in 0..<samples.count {
                destination[index] = Float(samples[index]) / Float(Int16.max)
            }
        }
        scheduledBufferCount += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pipelineGeneration == generation else { return }
                self.scheduledBufferCount = max(0, self.scheduledBufferCount - 1)
            }
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    private func stopPipeline() {
        pipelineGeneration = UUID()
        orderedPCM = OrderedDataChunkBuffer()
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
        scheduledBufferCount = 0
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

struct OrderedDataChunkBuffer: Equatable {
    private var nextSequence: UInt64 = 0
    private var pending: [UInt64: Data] = [:]

    mutating func insert(_ data: Data, sequence: UInt64) -> [Data] {
        guard sequence >= nextSequence else { return [] }
        pending[sequence] = data
        var ready: [Data] = []
        while let chunk = pending.removeValue(forKey: nextSequence) {
            ready.append(chunk)
            nextSequence &+= 1
        }
        return ready
    }
}

private final class LockedSequenceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock {
            defer { value &+= 1 }
            return value
        }
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
            guard let split = candidate.lastIndex(where: { $0.isWhitespace }),
                  split != storage.startIndex else { break }
            if let phrase = takePrefix(through: split) { chunks.append(phrase) }
        }
        return chunks
    }

    /// Flushes only text ending at a confirmed whitespace boundary. The final
    /// word stays buffered because a streamed token may still be only half of
    /// that word.
    mutating func flushReadyPrefix() -> String? {
        guard storage.count >= 18,
              let boundary = storage.lastIndex(where: { $0.isWhitespace }) else { return nil }
        return takePrefix(through: storage.index(after: boundary))
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

/// Uses the authoritative accumulated model text to emit each spoken suffix
/// once. Duplicate or stale network events can no longer repeat or reorder TTS.
struct StreamedSpeechCursor: Equatable {
    private(set) var text = ""
    private var segmentPrefix = ""

    mutating func beginSegment(separator: String = "\n\n") {
        if !text.isEmpty { text += separator }
        segmentPrefix = text
    }

    mutating func consume(delta: String, accumulated snapshot: String) -> String {
        let snapshot = segmentPrefix + snapshot
        if snapshot.hasPrefix(text) {
            let suffix = String(snapshot.dropFirst(text.count))
            text = snapshot
            return suffix
        }
        if text.hasPrefix(snapshot) {
            return ""
        }
        if snapshot.isEmpty, !delta.isEmpty {
            text += delta
            return delta
        }

        // A provider correction may replace earlier text. Update the visible
        // answer, but do not speak the divergent section because spoken audio
        // cannot be retracted safely.
        text = snapshot
        return ""
    }
}

/// Removes fenced code from streamed Markdown before it reaches TTS. The
/// parser retains partial backtick runs across model tokens, so a split ```
/// delimiter can never leak source code into Piper.
struct StreamingSpeechMarkdownFilter: Equatable {
    private enum Mode: Equatable {
        case prose
        case openingFence(language: String)
        case code
    }

    private var mode: Mode = .prose
    private var pendingBackticks = 0
    private var linkFilter = StreamingSpeechLinkFilter()

    mutating func append(_ text: String) -> String {
        processMarkdown(linkFilter.append(text))
    }

    private mutating func processMarkdown(_ text: String) -> String {
        var output = ""
        for character in text {
            switch mode {
            case .prose:
                if character == "`" {
                    pendingBackticks += 1
                    if pendingBackticks == 3 {
                        pendingBackticks = 0
                        mode = .openingFence(language: "")
                    }
                } else {
                    flushLiteralBackticks(into: &output)
                    output.append(character)
                }

            case .openingFence(let currentLanguage):
                if character == "\n" || character == "\r" {
                    output += Self.codeAnnouncement(for: currentLanguage)
                    pendingBackticks = 0
                    mode = .code
                } else {
                    mode = .openingFence(language: currentLanguage + String(character))
                }

            case .code:
                if character == "`" {
                    pendingBackticks += 1
                    if pendingBackticks == 3 {
                        pendingBackticks = 0
                        mode = .prose
                        output.append(" ")
                    }
                } else {
                    pendingBackticks = 0
                }
            }
        }
        return output
    }

    mutating func finish() -> String {
        var output = processMarkdown(linkFilter.finish())
        switch mode {
        case .prose:
            flushLiteralBackticks(into: &output)
        case .openingFence(let language):
            output = Self.codeAnnouncement(for: language)
        case .code:
            break
        }
        mode = .prose
        pendingBackticks = 0
        linkFilter = StreamingSpeechLinkFilter()
        return output
    }

    private mutating func flushLiteralBackticks(into output: inout String) {
        guard pendingBackticks > 0 else { return }
        output += String(repeating: "`", count: pendingBackticks)
        pendingBackticks = 0
    }

    private static func codeAnnouncement(for rawLanguage: String) -> String {
        let identifier = rawLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased() ?? ""
        let language: String? = switch identifier {
        case "py", "python": "Python"
        case "js", "javascript": "JavaScript"
        case "ts", "typescript": "TypeScript"
        case "sh", "shell", "bash", "zsh": "shell"
        case "swift": "Swift"
        case "kt", "kotlin": "Kotlin"
        case "rs", "rust": "Rust"
        case "rb", "ruby": "Ruby"
        case "cpp", "c++": "C++"
        case "csharp", "cs", "c#": "C sharp"
        case "go", "golang": "Go"
        case "java": "Java"
        case "html": "HTML"
        case "css": "CSS"
        case "sql": "SQL"
        case "json": "JSON"
        case "yaml", "yml": "YAML"
        case "": nil
        default: identifier.prefix(24).capitalized
        }
        return language.map { " Here is the \($0) code. " } ?? " Here is the code. "
    }
}

/// Buffers Markdown links across token boundaries and emits only their human
/// label. A URL can therefore never reach the sentence chunker half-finished
/// and be spoken before the final `)` arrives.
struct StreamingSpeechLinkFilter: Equatable {
    private enum Mode: Equatable {
        case text
        case label(String)
        case awaitingDestination(String)
        case destination(label: String, depth: Int)
    }

    private var mode: Mode = .text

    mutating func append(_ text: String) -> String {
        var output = ""
        for character in text {
            switch mode {
            case .text:
                if character == "[" {
                    mode = .label("")
                } else {
                    output.append(character)
                }
            case .label(let label):
                if character == "]" {
                    mode = .awaitingDestination(label)
                } else if character == "\n" || label.count >= 200 {
                    output += "[" + label + String(character)
                    mode = .text
                } else {
                    mode = .label(label + String(character))
                }
            case .awaitingDestination(let label):
                if character == "(" {
                    mode = .destination(label: label, depth: 1)
                } else {
                    output += "[" + label + "]" + String(character)
                    mode = .text
                }
            case .destination(let label, let depth):
                if character == "(" {
                    mode = .destination(label: label, depth: depth + 1)
                } else if character == ")" {
                    if depth == 1 {
                        output += label
                        mode = .text
                    } else {
                        mode = .destination(label: label, depth: depth - 1)
                    }
                }
            }
        }
        return output
    }

    mutating func finish() -> String {
        defer { mode = .text }
        switch mode {
        case .text: return ""
        case .label(let label): return "[" + label
        case .awaitingDestination(let label): return "[" + label + "]"
        case .destination(let label, _): return label
        }
    }
}

enum SpeechSanitizer {
    static func forSpeech(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"```[\s\S]*?```"#, with: " code block ", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"https?://[^\s]+"#, with: "", options: [.regularExpression, .caseInsensitive])
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
