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
    case svg(data: Data, fallbackSystemName: String)
}

struct ToolActivity: Equatable, Sendable {
    let toolName: String
    let status: String
    let spokenStatus: String
    let icon: ToolIconSource

    static func googleSearch(query: String) -> ToolActivity {
        ToolActivity(
            toolName: "Google Search",
            status: "Researching \(query) with Google",
            spokenStatus: "Searching Google for \(query).",
            icon: .svg(data: Data(chromeSVG.utf8), fallbackSystemName: "globe")
        )
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

    mutating func beginDictation() {
        transcript = ""
        answer = ""
        toolActivity = nil
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
        toolActivity = activity
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
        presentation = .idle
    }
}

enum PromptAcknowledgement {
    static func text(for prompt: String) -> String {
        let normalized = prompt.lowercased()
        if normalized.contains("search") || normalized.contains("look up") || normalized.contains("research") {
            return "Got it. I’ll look into that."
        }
        if normalized.contains("write") || normalized.contains("create") || normalized.contains("build") {
            return "Understood. I’ll put that together."
        }
        return "Got it. Let me work through that."
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
