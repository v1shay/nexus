import Foundation

enum NotchPresentation: Equatable {
    case idle
    case dictating
    case thinking
    case tool
    case overlay
}

enum ToolIconSource: Equatable, Sendable {
    case systemSymbol(String)
    case asset(name: String, fallbackSystemName: String)
    case svg(data: Data, fallbackSystemName: String)
    case image(data: Data, fallbackSystemName: String)
}

struct ToolReceiptSource: Equatable, Identifiable, Sendable {
    let id: String
    let sourceID: String
    let title: String
    let excerpt: String
}

struct ToolActivity: Equatable, Sendable {
    var actionID: String? = nil
    let toolName: String
    let status: String
    let spokenStatus: String
    let icon: ToolIconSource
    var phase: NexToolLifecyclePhase = .started
    var progress: Double?
    /// A live external-worker line. When present it is rendered verbatim in
    /// the compact notch beneath the worker's current activity.
    var detail: String? = nil
    /// Present only for a Codex activity so the notch can select another live
    /// local Codex chat without conflating their progress streams.
    var codexSessionID: String? = nil
    var codexTaskTitle: String? = nil
    var codexKind: CodexProgressKind? = nil
    /// The exact validated query sent to a retrieval tool.
    var query: String?
    var sources: [ToolReceiptSource] = []
    var arguments: [String: NexJSONValue] = [:]
    var result: NexJSONValue? = nil

    var requiresExpandedPreview: Bool {
        let action = actionID ?? ""
        // Execution consoles are intentionally direct. Their streamed status
        // is the useful UI, whereas app actions hand off to a result card.
        guard toolName != "Codex", toolName != "Nex CLI", !action.hasPrefix("terminal.") else { return false }
        if phase == .failed { return true }
        guard phase == .completed else { return false }
        // A status-bearing app result is a real handoff: show its returned
        // files, media, draft, connector result, or setting in the glass
        // card. Retrieval-only tools typically do not emit a status field,
        // so web and memory streaming retain their existing compact UX.
        return result?.object?["status"]?.string != nil
    }

    /// Generic activity text stays in the compact row. Reserve a second line
    /// only for real streamed worker output or retrieved search results.
    var requiresCompactTextReveal: Bool {
        detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || (toolName == "Web Search" && (
                !sources.isEmpty || query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ))
            || (toolName == "YouTube" && (
                !sources.isEmpty || query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ))
    }

    static func googleSearch(query: String) -> ToolActivity {
        ToolActivity(
            toolName: "Google Search",
            status: "Researching \(query) with Google",
            spokenStatus: "Searching Google for \(query).",
            icon: .svg(data: Data(chromeSVG.utf8), fallbackSystemName: "globe"),
            progress: nil
        )
    }

    static func lifecycle(_ event: NexToolLifecycleEvent) -> ToolActivity {
        let isMemory = event.toolName.hasPrefix("memory_") || event.toolName == "conversation_recall"
        let isWebSearch = event.toolName == "web_search"
        let isNexCLI = event.toolName == "nex_cli_task"
        let isYouTube = event.toolName.hasPrefix("youtube_")
        let title = isMemory
            ? "Nex Memory"
            : (isWebSearch ? "Web Search" : (isNexCLI ? "Nex CLI" : (isYouTube ? "YouTube" : event.toolName.replacingOccurrences(of: "_", with: " ").capitalized)))
        let icon = NexProviderIconCatalog.icon(for: event.toolName)
        let query: String?
        if let submitted = event.arguments["query"]?.string {
            query = submitted
        } else if case .object(let result)? = event.result {
            query = result["query"]?.string
        } else {
            query = nil
        }
        return ToolActivity(
            actionID: event.toolName,
            toolName: title,
            status: event.message,
            spokenStatus: isMemory ? "Checking memory." : (isWebSearch ? "Searching the web." : (isYouTube ? "Checking YouTube." : event.message)),
            icon: icon,
            phase: event.phase,
            progress: event.progress,
            detail: isNexCLI ? "NEX > \(event.message)" : nil,
            query: query,
            sources: isMemory ? memorySources(from: event.result) : ((isWebSearch || isYouTube) ? webSources(from: event.result) : []),
            arguments: event.arguments,
            result: event.result
        )
    }

    static func codex(_ update: CodexProgressUpdate) -> ToolActivity {
        ToolActivity(
            toolName: "Codex",
            status: update.kind.label,
            spokenStatus: "",
            icon: CodexProgressAssets.icon(for: update.kind),
            phase: update.phase,
            detail: update.detail,
            codexSessionID: update.sessionID,
            codexTaskTitle: update.taskTitle,
            codexKind: update.kind
        )
    }

    private static func webSources(from result: NexJSONValue?) -> [ToolReceiptSource] {
        guard case .object(let object) = result,
              case .array(let values) = object["results"] else { return [] }
        var seen = Set<String>()
        return values.compactMap { value in
            guard case .object(let source) = value,
                  let url = source["url"]?.string,
                  let title = source["title"]?.string else { return nil }
            guard seen.insert(url).inserted else { return nil }
            let extracted = source["extracted_text"]?.string
            let snippet = source["snippet"]?.string ?? ""
            return ToolReceiptSource(
                id: url,
                sourceID: url,
                title: title,
                excerpt: extracted?.isEmpty == false ? extracted! : snippet
            )
        }
    }

    private static func memorySources(from result: NexJSONValue?) -> [ToolReceiptSource] {
        guard case .object(let object) = result,
              case .array(let values) = object["results"] else { return [] }
        var seen = Set<String>()
        return values.compactMap { value in
            guard case .object(let source) = value,
                  let sourceID = source["source_id"]?.string,
                  let title = source["title"]?.string,
                  let excerpt = source["excerpt"]?.string else { return nil }
            let id = source["chunk_id"]?.string ?? sourceID
            guard seen.insert(id).inserted else { return nil }
            return ToolReceiptSource(id: id, sourceID: sourceID, title: title, excerpt: excerpt)
        }
    }

    private static let chromeSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
      <path fill="#EA4335" d="M32 4a28 28 0 0 1 24.3 14H32a14 14 0 0 0-12.1 7L11.8 11A27.9 27.9 0 0 1 32 4Z"/>
      <path fill="#FBBC04" d="M11.8 11 24 32a14 14 0 0 0 12.1 13.4L28 59.8A28 28 0 0 1 11.8 11Z"/>
      <path fill="#34A853" d="M28 59.8 40.1 39A14 14 0 0 0 44.1 25h12.2A28 28 0 0 1 28 59.8Z"/>
      <circle cx="32" cy="32" r="11" fill="#4285F4" stroke="white" stroke-width="2"/>
    </svg>
    """

}

enum CodexProgressAssets {
    private static let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true)

    static let avatarURL = downloadsURL.appendingPathComponent("codex-removebg-preview.png")

    static func icon(for kind: CodexProgressKind) -> ToolIconSource {
        let fileName: String = switch kind {
        case .thinking: "codex.svg"
        case .terminal: "terminal-svgrepo-com.svg"
        case .writing: "code-svgrepo-com.svg"
        case .reading: "read-svgrepo-com.svg"
        case .image: "image-01-svgrepo-com.svg"
        case .git: "code-merge-svgrepo-com.svg"
        }
        let url = downloadsURL.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url) {
            return .svg(data: data, fallbackSystemName: kind.fallbackSymbol)
        }
        return .systemSymbol(kind.fallbackSymbol)
    }
}

struct NotchInteractionState: Equatable {
    private(set) var presentation: NotchPresentation = .idle
    private(set) var transcript = ""
    private(set) var answer = ""
    /// A late model-generated status remains visible while the notch is in
    /// its compact working state. It is separate from `answer` so status
    /// generation can never overwrite streamed response text.
    private(set) var workingStatus: String?
    private(set) var thinkingSentence: String?
    private(set) var toolActivity: ToolActivity?
    private(set) var toolReceipt: ToolActivity?

    mutating func beginDictation() {
        transcript = ""
        answer = ""
        workingStatus = nil
        thinkingSentence = nil
        toolActivity = nil
        toolReceipt = nil
        presentation = .dictating
    }

    mutating func updateTranscript(_ text: String) {
        transcript = text
    }

    mutating func finishDictation() {
        presentation = .overlay
    }

    /// Global text-field dictation uses the shaping orb while Apple Speech
    /// finalizes and the low-latency cleaner resolves. This state is allowed
    /// even before a partial transcript arrives.
    mutating func beginDictationFinalizing() {
        toolActivity = nil
        thinkingSentence = nil
        presentation = .thinking
    }

    mutating func beginThinking() {
        guard !transcript.isEmpty else { return }
        toolActivity = nil
        presentation = .thinking
    }

    mutating func updateWorkingStatus(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        workingStatus = text
    }

    mutating func updateThinkingSentence(_ text: String) {
        let sentence = Self.sanitizedThinkingDisplay(text)
        guard !sentence.isEmpty else { return }
        thinkingSentence = sentence
    }

    /// Native reasoning is deliberately a low-detail ambient surface, not a
    /// transcript. Quotes and terminal punctuation create noisy flicker in the
    /// one-line notch, so keep their spacing but hide the marks themselves.
    static func sanitizedThinkingDisplay(_ text: String) -> String {
        let hiddenMarks = CharacterSet(charactersIn: ".…\\\"'“”‘’")
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(hiddenMarks.contains(scalar) ? UnicodeScalar(32)! : scalar)
        }
        let replaced = String(scalars)
        return replaced
            .replacingOccurrences(of: #"\s+"#, with: " ", options: NSString.CompareOptions.regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    mutating func beginToolActivity(_ activity: ToolActivity) {
        if activity.phase == .started { toolReceipt = nil }
        thinkingSentence = nil
        toolActivity = activity
        presentation = .tool
    }

    mutating func completeToolActivity(_ activity: ToolActivity) {
        toolActivity = activity
        toolReceipt = activity
        presentation = .tool
    }

    mutating func acknowledge(_ text: String) {
        answer = text
        workingStatus = text
        presentation = .overlay
    }

    mutating func receiveAnswer(_ text: String, reveal: Bool = true) {
        toolActivity = nil
        workingStatus = nil
        thinkingSentence = nil
        answer = text
        presentation = reveal ? .overlay : .idle
    }

    mutating func receivePartialAnswer(_ text: String, reveal: Bool = true) {
        toolActivity = nil
        workingStatus = nil
        thinkingSentence = nil
        answer = text
        presentation = reveal ? .overlay : .idle
    }

    mutating func failResponse(_ message: String, reveal: Bool = true) {
        toolActivity = nil
        workingStatus = nil
        thinkingSentence = nil
        answer = message
        presentation = reveal ? .overlay : .idle
    }

    mutating func restoreConversation(transcript: String, answer: String) {
        self.transcript = transcript
        self.answer = answer
        workingStatus = nil
        thinkingSentence = nil
        toolActivity = nil
        toolReceipt = nil
        presentation = .overlay
    }

    mutating func showOverlay() {
        guard presentation != .dictating && presentation != .thinking && presentation != .tool else { return }
        presentation = .overlay
    }

    /// An explicitly requested media player replaces transient work states.
    /// Hover-driven expansion must not do this, but a playback command must:
    /// otherwise the panel can resize while the tool indicator still wins the
    /// view-state switch and the player never appears.
    mutating func showMediaOverlay() {
        toolActivity = nil
        toolReceipt = nil
        workingStatus = nil
        thinkingSentence = nil
        presentation = .overlay
    }

    mutating func hideOverlay() {
        guard presentation != .dictating && presentation != .thinking && presentation != .tool else { return }
        presentation = .idle
    }

    mutating func dismiss() {
        toolActivity = nil
        toolReceipt = nil
        workingStatus = nil
        thinkingSentence = nil
        presentation = .idle
    }
}

/// Converts the continuous mouse-move stream into one enter and one exit per
/// visit. The session spans both the physical camera cutout and Nexus's panel,
/// so resizing the panel underneath the cursor cannot retrigger expansion.
struct NotchHoverSession: Equatable {
    private(set) var isActive = false

    mutating func update(isInside: Bool) -> Bool? {
        guard isInside != isActive else { return nil }
        isActive = isInside
        return isInside
    }
}
