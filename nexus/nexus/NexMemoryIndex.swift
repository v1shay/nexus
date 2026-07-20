import Foundation
import NaturalLanguage
import SQLite3

protocol NexEmbeddingProviding: Sendable {
    var identifier: String { get }
    func vector(for text: String) -> [Float]
}

/// Uses Apple's on-device word vectors when available and falls back to a
/// deterministic feature-hash vector. The provider boundary lets a later local
/// embedding model replace it and trigger a safe rebuild from Markdown.
final class NexLocalEmbeddingProvider: NexEmbeddingProviding, @unchecked Sendable {
    private let embedding = NLEmbedding.wordEmbedding(for: .english)
    private let fallbackDimensions = 384

    var identifier: String {
        embedding == nil ? "nex-feature-hash-v1" : "apple-natural-language-en-v1"
    }

    func vector(for text: String) -> [Float] {
        let tokens = Self.tokens(text)
        guard let embedding, !tokens.isEmpty else { return hashedVector(tokens) }
        var total: [Double]?
        var count = 0.0
        for token in tokens.prefix(256) {
            guard let source = embedding.vector(for: token) else { continue }
            if total == nil { total = Array(repeating: 0, count: source.count) }
            guard total?.count == source.count else { continue }
            for index in source.indices { total?[index] += source[index] }
            count += 1
        }
        guard var total, count > 0 else { return hashedVector(tokens) }
        for index in total.indices { total[index] /= count }
        return Self.normalized(total.map(Float.init))
    }

    private func hashedVector(_ tokens: [String]) -> [Float] {
        var vector = Array(repeating: Float(0), count: fallbackDimensions)
        for token in tokens.prefix(512) {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in token.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            let index = Int(hash % UInt64(fallbackDimensions))
            vector[index] += (hash & 1) == 0 ? 1 : -1
        }
        return Self.normalized(vector)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func normalized(_ values: [Float]) -> [Float] {
        let magnitude = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 0 else { return values }
        return values.map { $0 / magnitude }
    }
}

struct NexMemorySearchOptions: Codable, Equatable, Sendable {
    var limit: Int
    var documentTypes: Set<NexMemoryDocumentType>
    /// Semantic categories inside canonical Obsidian memory documents, such
    /// as `project` or `preference`. These are intentionally distinct from
    /// the storage-level `documentTypes` (`memory` and `chat`).
    var memoryKinds: Set<String>
    var projects: Set<String>
    var entities: Set<String>
    var includeTranscriptExcerpts: Bool
    var evidenceOnly: Bool

    init(
        limit: Int = 6,
        documentTypes: Set<NexMemoryDocumentType> = [],
        projects: Set<String> = [],
        entities: Set<String> = [],
        includeTranscriptExcerpts: Bool = true,
        evidenceOnly: Bool = false
    ) {
        self.init(
            limit: limit,
            documentTypes: documentTypes,
            memoryKinds: [],
            projects: projects,
            entities: entities,
            includeTranscriptExcerpts: includeTranscriptExcerpts,
            evidenceOnly: evidenceOnly
        )
    }

    init(
        limit: Int = 6,
        documentTypes: Set<NexMemoryDocumentType> = [],
        memoryKinds: Set<String>,
        projects: Set<String> = [],
        entities: Set<String> = [],
        includeTranscriptExcerpts: Bool = true,
        evidenceOnly: Bool = false
    ) {
        self.limit = min(20, max(1, limit))
        self.documentTypes = documentTypes
        self.memoryKinds = memoryKinds
        self.projects = projects
        self.entities = entities
        self.includeTranscriptExcerpts = includeTranscriptExcerpts
        self.evidenceOnly = evidenceOnly
    }
}

struct NexMemorySearchResult: Codable, Equatable, Identifiable, Sendable {
    var id: String { chunkID }
    let sourceID: UUID
    let chunkID: String
    let sourceMessageID: UUID?
    let documentType: NexMemoryDocumentType
    let memoryKind: NexMemoryKind?
    let title: String
    let excerpt: String
    let relativePath: String
    let score: Double
    let updatedAt: Date
    let storedEvidence: Bool
    let sourceRole: NexConversationRole?
}

struct NexSavedConversationSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let summary: String
    let decisions: [String]
    let openThreads: [String]
    let updatedAt: Date
    let relativePath: String
}

enum NexMemoryIndexError: LocalizedError, Equatable {
    case openFailed(String)
    case sqlite(String)
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .openFailed(let detail): "Nex could not open its local memory index: \(detail)"
        case .sqlite(let detail): "Nex memory index failed: \(detail)"
        case .unsupportedSchema(let version): "Nex memory index schema \(version) is newer than this app supports."
        }
    }
}

actor NexMemoryIndex {
    static let schemaVersion = 1
    static let indexFormatVersion = 2

    let databaseURL: URL
    let embeddingIdentifier: String
    private var database: OpaquePointer?
    private var migrated = false
    private let embeddingProvider: any NexEmbeddingProviding
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        databaseURL: URL = NexMemoryIndex.defaultDatabaseURL(),
        embeddingProvider: any NexEmbeddingProviding = NexLocalEmbeddingProvider()
    ) throws {
        self.databaseURL = databaseURL
        self.embeddingProvider = embeddingProvider
        embeddingIdentifier = embeddingProvider.identifier
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            let detail = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let connection { sqlite3_close(connection) }
            throw NexMemoryIndexError.openFailed(detail)
        }
        database = connection
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Nexus/Memory/index.sqlite")
    }

    func indexedHash(documentID: UUID) throws -> String? {
        try ensureMigrated()
        let statement = try prepare("SELECT content_hash FROM documents WHERE id = ? AND deleted = 0 LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(documentID.uuidString.lowercased(), to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, column: 0)
    }

    func indexedDocumentIDs() throws -> Set<UUID> {
        try ensureMigrated()
        let statement = try prepare("SELECT id FROM documents WHERE deleted = 0")
        defer { sqlite3_finalize(statement) }
        var ids = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = UUID(uuidString: text(statement, column: 0)) { ids.insert(id) }
        }
        return ids
    }

    func index(_ document: NexCanonicalDocument) throws {
        try ensureMigrated()
        guard document.status == .active else {
            try remove(documentID: document.id)
            return
        }
        try execute("BEGIN IMMEDIATE")
        do {
            try upsertDocument(document)
            try deleteChunks(documentID: document.id)
            for chunk in document.chunks { try insert(chunk, document: document) }
            try setMetadata(key: "embedding_identifier", value: embeddingIdentifier)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func remove(documentID: UUID) throws {
        try ensureMigrated()
        try execute("BEGIN IMMEDIATE")
        do {
            try deleteChunks(documentID: documentID)
            let statement = try prepare("UPDATE documents SET deleted = 1 WHERE id = ?")
            bind(documentID.uuidString.lowercased(), to: 1, in: statement)
            try stepDone(statement)
            sqlite3_finalize(statement)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func rebuild(documents: [NexCanonicalDocument], tombstonedIDs: Set<UUID>) throws {
        try ensureMigrated()
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM chunks_fts")
            try execute("DELETE FROM chunks")
            try execute("DELETE FROM documents")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        for document in documents where !tombstonedIDs.contains(document.id) { try index(document) }
        for id in tombstonedIDs { try remove(documentID: id) }
        try setMetadata(key: "embedding_identifier", value: embeddingIdentifier)
        try setMetadata(key: "index_format_version", value: String(Self.indexFormatVersion))
    }

    func requiresEmbeddingRebuild() throws -> Bool {
        try ensureMigrated()
        guard let stored = try metadata(key: "embedding_identifier") else { return false }
        return stored != embeddingIdentifier
    }

    func requiresIndexFormatRebuild() throws -> Bool {
        try ensureMigrated()
        return try metadata(key: "index_format_version") != String(Self.indexFormatVersion)
    }

    func savedConversations() throws -> [NexSavedConversationSummary] {
        try ensureMigrated()
        let sql = """
        SELECT id, title, summary, decisions, open_threads, updated_at, relative_path
        FROM documents WHERE type = 'chat' AND deleted = 0
        ORDER BY updated_at DESC
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var result: [NexSavedConversationSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, column: 0)) else { continue }
            result.append(.init(
                id: id,
                title: text(statement, column: 1),
                summary: text(statement, column: 2),
                decisions: decodeStrings(text(statement, column: 3)),
                openThreads: decodeStrings(text(statement, column: 4)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                relativePath: text(statement, column: 6)
            ))
        }
        return result
    }

    func search(
        query: String,
        options: NexMemorySearchOptions = .init()
    ) throws -> [NexMemorySearchResult] {
        try ensureMigrated()
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        var candidates: [String: Candidate] = [:]
        try collectLexicalCandidates(query: normalized, into: &candidates)
        try collectVectorCandidates(query: normalized, into: &candidates)
        let queryTokens = Set(Self.tokens(normalized))
        let now = Date()
        var results: [NexMemorySearchResult] = candidates.values.compactMap { candidate in
            guard options.documentTypes.isEmpty || options.documentTypes.contains(candidate.documentType) else { return nil }
            guard options.memoryKinds.isEmpty || options.memoryKinds.contains(candidate.memoryKind?.rawValue ?? "") else { return nil }
            let isTranscript = candidate.chunkKind == "user_transcript"
                || candidate.chunkKind == "assistant_transcript"
                || candidate.chunkKind == "transcript_excerpt"
            guard options.includeTranscriptExcerpts || !isTranscript else { return nil }
            let projects = Set(candidate.projects.map { $0.lowercased() })
            let entities = Set(candidate.entities.map { $0.lowercased() })
            let requestedProjects = Set(options.projects.map { $0.lowercased() })
            let requestedEntities = Set(options.entities.map { $0.lowercased() })
            guard requestedProjects.isEmpty || !projects.isDisjoint(with: requestedProjects) else { return nil }
            guard requestedEntities.isEmpty || !entities.isDisjoint(with: requestedEntities) else { return nil }

            let sourceRole: NexConversationRole? = switch candidate.chunkKind {
            case "user_transcript": .user
            case "assistant_transcript": .assistant
            default: nil
            }
            let storedEvidence = candidate.documentType == .memory || sourceRole == .user
            guard !options.evidenceOnly || storedEvidence else { return nil }

            let relationTerms = Set((candidate.topics + candidate.projects + candidate.entities).flatMap(Self.tokens))
            let relation = queryTokens.isEmpty ? 0 : Double(queryTokens.intersection(relationTerms).count) / Double(queryTokens.count)
            let ageDays = max(0, now.timeIntervalSince(candidate.updatedAt) / 86_400)
            let recency = exp(-ageDays / 365)
            let sourcePriority: Double = switch (candidate.documentType, candidate.chunkKind) {
            case (.memory, _): 0.22
            case (.chat, "user_transcript"): 0.12
            case (.chat, "summary"): 0.05
            case (.chat, "assistant_transcript"): -0.18
            default: -0.06
            }
            let score = candidate.lexical * 0.38
                + candidate.vector * 0.34
                + relation * 0.12
                + candidate.importance * candidate.confidence * 0.08
                + recency * 0.04
                + sourcePriority
            guard candidate.lexical > 0.05 || candidate.vector > 0.30 || relation > 0 else { return nil }
            return .init(
                sourceID: candidate.documentID,
                chunkID: candidate.chunkID,
                sourceMessageID: candidate.sourceMessageID,
                documentType: candidate.documentType,
                memoryKind: candidate.memoryKind,
                title: candidate.title,
                excerpt: Self.clipped(candidate.text, length: 700),
                relativePath: candidate.relativePath,
                score: score,
                updatedAt: candidate.updatedAt,
                storedEvidence: storedEvidence,
                sourceRole: sourceRole
            )
        }
        results.sort {
            $0.score == $1.score ? $0.chunkID < $1.chunkID : $0.score > $1.score
        }
        var perDocument: [UUID: Int] = [:]
        results = results.filter {
            let count = perDocument[$0.sourceID, default: 0]
            guard count < 2 else { return false }
            perDocument[$0.sourceID] = count + 1
            return true
        }
        return Array(results.prefix(options.limit))
    }

    private struct Candidate {
        let chunkID: String
        let documentID: UUID
        let sourceMessageID: UUID?
        let documentType: NexMemoryDocumentType
        let memoryKind: NexMemoryKind?
        let chunkKind: String
        let title: String
        let text: String
        let relativePath: String
        let topics: [String]
        let projects: [String]
        let entities: [String]
        let updatedAt: Date
        let importance: Double
        let confidence: Double
        var lexical: Double
        var vector: Double
    }

    private func collectLexicalCandidates(query: String, into candidates: inout [String: Candidate]) throws {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return }
        let sql = Self.candidateSelect + " WHERE chunks_fts MATCH ? AND d.deleted = 0 ORDER BY bm25(chunks_fts) LIMIT 80"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(match, to: 1, in: statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            var candidate = decodeCandidate(statement)
            let rank = abs(sqlite3_column_double(statement, 17))
            candidate.lexical = 1 / (1 + rank)
            candidates[candidate.chunkID] = candidate
        }
    }

    private func collectVectorCandidates(query: String, into candidates: inout [String: Candidate]) throws {
        let queryVector = embeddingProvider.vector(for: query)
        guard !queryVector.isEmpty else { return }
        let sql = Self.candidateSelect + " WHERE d.deleted = 0"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var ranked: [(Candidate, Double)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var candidate = decodeCandidate(statement)
            let embeddingData = data(statement, column: 16)
            guard let vector = try? decoder.decode([Float].self, from: embeddingData), vector.count == queryVector.count else { continue }
            let similarity = Double(zip(queryVector, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 })
            candidate.vector = max(0, similarity)
            ranked.append((candidate, candidate.vector))
        }
        for (candidate, _) in ranked.sorted(by: { $0.1 > $1.1 }).prefix(80) {
            if var existing = candidates[candidate.chunkID] {
                existing.vector = candidate.vector
                candidates[candidate.chunkID] = existing
            } else {
                candidates[candidate.chunkID] = candidate
            }
        }
    }

    private static let candidateSelect = """
        SELECT c.id, c.document_id, c.source_message_id, d.type, d.memory_kind,
               c.kind, d.title, c.text, d.relative_path, d.topics, d.projects,
               d.entities, d.updated_at, d.importance, d.confidence,
               c.ordinal, c.embedding, bm25(chunks_fts)
        FROM chunks_fts
        JOIN chunks c ON c.id = chunks_fts.chunk_id
        JOIN documents d ON d.id = c.document_id
        """

    private func decodeCandidate(_ statement: OpaquePointer?) -> Candidate {
        Candidate(
            chunkID: text(statement, column: 0),
            documentID: UUID(uuidString: text(statement, column: 1)) ?? UUID(),
            sourceMessageID: UUID(uuidString: text(statement, column: 2)),
            documentType: NexMemoryDocumentType(rawValue: text(statement, column: 3)) ?? .memory,
            memoryKind: NexMemoryKind(rawValue: text(statement, column: 4)),
            chunkKind: text(statement, column: 5),
            title: text(statement, column: 6),
            text: text(statement, column: 7),
            relativePath: text(statement, column: 8),
            topics: decodeStrings(text(statement, column: 9)),
            projects: decodeStrings(text(statement, column: 10)),
            entities: decodeStrings(text(statement, column: 11)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
            importance: sqlite3_column_double(statement, 13),
            confidence: sqlite3_column_double(statement, 14),
            lexical: 0,
            vector: 0
        )
    }

    private func upsertDocument(_ document: NexCanonicalDocument) throws {
        let sql = """
        INSERT INTO documents (
            id, type, memory_kind, relative_path, title, summary, topics, projects,
            entities, decisions, open_threads, created_at, updated_at, revision,
            status, active, importance, confidence, content_hash, deleted
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
        ON CONFLICT(id) DO UPDATE SET
            type=excluded.type, memory_kind=excluded.memory_kind,
            relative_path=excluded.relative_path, title=excluded.title, summary=excluded.summary,
            topics=excluded.topics, projects=excluded.projects, entities=excluded.entities,
            decisions=excluded.decisions, open_threads=excluded.open_threads,
            created_at=excluded.created_at, updated_at=excluded.updated_at,
            revision=excluded.revision, status=excluded.status, active=excluded.active,
            importance=excluded.importance, confidence=excluded.confidence,
            content_hash=excluded.content_hash, deleted=0
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let values: [String] = [
            document.id.uuidString.lowercased(), document.type.rawValue,
            document.memoryKind?.rawValue ?? "", document.relativePath, document.title,
            document.summary, encodeStrings(document.topics), encodeStrings(document.projects),
            encodeStrings(document.entities), encodeStrings(document.decisions),
            encodeStrings(document.openThreads)
        ]
        for (offset, value) in values.enumerated() { bind(value, to: Int32(offset + 1), in: statement) }
        sqlite3_bind_double(statement, 12, document.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 13, document.updatedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 14, Int32(document.revision))
        bind(document.status.rawValue, to: 15, in: statement)
        sqlite3_bind_int(statement, 16, document.isActiveConversation ? 1 : 0)
        sqlite3_bind_double(statement, 17, document.importance)
        sqlite3_bind_double(statement, 18, document.confidence)
        bind(document.contentHash, to: 19, in: statement)
        try stepDone(statement)
    }

    private func insert(_ chunk: NexIndexedChunk, document: NexCanonicalDocument) throws {
        let vector = embeddingProvider.vector(for: chunk.text)
        let vectorData = (try? encoder.encode(vector)) ?? Data()
        let statement = try prepare("""
            INSERT INTO chunks (id, document_id, kind, source_message_id, text, ordinal, embedding)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        bind(chunk.id, to: 1, in: statement)
        bind(document.id.uuidString.lowercased(), to: 2, in: statement)
        bind(chunk.kind, to: 3, in: statement)
        bind(chunk.sourceMessageID?.uuidString.lowercased() ?? "", to: 4, in: statement)
        bind(chunk.text, to: 5, in: statement)
        sqlite3_bind_int(statement, 6, Int32(chunk.ordinal))
        bind(vectorData, to: 7, in: statement)
        try stepDone(statement)
        sqlite3_finalize(statement)

        let fts = try prepare("INSERT INTO chunks_fts (chunk_id, document_id, text) VALUES (?, ?, ?)")
        bind(chunk.id, to: 1, in: fts)
        bind(document.id.uuidString.lowercased(), to: 2, in: fts)
        bind(chunk.text, to: 3, in: fts)
        try stepDone(fts)
        sqlite3_finalize(fts)
    }

    private func deleteChunks(documentID: UUID) throws {
        let id = documentID.uuidString.lowercased()
        let fts = try prepare("DELETE FROM chunks_fts WHERE document_id = ?")
        bind(id, to: 1, in: fts)
        try stepDone(fts)
        sqlite3_finalize(fts)
        let chunks = try prepare("DELETE FROM chunks WHERE document_id = ?")
        bind(id, to: 1, in: chunks)
        try stepDone(chunks)
        sqlite3_finalize(chunks)
    }

    private func migrate() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
        let version = try scalarInt("PRAGMA user_version")
        guard version <= Self.schemaVersion else { throw NexMemoryIndexError.unsupportedSchema(version) }
        if version == 0 {
            try execute("""
                CREATE TABLE IF NOT EXISTS documents (
                    id TEXT PRIMARY KEY, type TEXT NOT NULL, memory_kind TEXT NOT NULL,
                    relative_path TEXT NOT NULL, title TEXT NOT NULL, summary TEXT NOT NULL,
                    topics TEXT NOT NULL, projects TEXT NOT NULL, entities TEXT NOT NULL,
                    decisions TEXT NOT NULL, open_threads TEXT NOT NULL,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL, revision INTEGER NOT NULL,
                    status TEXT NOT NULL, active INTEGER NOT NULL, importance REAL NOT NULL,
                    confidence REAL NOT NULL, content_hash TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS chunks (
                    id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL, source_message_id TEXT NOT NULL, text TEXT NOT NULL,
                    ordinal INTEGER NOT NULL, embedding BLOB NOT NULL
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS chunks_document ON chunks(document_id)")
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(chunk_id UNINDEXED, document_id UNINDEXED, text, tokenize='unicode61')")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("PRAGMA user_version=1")
        }
    }

    private func ensureMigrated() throws {
        guard !migrated else { return }
        try migrate()
        migrated = true
    }

    private func setMetadata(key: String, value: String) throws {
        let statement = try prepare("INSERT INTO metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        bind(value, to: 2, in: statement)
        try stepDone(statement)
    }

    private func metadata(key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM metadata WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? text(statement, column: 0) : nil
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw NexMemoryIndexError.openFailed("database is closed") }
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw NexMemoryIndexError.sqlite(detail)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let database else { throw NexMemoryIndexError.openFailed("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NexMemoryIndexError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed"
            throw NexMemoryIndexError.sqlite(detail)
        }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, value, -1, nexSQLiteTransient)
    }

    private func bind(_ value: Data, to index: Int32, in statement: OpaquePointer?) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), nexSQLiteTransient)
        }
    }

    private func text(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func data(_ statement: OpaquePointer?, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func encodeStrings(_ values: [String]) -> String {
        let data = (try? encoder.encode(values)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodeStrings(_ value: String) -> [String] {
        (try? decoder.decode([String].self, from: Data(value.utf8))) ?? []
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }

    private static func ftsQuery(_ query: String) -> String {
        tokens(query).prefix(16).map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " OR ")
    }

    private static func clipped(_ text: String, length: Int) -> String {
        guard text.count > length else { return text }
        return String(text.prefix(length)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

private let nexSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
