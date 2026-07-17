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

enum NexResponseMode: String, Equatable, Sendable {
    case prose
    case code

    static func infer(from turns: [NexConversationTurn]) -> NexResponseMode {
        guard let currentIndex = turns.lastIndex(where: { $0.role == .user }) else { return .prose }
        let current = turns[currentIndex].text
        if explicitlyRequestsCode(current) { return .code }

        let followUps: Set<String> = [
            "continue", "keep going", "do that", "do it", "finish it", "yes", "go ahead"
        ]
        let normalized = normalize(current)
        guard followUps.contains(normalized) else { return .prose }
        let previousUser = turns[..<currentIndex].last(where: { $0.role == .user })?.text ?? ""
        return explicitlyRequestsCode(previousUser) ? .code : .prose
    }

    var instruction: String {
        switch self {
        case .prose:
            "Current response mode: PROSE. The current request does not ask for code. Do not output source code, pseudocode, fenced code blocks, programming boilerplate, or a phrase claiming code was created."
        case .code:
            "Current response mode: CODE. The current request asks for implementation or continues an active coding task. Provide only the amount of explanation and code needed to satisfy it."
        }
    }

    private static func explicitlyRequestsCode(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased().replacingOccurrences(of: "’", with: "'")
        if normalized.contains("```") { return true }
        let directPhrases = [
            "write code", "write the code", "give me the code", "show me the code",
            "generate code", "code this", "code it", "implement this", "implement it",
            "write a function", "write a class", "write a script", "create a function",
            "debug this", "fix this code", "fix the bug", "refactor this", "patch this",
            "complete this code", "modify this code", "build this app", "build the app",
            "build this website", "create an api endpoint", "write an sql query"
        ]
        if directPhrases.contains(where: normalized.contains) { return true }
        let languageRequest = #"\b(write|implement|build|create|debug|fix|refactor)\b.{0,32}\b(swift|python|javascript|typescript|rust|java|kotlin|c\+\+|html|css|sql)\b"#
        return normalized.range(of: languageRequest, options: .regularExpression) != nil
    }

    private static func normalize(_ prompt: String) -> String {
        prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
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

    func contextMessages(
        retrievedContext: String? = nil,
        memoryLookupPerformed: Bool = false,
        webContext: String? = nil
    ) -> [NexusChatMessage] {
        let continuityTurns = memoryLookupPerformed ? turns.filter { $0.role == .user } : turns
        let snapshot = Self.makeSnapshot(
            id: conversationID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            turns: continuityTurns,
            isActive: true
        )
        var messages: [NexusChatMessage] = []
        let olderCount = max(0, continuityTurns.count - Self.recentTurnLimit)
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
        let recentTurns = Array(turns.suffix(Self.recentTurnLimit))
        if let currentIndex = recentTurns.lastIndex(where: { $0.role == .user }) {
            let priorTurns = recentTurns[..<currentIndex].filter {
                !memoryLookupPerformed || $0.role == .user
            }
            messages += priorTurns.map {
                .init(role: $0.role.rawValue, content: $0.text)
            }
            appendMemoryAuthority(
                retrievedContext: retrievedContext,
                memoryLookupPerformed: memoryLookupPerformed,
                webContext: webContext,
                to: &messages
            )
            messages.append(.init(
                role: "system",
                content: NexResponseMode.infer(from: turns).instruction
            ))
            messages += recentTurns[currentIndex...].map {
                .init(role: $0.role.rawValue, content: $0.text)
            }
        } else {
            appendMemoryAuthority(
                retrievedContext: retrievedContext,
                memoryLookupPerformed: memoryLookupPerformed,
                webContext: webContext,
                to: &messages
            )
            messages += recentTurns.map { .init(role: $0.role.rawValue, content: $0.text) }
        }
        return messages
    }

    private func appendMemoryAuthority(
        retrievedContext: String?,
        memoryLookupPerformed: Bool,
        webContext: String?,
        to messages: inout [NexusChatMessage]
    ) {
        if let retrievedContext, !retrievedContext.isEmpty {
            messages.append(.init(
                role: "system",
                content: """
                \(retrievedContext)
                Factual authority for the current request: use the stored evidence above silently. It overrides any conflicting factual claim made by an earlier assistant turn. Never repeat the conflicting assistant claim. Do not expose citations, source IDs, evidence labels, or memory-tool details; the app shows sources behind the Used memory receipt. For any requested personal detail absent from the evidence, explicitly say it is not in memory; do not state, infer, or invent it.
                """
            ))
        } else if memoryLookupPerformed {
            messages.append(.init(
                role: "system",
                content: "Nex checked durable memory and found no relevant user-supported evidence. Do not guess a personal fact or reuse an unsupported claim from an earlier assistant response; say that the information is not in memory."
            ))
        }
        if let webContext, !webContext.isEmpty {
            messages.append(.init(role: "system", content: webContext))
        }
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
