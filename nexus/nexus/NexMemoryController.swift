import AppKit
import Combine
import SwiftUI

@MainActor
final class NexMemoryController: ObservableObject {
    enum SaveState: Equatable {
        case ready
        case saving
        case saved
        case dirty
        case failed(String)

        var label: String {
            switch self {
            case .ready: "Save to Obsidian"
            case .saving: "Saving…"
            case .saved: "Saved"
            case .dirty: "Save New Changes"
            case .failed: "Save Failed"
            }
        }

        var systemImage: String {
            switch self {
            case .ready, .dirty: "square.and.arrow.down"
            case .saving: "arrow.triangle.2.circlepath"
            case .saved: "checkmark"
            case .failed: "exclamationmark.triangle"
            }
        }
    }

    enum SyncState: Equatable {
        case starting
        case syncing
        case synchronized(Date)
        case waitingForICloud(Int)
        case conflicts(Int)
        case unavailable(String)

        var label: String {
            switch self {
            case .starting: "Preparing memory…"
            case .syncing: "Ingesting vault changes…"
            case .synchronized: "Vault changes ingested"
            case .waitingForICloud(let count): "Waiting for \(count) iCloud file\(count == 1 ? "" : "s")"
            case .conflicts(let count): "\(count) vault conflict\(count == 1 ? "" : "s")"
            case .unavailable(let message): message
            }
        }
    }

    @Published private(set) var saveState: SaveState = .ready
    @Published private(set) var syncState: SyncState = .starting
    @Published private(set) var savedConversations: [NexSavedConversationSummary] = []
    @Published private(set) var hasValuableUnsavedConversation = false

    let conversation: NexConversationSession
    let registry: NexToolRegistry
    let service: NexMemoryService?
    let vaultURL: URL
    private var syncTask: Task<Void, Never>?

    init(
        conversation: NexConversationSession,
        vaultURL: URL = NexVaultLocation.defaultURL(),
        databaseURL: URL = NexMemoryIndex.defaultDatabaseURL(),
        embeddingProvider: any NexEmbeddingProviding = NexLocalEmbeddingProvider()
    ) {
        self.conversation = conversation
        self.vaultURL = vaultURL
        let registry = NexToolRegistry()
        self.registry = registry
        if let index = try? NexMemoryIndex(
            databaseURL: databaseURL,
            embeddingProvider: embeddingProvider
        ) {
            service = NexMemoryService(
                vault: NexObsidianVault(rootURL: vaultURL),
                index: index,
                registry: registry,
                conversation: conversation
            )
        } else {
            service = nil
            syncState = .unavailable("Memory index unavailable")
        }
    }

    func start() {
        guard syncTask == nil, let service else { return }
        syncTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await synchronize(using: service)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
    }

    func conversationDidChange() async {
        hasValuableUnsavedConversation = await conversation.hasValuableUnsavedConversation()
        guard await conversation.hasUnsavedChanges() else {
            saveState = .saved
            return
        }
        if saveState == .saved || saveState == .saving {
            saveState = .dirty
        } else if case .failed = saveState {
            saveState = .dirty
        }
    }

    func save() async {
        guard let service, saveState != .saving else { return }
        saveState = .saving
        do {
            _ = try await service.saveActiveConversation()
            savedConversations = try await service.savedConversations()
            hasValuableUnsavedConversation = false
            saveState = .saved
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    func refreshSavedConversations() async {
        guard let service else { return }
        do {
            savedConversations = try await service.savedConversations()
        } catch {
            syncState = .unavailable(error.localizedDescription)
        }
    }

    func resume(id: UUID) async throws -> NexConversationSnapshot {
        guard let service else { throw NexToolError.executionFailed(code: "memory_unavailable", message: "Memory is unavailable.") }
        let snapshot = try await service.resumeConversation(id: id)
        saveState = .saved
        hasValuableUnsavedConversation = false
        return snapshot
    }

    func retrievalContext(for prompt: String) async throws -> String? {
        guard NexMemoryRetrievalIntent.shouldSearch(prompt: prompt) else { return nil }
        guard let service else { return nil }
        try await service.ensureToolsRegistered()
        let output = try await registry.execute(
            name: "memory_search",
            arguments: [
                "query": .string(prompt),
                "limit": .number(6),
                "include_transcript_excerpts": .bool(true),
                "evidence_only": .bool(true)
            ],
            invocation: .modelReadOnly
        )
        guard case .object(let object) = output,
              case .array(let results) = object["results"],
              !results.isEmpty else { return nil }
        var lines = [
            "Stored evidence retrieved by the memory_search tool follows.",
            "Use this evidence silently. Answer naturally without citations, source IDs, evidence labels, titles, brackets, or mentioning the memory tool. The app displays sources separately in the Used memory receipt."
        ]
        for (index, value) in results.prefix(6).enumerated() {
            guard case .object(let result) = value,
                  result["stored_evidence"] == .bool(true),
                  let excerpt = result["excerpt"]?.string else { continue }
            lines.append("Evidence \(index + 1): \(excerpt)")
        }
        return lines.count > 2 ? lines.joined(separator: "\n") : nil
    }

    func storeExplicitRememberRequest(prompt: String, evidenceMessageID: UUID) {
        guard let service, let proposal = Self.explicitProposal(prompt: prompt, evidenceMessageID: evidenceMessageID) else { return }
        // Explicit memory writes are nonessential to response generation and
        // deliberately never block token streaming or speech playback.
        Task {
            do { _ = try await service.store(proposal) }
            catch { NSLog("Nex explicit memory write failed: %@", error.localizedDescription) }
        }
    }

    /// Builds a post-turn classification request for every completed exchange.
    /// There is intentionally no phrase or keyword gate here: the selected
    /// model decides durability from meaning, then deterministic app policy
    /// validates whatever it proposes.
    func automaticMemoryInferenceRequest(
        after assistantMessageID: UUID
    ) async throws -> NexAutomaticMemoryInferenceRequest? {
        guard let service else { return nil }
        let snapshot = await conversation.snapshot()
        guard let assistantIndex = snapshot.turns.firstIndex(where: {
            $0.id == assistantMessageID && $0.role == .assistant && $0.state == .finalized
        }) else { return nil }

        let start = max(0, assistantIndex - 9)
        let relevantTurns = Array(snapshot.turns[start...assistantIndex])
        let supportedUserTurns = relevantTurns.filter {
            $0.role == .user && $0.state == .finalized && !$0.text.isEmpty
        }
        guard !supportedUserTurns.isEmpty else { return nil }

        let query = supportedUserTurns.suffix(3).map(\.text).joined(separator: " ")
        let searchResults = try await service.search(
            query,
            options: .init(
                limit: 10,
                documentTypes: [.memory],
                includeTranscriptExcerpts: false,
                evidenceOnly: true
            )
        )
        var seenCandidates = Set<UUID>()
        let candidates = searchResults.compactMap { result -> NexAutomaticMemoryCandidate? in
            guard seenCandidates.insert(result.sourceID).inserted,
                  let kind = result.memoryKind else { return nil }
            return .init(
                sourceID: result.sourceID,
                kind: kind,
                title: result.title,
                excerpt: String(result.excerpt.prefix(700))
            )
        }
        return NexAutomaticMemoryInferenceRequest(
            conversationID: snapshot.id,
            assistantMessageID: assistantMessageID,
            turns: relevantTurns,
            supportedUserTurns: supportedUserTurns,
            candidates: candidates
        )
    }

    @discardableResult
    func persistAutomaticMemoryInference(
        _ rawResponse: String,
        request: NexAutomaticMemoryInferenceRequest
    ) async throws -> Int {
        guard service != nil else { return 0 }
        let proposals = try NexAutomaticMemoryInferenceParser.proposals(
            from: rawResponse,
            request: request
        )
        guard !proposals.isEmpty else { return 0 }
        try await service?.ensureToolsRegistered()
        var stored = 0
        for proposal in proposals {
            var arguments: [String: NexJSONValue] = [
                "idempotency_key": .string(proposal.idempotencyKey),
                "kind": .string(proposal.kind.rawValue),
                "title": .string(proposal.title),
                "statement": .string(proposal.statement),
                "summary": .string(proposal.summary),
                "topics": .array(proposal.topics.map(NexJSONValue.string)),
                "projects": .array(proposal.projects.map(NexJSONValue.string)),
                "entities": .array(proposal.entities.map(NexJSONValue.string)),
                "evidence_message_ids": .array(
                    proposal.evidenceMessageIDs.map { .string($0.uuidString.lowercased()) }
                ),
                "importance": .number(proposal.importance),
                "confidence": .number(proposal.confidence)
            ]
            if let supersedesSourceID = proposal.supersedesSourceID {
                arguments["supersedes_source_id"] = .string(supersedesSourceID.uuidString.lowercased())
            }
            _ = try await registry.execute(
                name: "memory_propose",
                arguments: arguments,
                invocation: .validatedBackgroundMemoryWrite
            )
            stored += 1
        }
        return stored
    }

    private func synchronize(using service: NexMemoryService) async {
        syncState = .syncing
        do {
            let report = try await service.prepare()
            savedConversations = try await service.savedConversations()
            if !report.conflicts.isEmpty {
                syncState = .conflicts(report.conflicts.count)
            } else if !report.ingestionFailures.isEmpty {
                syncState = .unavailable("\(report.ingestionFailures.count) vault file\(report.ingestionFailures.count == 1 ? "" : "s") could not be ingested")
            } else if !report.isFullyIngested {
                syncState = .waitingForICloud(report.pendingICloudFiles)
            } else {
                syncState = .synchronized(Date())
            }
        } catch {
            syncState = .unavailable(error.localizedDescription)
        }
    }

    private static func explicitProposal(prompt: String, evidenceMessageID: UUID) -> NexMemoryProposal? {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        let prefixes = ["remember that ", "please remember that ", "remember: "]
        guard let prefix = prefixes.first(where: lower.hasPrefix) else { return nil }
        let start = normalized.index(normalized.startIndex, offsetBy: prefix.count)
        let statement = String(normalized[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard statement.count >= 3 else { return nil }
        let kind: NexMemoryKind
        if lower.contains("prefer") { kind = .preference }
        else if lower.contains("project") { kind = .project }
        else if lower.contains("goal") { kind = .goal }
        else if lower.contains("decided") || lower.contains("decision") { kind = .decision }
        else { kind = .knowledge }
        let key = statement.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
        return .init(
            idempotencyKey: "explicit-\(String(key.prefix(180)))",
            kind: kind,
            title: String(statement.prefix(72)),
            statement: statement,
            evidenceMessageIDs: [evidenceMessageID],
            importance: 0.75,
            confidence: 1
        )
    }
}

struct NexAutomaticMemoryCandidate: Equatable, Sendable {
    let sourceID: UUID
    let kind: NexMemoryKind
    let title: String
    let excerpt: String
}

struct NexAutomaticMemoryInferenceRequest: Equatable, Sendable {
    let conversationID: UUID
    let assistantMessageID: UUID
    let turns: [NexConversationTurn]
    let supportedUserTurns: [NexConversationTurn]
    let candidates: [NexAutomaticMemoryCandidate]

    var messages: [NexusChatMessage] {
        let transcript = turns.map { turn in
            let evidence = turn.role == .user && turn.state == .finalized
                ? " evidence_message_id=\(turn.id.uuidString.lowercased())"
                : ""
            return "[\(turn.role.rawValue)\(evidence)] \(turn.text)"
        }.joined(separator: "\n")
        let existing = candidates.isEmpty ? "(none found)" : candidates.map {
            "- source_id=\($0.sourceID.uuidString.lowercased()) kind=\($0.kind.rawValue) title=\($0.title) evidence=\($0.excerpt)"
        }.joined(separator: "\n")
        return [
            .init(role: "system", content: Self.classifierInstructions),
            .init(role: "user", content: """
            Finalized conversation excerpt:
            \(transcript)

            Potentially related existing durable memories:
            \(existing)

            Classify the exchange now. Return only the JSON object.
            """)
        ]
    }

    static let classifierInstructions = """
    You are Nex's conservative durable-memory classifier, not the conversational assistant. For this internal call, these classification and JSON-output rules override the normal Nex persona and response-format instructions.
    Infer meaning; do not look for trigger phrases. Evaluate every finalized exchange.

    Propose a memory only when the user has directly supplied stable information likely to remain useful weeks or months later: a preference, personal context, project, goal, person, organization, decision, or important reusable knowledge. Ordinary wording is enough; the user never needs to say “remember.”

    Never propose questions, requests, commands, temporary moods or plans for today, jokes, hypotheticals, uncertain claims, assistant statements, assistant deductions, generated answers, credentials, passwords, API keys, tokens, private keys, or incomplete/interrupted speech. Do not turn the assistant's response into a fact about the user. Return no proposal when support or future value is doubtful.

    Compare against the supplied existing memories. Skip an unchanged duplicate. For a correction or meaningful update, set supersedes_source_id to the exact supplied source_id and retain one conceptual idempotency_key. Never invent a source ID.

    Every proposal needs confidence >= 0.88 and importance >= 0.70. Cite one or more finalized USER evidence messages and copy a verbatim supporting quote from each. Maximum 3 proposals.

    Return exactly this JSON shape and no Markdown:
    {"proposals":[{"idempotency_key":"stable-concept-key","kind":"preference|personal_context|project|goal|person|organization|decision|knowledge","title":"short title","statement":"one supported standalone fact","summary":"short retrieval summary","topics":["..."],"projects":["..."],"entities":["..."],"evidence":[{"message_id":"uuid","quote":"verbatim user quote"}],"importance":0.85,"confidence":0.95,"supersedes_source_id":null}]}
    If nothing qualifies, return {"proposals":[]}.
    """
}

enum NexAutomaticMemoryInferenceError: LocalizedError, Equatable {
    case invalidJSON
    case invalidShape(String)
    case unsupportedEvidence(UUID)
    case unsupportedQuote(UUID)
    case unsafeContent

    var errorDescription: String? {
        switch self {
        case .invalidJSON: "The memory classifier did not return valid JSON."
        case .invalidShape(let detail): "The memory classifier returned an invalid proposal: \(detail)"
        case .unsupportedEvidence(let id): "Memory evidence \(id.uuidString) was not a finalized user message."
        case .unsupportedQuote(let id): "Memory evidence did not quote user message \(id.uuidString)."
        case .unsafeContent: "Sensitive content cannot be written to durable memory automatically."
        }
    }
}

enum NexAutomaticMemoryInferenceParser {
    private struct Envelope: Decodable {
        let proposals: [RawProposal]
    }

    private struct RawProposal: Decodable {
        let idempotencyKey: String
        let kind: String
        let title: String
        let statement: String
        let summary: String
        let topics: [String]
        let projects: [String]
        let entities: [String]
        let evidence: [RawEvidence]
        let importance: Double
        let confidence: Double
        let supersedesSourceID: String?

        enum CodingKeys: String, CodingKey {
            case idempotencyKey = "idempotency_key"
            case kind, title, statement, summary, topics, projects, entities, evidence, importance, confidence
            case supersedesSourceID = "supersedes_source_id"
        }
    }

    private struct RawEvidence: Decodable {
        let messageID: String
        let quote: String

        enum CodingKeys: String, CodingKey {
            case messageID = "message_id"
            case quote
        }
    }

    static func proposals(
        from rawResponse: String,
        request: NexAutomaticMemoryInferenceRequest
    ) throws -> [NexMemoryProposal] {
        let data = try jsonData(from: rawResponse)
        try validateKnownFields(in: data)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.proposals.count <= 3 else {
            throw NexAutomaticMemoryInferenceError.invalidShape("expected at most three proposals")
        }
        let userEvidence = Dictionary(uniqueKeysWithValues: request.supportedUserTurns.map { ($0.id, $0.text) })
        let candidateIDs = Set(request.candidates.map(\.sourceID))
        var seenKeys = Set<String>()
        return try envelope.proposals.compactMap { raw -> NexMemoryProposal? in
            guard (0.88...1).contains(raw.confidence), (0.70...1).contains(raw.importance) else { return nil }
            guard let kind = NexMemoryKind(rawValue: raw.kind) else {
                throw NexAutomaticMemoryInferenceError.invalidShape("unknown memory kind")
            }
            let title = trimmed(raw.title, maximum: 100)
            let statement = trimmed(raw.statement, maximum: 1_000)
            let summary = trimmed(raw.summary, maximum: 500)
            let suppliedKey = canonicalKey(raw.idempotencyKey)
            let key = genericKeys.contains(suppliedKey)
                ? derivedKey(kind: kind, title: title, projects: raw.projects, entities: raw.entities)
                : suppliedKey
            guard key.count >= 3, !title.isEmpty, statement.count >= 3,
                  raw.evidence.count > 0, raw.evidence.count <= 4 else {
                throw NexAutomaticMemoryInferenceError.invalidShape("required content is missing")
            }
            guard seenKeys.insert("\(kind.rawValue):\(key)").inserted else { return nil }
            var evidenceIDs: [UUID] = []
            for evidence in raw.evidence {
                guard let id = UUID(uuidString: evidence.messageID), let userText = userEvidence[id] else {
                    throw NexAutomaticMemoryInferenceError.unsupportedEvidence(
                        UUID(uuidString: evidence.messageID) ?? UUID()
                    )
                }
                let quote = normalizeEvidence(evidence.quote)
                guard quote.count >= 8, normalizeEvidence(userText).contains(quote) else {
                    throw NexAutomaticMemoryInferenceError.unsupportedQuote(id)
                }
                evidenceIDs.append(id)
            }
            let safetyText = (
                evidenceIDs.compactMap { userEvidence[$0] }
                + [title, statement, summary]
                + raw.topics + raw.projects + raw.entities
            ).joined(separator: " ")
            guard !containsSensitiveContent(safetyText) else {
                throw NexAutomaticMemoryInferenceError.unsafeContent
            }
            let supersedesID: UUID?
            if let rawID = raw.supersedesSourceID {
                guard let id = UUID(uuidString: rawID), candidateIDs.contains(id) else {
                    throw NexAutomaticMemoryInferenceError.invalidShape("unknown supersedes_source_id")
                }
                supersedesID = id
            } else {
                supersedesID = nil
            }
            var seenEvidence = Set<UUID>()
            let orderedEvidenceIDs = evidenceIDs.filter { seenEvidence.insert($0).inserted }
            return NexMemoryProposal(
                idempotencyKey: key,
                kind: kind,
                title: title,
                statement: statement,
                summary: summary,
                topics: bounded(raw.topics),
                projects: bounded(raw.projects),
                entities: bounded(raw.entities),
                evidenceMessageIDs: orderedEvidenceIDs,
                importance: min(1, raw.importance),
                confidence: min(1, raw.confidence),
                supersedesSourceID: supersedesID
            )
        }
    }

    private static func jsonData(from response: String) throws -> Data {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start <= end,
              let data = String(response[start...end]).data(using: .utf8) else {
            throw NexAutomaticMemoryInferenceError.invalidJSON
        }
        return data
    }

    private static func validateKnownFields(in data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["proposals"], let proposals = root["proposals"] as? [[String: Any]] else {
            throw NexAutomaticMemoryInferenceError.invalidJSON
        }
        let proposalFields: Set<String> = [
            "idempotency_key", "kind", "title", "statement", "summary", "topics", "projects",
            "entities", "evidence", "importance", "confidence", "supersedes_source_id"
        ]
        for proposal in proposals {
            guard Set(proposal.keys).isSubset(of: proposalFields),
                  let evidence = proposal["evidence"] as? [[String: Any]],
                  evidence.allSatisfy({ Set($0.keys).isSubset(of: ["message_id", "quote"]) }) else {
                throw NexAutomaticMemoryInferenceError.invalidShape("unknown fields are not allowed")
            }
        }
    }

    private static func canonicalKey(_ value: String) -> String {
        value.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(24).joined(separator: "-")
    }

    private static let genericKeys: Set<String> = [
        "stable-concept-key", "stable-key", "concept-key", "memory-key", "idempotency-key"
    ]

    private static func derivedKey(
        kind: NexMemoryKind,
        title: String,
        projects: [String],
        entities: [String]
    ) -> String {
        let identity = projects.first ?? entities.first ?? title
        let suffix = canonicalKey(identity)
        return suffix.isEmpty ? "\(kind.rawValue)-durable-memory" : "\(kind.rawValue)-\(suffix)"
    }

    private static func trimmed(_ value: String, maximum: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximum))
    }

    private static func bounded(_ values: [String]) -> [String] {
        Array(values.prefix(10)).map { trimmed($0, maximum: 80) }.filter { !$0.isEmpty }
    }

    private static func normalizeEvidence(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func containsSensitiveContent(_ value: String) -> Bool {
        let lower = value.lowercased()
        let labels = ["password", "passcode", "api key", "private key", "access token", "secret key", "bearer token"]
        if labels.contains(where: lower.contains) { return true }
        let patterns = [#"sk-[a-z0-9_-]{16,}"#, #"-----begin [a-z ]*private key-----"#]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}

struct NexSavedChatsView: View {
    @ObservedObject var memory: NexMemoryController
    let resume: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved conversations").font(.title2.weight(.semibold))
                    Text(memory.syncState.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Vault") { NSWorkspace.shared.open(memory.vaultURL) }
            }
            List(memory.savedConversations) { conversation in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(conversation.title).font(.headline)
                        if !conversation.summary.isEmpty {
                            Text(conversation.summary).lineLimit(2).foregroundStyle(.secondary)
                        }
                        if !conversation.openThreads.isEmpty {
                            Text("Open: \(conversation.openThreads.joined(separator: " · "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Resume") { resume(conversation.id) }
                }
                .padding(.vertical, 5)
            }
            if memory.savedConversations.isEmpty {
                ContentUnavailableView(
                    "No Saved Conversations",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Use Save to Obsidian in the Nex overlay first.")
                )
            }
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 420)
        .task { await memory.refreshSavedConversations() }
    }
}
