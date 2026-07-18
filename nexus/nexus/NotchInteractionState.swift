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
}

struct ToolReceiptSource: Equatable, Identifiable, Sendable {
    let id: String
    let sourceID: String
    let title: String
    let excerpt: String
}

struct ToolActivity: Equatable, Sendable {
    let toolName: String
    let status: String
    let spokenStatus: String
    let icon: ToolIconSource
    var phase: NexToolLifecyclePhase = .started
    var progress: Double?
    var sources: [ToolReceiptSource] = []

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
        let title = isMemory
            ? "Nex Memory"
            : (isWebSearch ? "Web Search" : event.toolName.replacingOccurrences(of: "_", with: " ").capitalized)
        let icon: ToolIconSource
        if isMemory {
            icon = .asset(name: "Obsidian", fallbackSystemName: "diamond.fill")
        } else if isWebSearch {
            icon = .asset(name: "Chrome", fallbackSystemName: "globe")
        } else {
            icon = .systemSymbol("wrench.and.screwdriver")
        }
        return ToolActivity(
            toolName: title,
            status: event.message,
            spokenStatus: isMemory ? "Checking memory." : (isWebSearch ? "Searching the web." : event.message),
            icon: icon,
            phase: event.phase,
            progress: event.progress,
            sources: isMemory ? memorySources(from: event.result) : (isWebSearch ? webSources(from: event.result) : [])
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

struct NotchInteractionState: Equatable {
    private(set) var presentation: NotchPresentation = .idle
    private(set) var transcript = ""
    private(set) var answer = ""
    private(set) var toolActivity: ToolActivity?
    private(set) var toolReceipt: ToolActivity?

    mutating func beginDictation() {
        transcript = ""
        answer = ""
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

    mutating func beginThinking() {
        guard !transcript.isEmpty else { return }
        toolActivity = nil
        presentation = .thinking
    }

    mutating func beginToolActivity(_ activity: ToolActivity) {
        if activity.phase == .started { toolReceipt = nil }
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
        presentation = .overlay
    }

    mutating func receiveAnswer(_ text: String, reveal: Bool = true) {
        toolActivity = nil
        answer = text
        presentation = reveal ? .overlay : .idle
    }

    mutating func receivePartialAnswer(_ text: String, reveal: Bool = true) {
        toolActivity = nil
        answer = text
        presentation = reveal ? .overlay : .idle
    }

    mutating func failResponse(_ message: String, reveal: Bool = true) {
        toolActivity = nil
        answer = message
        presentation = reveal ? .overlay : .idle
    }

    mutating func restoreConversation(transcript: String, answer: String) {
        self.transcript = transcript
        self.answer = answer
        toolActivity = nil
        toolReceipt = nil
        presentation = .overlay
    }

    mutating func showOverlay() {
        guard presentation != .dictating && presentation != .thinking && presentation != .tool else { return }
        presentation = .overlay
    }

    mutating func hideOverlay() {
        guard presentation != .dictating && presentation != .thinking && presentation != .tool else { return }
        presentation = .idle
    }

    mutating func dismiss() {
        toolActivity = nil
        toolReceipt = nil
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
