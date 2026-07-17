import Foundation

enum NexConversationRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
}

enum NexConversationTurnState: String, Codable, Sendable {
    case finalized
    case interrupted
}

struct NexConversationTurn: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let role: NexConversationRole
    let text: String
    let createdAt: Date
    let state: NexConversationTurnState

    init(
        id: UUID = UUID(),
        role: NexConversationRole,
        text: String,
        createdAt: Date = Date(),
        state: NexConversationTurnState = .finalized
    ) {
        self.id = id
        self.role = role
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.state = state
    }
}

struct NexConversationSnapshot: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let title: String
    let summary: String
    let topics: [String]
    let projects: [String]
    let entities: [String]
    let decisions: [String]
    let openThreads: [String]
    let currentTask: String?
    let isActive: Bool
    let turns: [NexConversationTurn]

    init(
        schema: Int = NexConversationSnapshot.schemaVersion,
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        title: String,
        summary: String,
        topics: [String],
        projects: [String],
        entities: [String],
        decisions: [String],
        openThreads: [String],
        currentTask: String?,
        isActive: Bool,
        turns: [NexConversationTurn]
    ) {
        self.schema = schema
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.summary = summary
        self.topics = topics
        self.projects = projects
        self.entities = entities
        self.decisions = decisions
        self.openThreads = openThreads
        self.currentTask = currentTask
        self.isActive = isActive
        self.turns = turns
    }
}

/// Owns only the live conversation. Nothing in this actor is durable until the
/// user explicitly asks the Obsidian service to save a snapshot.
actor NexConversationSession {
    static let recentTurnLimit = 14

    private var conversationID: UUID
    private var createdAt: Date
    private var updatedAt: Date
    private var turns: [NexConversationTurn]
    private var mutationRevision: Int
    private var savedMutationRevision: Int

    init(id: UUID = UUID(), now: Date = Date()) {
        conversationID = id
        createdAt = now
        updatedAt = now
        turns = []
        mutationRevision = 0
        savedMutationRevision = 0
    }

    @discardableResult
    func appendUser(_ text: String, at date: Date = Date()) -> NexConversationTurn? {
        append(role: .user, text: text, at: date, state: .finalized)
    }

    @discardableResult
    func appendAssistant(
        _ text: String,
        interrupted: Bool = false,
        at date: Date = Date()
    ) -> NexConversationTurn? {
        append(
            role: .assistant,
            text: text,
            at: date,
            state: interrupted ? .interrupted : .finalized
        )
    }

    func snapshot(isActive: Bool = true) -> NexConversationSnapshot {
        Self.makeSnapshot(
            id: conversationID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            turns: turns,
            isActive: isActive
        )
    }

    func contextMessages(retrievedContext: String? = nil) -> [NexusChatMessage] {
        let snapshot = snapshot()
        var messages: [NexusChatMessage] = []
        let olderCount = max(0, turns.count - Self.recentTurnLimit)
        if olderCount > 0 || !snapshot.openThreads.isEmpty || snapshot.currentTask != nil {
            var context = "Active conversation continuity:\n"
            if olderCount > 0, !snapshot.summary.isEmpty {
                context += "Rolling summary of earlier turns:\n\(snapshot.summary)\n"
            }
            if let currentTask = snapshot.currentTask {
                context += "Current task: \(currentTask)\n"
            }
            if !snapshot.entities.isEmpty {
                context += "Active entities: \(snapshot.entities.joined(separator: ", "))\n"
            }
            if !snapshot.openThreads.isEmpty {
                context += "Open threads: \(snapshot.openThreads.joined(separator: " | "))\n"
            }
            context += "Resolve short follow-ups, pronouns, ‘why’, ‘continue’, and ‘do that’ against this active conversation."
            messages.append(.init(role: "system", content: context))
        }
        if let retrievedContext, !retrievedContext.isEmpty {
            messages.append(.init(role: "system", content: retrievedContext))
        }
        messages += turns.suffix(Self.recentTurnLimit).map {
            .init(role: $0.role.rawValue, content: $0.text)
        }
        return messages
    }

    func resume(_ snapshot: NexConversationSnapshot) throws {
        guard snapshot.schema == NexConversationSnapshot.schemaVersion else {
            throw NexConversationError.unsupportedSchema(snapshot.schema)
        }
        conversationID = snapshot.id
        createdAt = snapshot.createdAt
        updatedAt = snapshot.updatedAt
        turns = snapshot.turns.filter { !$0.text.isEmpty }
        mutationRevision = 0
        savedMutationRevision = 0
    }

    func markSaved() {
        savedMutationRevision = mutationRevision
    }

    func hasUnsavedChanges() -> Bool {
        !turns.isEmpty && mutationRevision != savedMutationRevision
    }

    func hasValuableUnsavedConversation() -> Bool {
        guard mutationRevision != savedMutationRevision else { return false }
        let finalized = turns.filter { $0.state == .finalized }
        return finalized.contains(where: { $0.role == .user })
            && finalized.contains(where: { $0.role == .assistant })
    }

    func reset(now: Date = Date()) {
        conversationID = UUID()
        createdAt = now
        updatedAt = now
        turns = []
        mutationRevision = 0
        savedMutationRevision = 0
    }

    private func append(
        role: NexConversationRole,
        text: String,
        at date: Date,
        state: NexConversationTurnState
    ) -> NexConversationTurn? {
        let turn = NexConversationTurn(role: role, text: text, createdAt: date, state: state)
        guard !turn.text.isEmpty else { return nil }
        if let last = turns.last,
           last.role == turn.role,
           last.text == turn.text,
           last.state == turn.state {
            return last
        }
        turns.append(turn)
        updatedAt = date
        mutationRevision += 1
        return turn
    }

    private static func makeSnapshot(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        turns: [NexConversationTurn],
        isActive: Bool
    ) -> NexConversationSnapshot {
        let analysis = NexConversationAnalyzer.analyze(turns)
        return .init(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            title: analysis.title,
            summary: analysis.summary,
            topics: analysis.topics,
            projects: analysis.projects,
            entities: analysis.entities,
            decisions: analysis.decisions,
            openThreads: analysis.openThreads,
            currentTask: analysis.currentTask,
            isActive: isActive,
            turns: turns
        )
    }
}

enum NexConversationError: LocalizedError, Equatable {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let schema):
            "This saved conversation uses unsupported schema version \(schema)."
        }
    }
}

private enum NexConversationAnalyzer {
    struct Analysis {
        let title: String
        let summary: String
        let topics: [String]
        let projects: [String]
        let entities: [String]
        let decisions: [String]
        let openThreads: [String]
        let currentTask: String?
    }

    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "been", "being", "could", "does", "from",
        "have", "into", "just", "like", "make", "more", "that", "their", "there", "these",
        "they", "this", "through", "what", "when", "where", "which", "with", "would", "your"
    ]

    static func analyze(_ turns: [NexConversationTurn]) -> Analysis {
        let userTurns = turns.filter { $0.role == .user && $0.state == .finalized }
        let firstPrompt = userTurns.first?.text ?? "Untitled conversation"
        let title = clipped(firstPrompt.replacingOccurrences(of: "\n", with: " "), length: 72)
        let older = turns.dropLast(min(turns.count, NexConversationSession.recentTurnLimit))
        let summarySource = older.isEmpty ? turns.prefix(6) : older.suffix(10)
        let summary = summarySource.map {
            "\($0.role == .user ? "User" : "Nex"): \(clipped($0.text, length: 240))"
        }.joined(separator: "\n")

        let allText = turns.map(\.text).joined(separator: " ")
        let words = tokens(allText)
        var counts: [String: Int] = [:]
        for word in words where word.count >= 4 && !stopWords.contains(word) {
            counts[word, default: 0] += 1
        }
        let topics = counts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(10).map(\.key)
        let entities = namedEntities(in: turns.map(\.text)).prefix(12).map { $0 }
        let projects = entities.filter {
            let lower = $0.lowercased()
            return lower.contains("project") || lower.contains("nexus") || lower.contains("nex")
        }
        let decisions = turns.flatMap { decisionSentences(in: $0.text) }.uniqued().prefix(10).map { $0 }
        let lastTurn = turns.last
        let openThreads: [String]
        if lastTurn?.role == .user || lastTurn?.state == .interrupted {
            openThreads = lastTurn.map { [clipped($0.text, length: 240)] } ?? []
        } else {
            openThreads = userTurns.suffix(3).flatMap { questionSentences(in: $0.text) }.uniqued().prefix(6).map { $0 }
        }
        return Analysis(
            title: title,
            summary: summary,
            topics: topics,
            projects: projects,
            entities: entities,
            decisions: decisions,
            openThreads: openThreads,
            currentTask: userTurns.last.map { clipped($0.text, length: 300) }
        )
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func namedEntities(in texts: [String]) -> [String] {
        let expression = try? NSRegularExpression(pattern: #"\b(?:[A-Z][A-Za-z0-9+#.-]{2,})(?:\s+[A-Z][A-Za-z0-9+#.-]{2,}){0,3}\b"#)
        var entities: [String] = []
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            expression?.matches(in: text, range: range).forEach { match in
                guard let swiftRange = Range(match.range, in: text) else { return }
                let value = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !["What", "Why", "Continue", "Nex"].contains(value) { entities.append(value) }
            }
        }
        return entities.uniqued()
    }

    private static func decisionSentences(in text: String) -> [String] {
        sentences(in: text).filter {
            let lower = $0.lowercased()
            return lower.contains("decided") || lower.contains("decision:")
                || lower.contains("we'll use") || lower.contains("we will use")
        }
    }

    private static func questionSentences(in text: String) -> [String] {
        sentences(in: text).filter { $0.contains("?") }
    }

    private static func sentences(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func clipped(_ text: String, length: Int) -> String {
        guard text.count > length else { return text }
        return String(text.prefix(length)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
