enum NotchPresentation: Equatable {
    case idle
    case dictating
    case thinking
    case overlay
}

struct NotchInteractionState: Equatable {
    private(set) var presentation: NotchPresentation = .idle
    private(set) var transcript = ""
    private(set) var answer = ""

    mutating func beginDictation() {
        transcript = ""
        answer = ""
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
        presentation = .thinking
    }

    mutating func receiveAnswer(_ text: String) {
        answer = text
        presentation = .overlay
    }

    mutating func receivePartialAnswer(_ text: String) {
        answer = text
        presentation = .overlay
    }

    mutating func failResponse(_ message: String) {
        answer = message
        presentation = .overlay
    }

    mutating func showOverlay() {
        guard presentation != .dictating && presentation != .thinking else { return }
        presentation = .overlay
    }

    mutating func hideOverlay() {
        guard presentation != .dictating && presentation != .thinking else { return }
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
