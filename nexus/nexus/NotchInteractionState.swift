enum NotchPresentation: Equatable {
    case idle
    case dictating
    case overlay
}

struct NotchInteractionState: Equatable {
    private(set) var presentation: NotchPresentation = .idle
    private(set) var transcript = ""

    mutating func beginDictation() {
        transcript = ""
        presentation = .dictating
    }

    mutating func updateTranscript(_ text: String) {
        transcript = text
    }

    mutating func finishDictation() {
        presentation = .idle
    }

    mutating func showOverlay() {
        guard presentation != .dictating else { return }
        presentation = .overlay
    }

    mutating func hideOverlay() {
        guard presentation != .dictating else { return }
        presentation = .idle
    }
}
