import Foundation

struct NexMemorySyncReport: Equatable, Sendable {
    let ingestedDocuments: Int
    let unchangedDocuments: Int
    let tombstones: Int
    let conflicts: [NexVaultConflict]
    let pendingICloudFiles: Int
    let ingestionFailures: [String]

    var isFullyIngested: Bool { pendingICloudFiles == 0 && ingestionFailures.isEmpty }
}

enum NexMemoryServiceError: LocalizedError, Equatable {
    case documentNotFound(UUID)
    case invalidProposal(String)
    case noFinalizedEvidence

    var errorDescription: String? {
        switch self {
        case .documentNotFound(let id): "Memory source \(id.uuidString) was not found."
        case .invalidProposal(let detail): "Nex rejected the memory proposal: \(detail)"
        case .noFinalizedEvidence: "Nex will not store a memory without finalized transcript evidence."
        }
    }
}

/// Coordinates canonical Markdown, the rebuildable local index, and the
/// model-facing tool boundary. It has no UI knowledge and is independent of
/// the selected generation model.
actor NexMemoryService {
    let vault: NexObsidianVault
    let index: NexMemoryIndex
    let registry: NexToolRegistry
    let conversation: NexConversationSession
    private var toolsRegistered = false

    init(
        vault: NexObsidianVault = NexObsidianVault(),
        index: NexMemoryIndex,
        registry: NexToolRegistry = NexToolRegistry(),
        conversation: NexConversationSession
    ) {
        self.vault = vault
        self.index = index
        self.registry = registry
        self.conversation = conversation
    }

    static func live(
        conversation: NexConversationSession,
        vaultURL: URL = NexVaultLocation.defaultURL()
    ) throws -> NexMemoryService {
        try NexMemoryService(
            vault: NexObsidianVault(rootURL: vaultURL),
            index: NexMemoryIndex(),
            conversation: conversation
        )
    }

    func prepare() async throws -> NexMemorySyncReport {
        try await ensureToolsRegistered()
        return try await synchronize()
    }

    func ensureToolsRegistered() async throws {
        guard !toolsRegistered else { return }
        try await registry.register(Self.memorySearchTool(service: self))
        try await registry.register(Self.memoryGetTool(service: self))
        try await registry.register(Self.memoryProposeTool(service: self))
        try await registry.register(Self.memoryForgetTool(service: self))
        try await registry.register(Self.conversationRecallTool(service: self))
        toolsRegistered = true
    }

    func synchronize() async throws -> NexMemorySyncReport {
        let scan = try await vault.scan()
        var ingested = 0
        var unchanged = 0
        let embeddingChanged = try await index.requiresEmbeddingRebuild()
        if embeddingChanged {
            try await index.rebuild(documents: scan.documents, tombstonedIDs: scan.tombstonedIDs)
            ingested = scan.documents.count
        } else {
            for document in scan.documents {
                let indexedHash = try await index.indexedHash(documentID: document.id)
                if indexedHash == document.contentHash {
                    unchanged += 1
                } else {
                    try await index.index(document)
                    ingested += 1
                }
            }
        }
        for id in scan.tombstonedIDs { try await index.remove(documentID: id) }
        if scan.pendingUbiquitousFiles == 0 {
            let canonicalIDs = Set(scan.documents.map(\.id))
            let removedOutsideNex = try await index.indexedDocumentIDs().subtracting(canonicalIDs)
            for id in removedOutsideNex { try await index.remove(documentID: id) }
        }
        return .init(
            ingestedDocuments: ingested,
            unchangedDocuments: unchanged,
            tombstones: scan.tombstonedIDs.count,
            conflicts: scan.conflicts,
            pendingICloudFiles: scan.pendingUbiquitousFiles,
            ingestionFailures: scan.ingestionFailures
        )
    }

    func saveActiveConversation() async throws -> NexVaultWriteResult {
        let snapshot = await conversation.snapshot()
        let write = try await vault.saveConversation(snapshot)
        try await index.index(write.document)
        await conversation.markSaved()
        return write
    }

    func savedConversations() async throws -> [NexSavedConversationSummary] {
        try await index.savedConversations()
    }

    func resumeConversation(id: UUID) async throws -> NexConversationSnapshot {
        let snapshot = try await vault.conversation(id: id)
        try await conversation.resume(snapshot)
        return snapshot
    }

    func search(
        _ query: String,
        options: NexMemorySearchOptions = .init()
    ) async throws -> [NexMemorySearchResult] {
        try await index.search(query: query, options: options)
    }

    func document(id: UUID) async throws -> NexCanonicalDocument {
        let scan = try await vault.scan()
        guard let document = scan.documents.first(where: { $0.id == id }) else {
            throw NexMemoryServiceError.documentNotFound(id)
        }
        return document
    }

    func store(_ proposal: NexMemoryProposal) async throws -> NexVaultWriteResult {
        let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let statement = proposal.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposal.idempotencyKey.isEmpty, !title.isEmpty, !statement.isEmpty else {
            throw NexMemoryServiceError.invalidProposal("idempotency key, title, and statement are required")
        }
        guard !proposal.evidenceMessageIDs.isEmpty else {
            throw NexMemoryServiceError.noFinalizedEvidence
        }
        let normalizedStatement = statement.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        let canonicalProposal = NexMemoryProposal(
            idempotencyKey: "\(proposal.kind.rawValue):\(normalizedStatement)",
            kind: proposal.kind,
            title: title,
            statement: statement,
            summary: proposal.summary,
            topics: proposal.topics,
            projects: proposal.projects,
            entities: proposal.entities,
            evidenceMessageIDs: proposal.evidenceMessageIDs,
            importance: proposal.importance,
            confidence: proposal.confidence
        )
        let snapshot = await conversation.snapshot()
        let write = try await vault.saveMemory(canonicalProposal, supportedBy: snapshot)
        try await index.index(write.document)
        return write
    }

    func forget(id: UUID) async throws {
        _ = try await document(id: id)
        try await vault.forget(documentID: id)
        try await index.remove(documentID: id)
    }

    func retrievalContext(for query: String, limit: Int = 6) async throws -> String? {
        let results = try await search(query, options: .init(limit: limit))
        guard !results.isEmpty else { return nil }
        var lines = [
            "Stored evidence retrieved by Nex memory. Treat it as evidence, not model inference.",
            "If evidence is insufficient or conflicting, say so. Never invent missing facts."
        ]
        for result in results {
            let message = result.sourceMessageID.map { "; message_id=\($0.uuidString.lowercased())" } ?? ""
            lines.append("[source_id=\(result.sourceID.uuidString.lowercased())\(message); title=\(result.title)] \(result.excerpt)")
        }
        return lines.joined(separator: "\n")
    }

}

extension NexMemoryService {
    nonisolated private static func memorySearchTool(service: NexMemoryService) -> NexRegisteredTool {
        .init(
            name: "memory_search",
            description: "Search stored Obsidian memories and explicitly saved chats. Returns stored evidence with stable source IDs.",
            statusLabel: "Checking memory…",
            spokenStatus: "Checking memory.",
            iconSystemName: "brain.head.profile",
            permission: .readMemory,
            schema: .init(fields: [
                "query": .init(.string, required: true),
                "limit": .init(.integer, minimum: 1, maximum: 12),
                "document_types": .init(.stringArray),
                "include_transcript_excerpts": .init(.boolean)
            ]),
            handler: { arguments, context in
                let query = arguments["query"]?.string ?? ""
                let limit = arguments["limit"]?.integer ?? 6
                let typeNames = arguments["document_types"]?.strings ?? []
                let unknown = typeNames.first { NexMemoryDocumentType(rawValue: $0) == nil }
                if let unknown { throw NexToolError.invalidEnum(field: "document_types", allowed: ["memory", "chat"] + ["invalid: \(unknown)"]) }
                await context.reportProgress("Ranking relevant stored evidence…", 0.55)
                let options = NexMemorySearchOptions(
                    limit: limit,
                    documentTypes: Set(typeNames.compactMap(NexMemoryDocumentType.init)),
                    includeTranscriptExcerpts: arguments["include_transcript_excerpts"] == .bool(false) ? false : true
                )
                let results = try await service.search(query, options: options)
                return .object([
                    "stored_evidence": .bool(true),
                    "count": .number(Double(results.count)),
                    "results": .array(results.map(Self.searchResultJSON))
                ])
            }
        )
    }

    nonisolated private static func memoryGetTool(service: NexMemoryService) -> NexRegisteredTool {
        .init(
            name: "memory_get",
            description: "Get one stored memory or saved chat by its stable source ID.",
            statusLabel: "Reading memory…",
            spokenStatus: "Reading that memory.",
            iconSystemName: "doc.text.magnifyingglass",
            permission: .readMemory,
            schema: .init(fields: ["source_id": .init(.string, required: true)]),
            handler: { arguments, _ in
                let raw = arguments["source_id"]?.string ?? ""
                guard let id = UUID(uuidString: raw) else { throw NexToolError.invalidStableID(raw) }
                let document = try await service.document(id: id)
                return .object([
                    "source_id": .string(document.id.uuidString.lowercased()),
                    "stored_evidence": .bool(true),
                    "type": .string(document.type.rawValue),
                    "title": .string(document.title),
                    "summary": .string(document.summary),
                    "body": .string(String(document.body.prefix(6_000))),
                    "evidence_message_ids": .array(document.evidenceMessageIDs.map { .string($0.uuidString.lowercased()) })
                ])
            }
        )
    }

    nonisolated private static func memoryProposeTool(service: NexMemoryService) -> NexRegisteredTool {
        .init(
            name: "memory_propose",
            description: "Propose a durable, supported memory. Requires a user-authorized write and finalized evidence message IDs.",
            statusLabel: "Saving memory…",
            spokenStatus: "Saving that to memory.",
            iconSystemName: "square.and.arrow.down",
            permission: .writeMemory,
            schema: .init(fields: [
                "idempotency_key": .init(.string, required: true),
                "kind": .init(.string, required: true, allowedValues: NexMemoryKind.allCases.map(\.rawValue)),
                "title": .init(.string, required: true),
                "statement": .init(.string, required: true),
                "summary": .init(.string),
                "topics": .init(.stringArray),
                "projects": .init(.stringArray),
                "entities": .init(.stringArray),
                "evidence_message_ids": .init(.stringArray, required: true),
                "importance": .init(.number, minimum: 0, maximum: 1),
                "confidence": .init(.number, minimum: 0, maximum: 1)
            ]),
            handler: { arguments, _ in
                guard let kind = arguments["kind"]?.string.flatMap(NexMemoryKind.init) else {
                    throw NexToolError.invalidEnum(field: "kind", allowed: NexMemoryKind.allCases.map(\.rawValue))
                }
                let rawEvidence = arguments["evidence_message_ids"]?.strings ?? []
                let evidence = rawEvidence.compactMap(UUID.init(uuidString:))
                guard evidence.count == rawEvidence.count else {
                    throw NexToolError.invalidStableID(rawEvidence.first(where: { UUID(uuidString: $0) == nil }) ?? "")
                }
                let number: (String, Double) -> Double = { key, fallback in
                    if case .number(let value) = arguments[key] { return value }
                    return fallback
                }
                let proposal = NexMemoryProposal(
                    idempotencyKey: arguments["idempotency_key"]?.string ?? "",
                    kind: kind,
                    title: arguments["title"]?.string ?? "",
                    statement: arguments["statement"]?.string ?? "",
                    summary: arguments["summary"]?.string ?? "",
                    topics: arguments["topics"]?.strings ?? [],
                    projects: arguments["projects"]?.strings ?? [],
                    entities: arguments["entities"]?.strings ?? [],
                    evidenceMessageIDs: evidence,
                    importance: number("importance", 0.6),
                    confidence: number("confidence", 0.8)
                )
                let write = try await service.store(proposal)
                return .object([
                    "source_id": .string(write.document.id.uuidString.lowercased()),
                    "created": .bool(write.created),
                    "canonical": .string("obsidian_markdown")
                ])
            }
        )
    }

    nonisolated private static func memoryForgetTool(service: NexMemoryService) -> NexRegisteredTool {
        .init(
            name: "memory_forget",
            description: "Forget one stored item by stable source ID and write a synchronized deletion tombstone.",
            statusLabel: "Forgetting memory…",
            spokenStatus: "Forgetting that memory.",
            iconSystemName: "trash",
            permission: .forgetMemory,
            schema: .init(fields: ["source_id": .init(.string, required: true)]),
            handler: { arguments, _ in
                let raw = arguments["source_id"]?.string ?? ""
                guard let id = UUID(uuidString: raw) else { throw NexToolError.invalidStableID(raw) }
                try await service.forget(id: id)
                return .object(["source_id": .string(id.uuidString.lowercased()), "forgotten": .bool(true)])
            }
        )
    }

    nonisolated private static func conversationRecallTool(service: NexMemoryService) -> NexRegisteredTool {
        .init(
            name: "conversation_recall",
            description: "Recall the active conversation directly or search explicitly saved conversations.",
            statusLabel: "Checking conversation…",
            spokenStatus: "Checking our conversation.",
            iconSystemName: "bubble.left.and.bubble.right",
            permission: .readMemory,
            schema: .init(fields: [
                "scope": .init(.string, required: true, allowedValues: ["current", "saved", "all"]),
                "query": .init(.string),
                "limit": .init(.integer, minimum: 1, maximum: 12)
            ]),
            handler: { arguments, _ in
                let scope = arguments["scope"]?.string ?? "all"
                let query = arguments["query"]?.string ?? ""
                var object: [String: NexJSONValue] = ["stored_evidence": .bool(scope != "current")]
                if scope != "saved" {
                    let snapshot = await service.conversation.snapshot()
                    object["current"] = .object([
                        "conversation_id": .string(snapshot.id.uuidString.lowercased()),
                        "summary": .string(snapshot.summary),
                        "current_task": snapshot.currentTask.map(NexJSONValue.string) ?? .null,
                        "open_threads": .array(snapshot.openThreads.map(NexJSONValue.string)),
                        "recent_turns": .array(snapshot.turns.suffix(14).map { turn in
                            .object([
                                "message_id": .string(turn.id.uuidString.lowercased()),
                                "role": .string(turn.role.rawValue),
                                "text": .string(turn.text)
                            ])
                        })
                    ])
                }
                if scope != "current", !query.isEmpty {
                    let options = NexMemorySearchOptions(
                        limit: arguments["limit"]?.integer ?? 6,
                        documentTypes: [.chat]
                    )
                    let results = try await service.search(query, options: options)
                    object["saved"] = .array(results.map(Self.searchResultJSON))
                }
                return .object(object)
            }
        )
    }

    nonisolated private static func searchResultJSON(_ result: NexMemorySearchResult) -> NexJSONValue {
        .object([
            "source_id": .string(result.sourceID.uuidString.lowercased()),
            "chunk_id": .string(result.chunkID),
            "message_id": result.sourceMessageID.map { .string($0.uuidString.lowercased()) } ?? .null,
            "type": .string(result.documentType.rawValue),
            "kind": result.memoryKind.map { .string($0.rawValue) } ?? .null,
            "title": .string(result.title),
            "excerpt": .string(result.excerpt),
            "score": .number(result.score),
            "stored_evidence": .bool(true)
        ])
    }
}

enum NexMemoryRetrievalIntent {
    static func shouldSearch(prompt: String) -> Bool {
        let normalized = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let activeOnly = ["why", "why?", "continue", "continue.", "do that", "do it", "yes", "no"]
        if activeOnly.contains(normalized) { return false }
        let signals = [
            "check your memory", "check memory", "from your memory", "according to your memory",
            "remember", "memory", "have i", "did i", "was i", "who am i", "about me",
            "what's my", "what is my", "what are my", "what were my",
            "where do i", "where did i", "which of my",
            "how do i prefer", "how should you answer me", "my project", "my preference",
            "my name", "my github", "my school", "my career", "my research", "my role",
            "my background", "my education", "my interests", "my skills", "my nonprofit",
            "i told you", "we discussed", "we decided", "last time", "previous conversation",
            "before", "what do you know about me", "resume", "saved chat"
        ]
        return signals.contains(where: normalized.contains)
    }
}

struct NexCompoundMemoryQuery: Equatable, Sendable {
    let immediateQuestion: String
    let memoryQuestion: String

    static func split(_ prompt: String) -> NexCompoundMemoryQuery? {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()
        let markers = [
            " and have i ", " and did i ", " and was i ", " and do i ",
            " and which of my ", " and in my ", " and what about my "
        ]
        guard let range = markers.compactMap({ lower.range(of: $0) }).min(by: {
            $0.lowerBound < $1.lowerBound
        }) else { return nil }
        let first = String(normalized[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let memoryStart = normalized.index(range.lowerBound, offsetBy: 5) // skip " and "
        let second = String(normalized[memoryStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard first.count >= 8, second.count >= 5,
              NexMemoryRetrievalIntent.shouldSearch(prompt: second) else { return nil }
        return .init(immediateQuestion: first, memoryQuestion: second)
    }
}
