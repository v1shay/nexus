import CryptoKit
import Foundation

enum NexMemoryKind: String, Codable, CaseIterable, Sendable {
    case preference
    case personalContext = "personal_context"
    case project
    case goal
    case person
    case organization
    case decision
    case knowledge

    var folder: String {
        switch self {
        case .preference, .personalContext: "10 Profile"
        case .project: "20 Projects"
        case .goal: "30 Goals"
        case .person: "40 People"
        case .organization: "50 Organizations"
        case .decision: "60 Decisions"
        case .knowledge: "70 Knowledge"
        }
    }
}

enum NexMemoryDocumentType: String, Codable, Hashable, Sendable {
    case chat
    case memory
}

enum NexMemoryDocumentStatus: String, Codable, Sendable {
    case active
    case superseded
    case deleted
    case expired
}

struct NexMemoryProposal: Codable, Equatable, Sendable {
    let idempotencyKey: String
    let kind: NexMemoryKind
    let title: String
    let statement: String
    let summary: String
    let topics: [String]
    let projects: [String]
    let entities: [String]
    let evidenceMessageIDs: [UUID]
    let importance: Double
    let confidence: Double

    init(
        idempotencyKey: String,
        kind: NexMemoryKind,
        title: String,
        statement: String,
        summary: String = "",
        topics: [String] = [],
        projects: [String] = [],
        entities: [String] = [],
        evidenceMessageIDs: [UUID],
        importance: Double = 0.6,
        confidence: Double = 0.8
    ) {
        self.idempotencyKey = idempotencyKey
        self.kind = kind
        self.title = title
        self.statement = statement
        self.summary = summary
        self.topics = topics
        self.projects = projects
        self.entities = entities
        self.evidenceMessageIDs = evidenceMessageIDs
        self.importance = importance
        self.confidence = confidence
    }
}

struct NexIndexedChunk: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    let text: String
    let sourceMessageID: UUID?
    let ordinal: Int
}

struct NexCanonicalDocument: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let id: UUID
    let type: NexMemoryDocumentType
    let memoryKind: NexMemoryKind?
    let relativePath: String
    let title: String
    let summary: String
    let body: String
    let topics: [String]
    let projects: [String]
    let entities: [String]
    let decisions: [String]
    let openThreads: [String]
    let evidenceMessageIDs: [UUID]
    let createdAt: Date
    let updatedAt: Date
    let revision: Int
    let status: NexMemoryDocumentStatus
    let isActiveConversation: Bool
    let importance: Double
    let confidence: Double
    let contentHash: String
    let chunks: [NexIndexedChunk]
    let conversation: NexConversationSnapshot?
}

struct NexVaultWriteResult: Equatable, Sendable {
    let document: NexCanonicalDocument
    let fileURL: URL
    let created: Bool
}

struct NexVaultConflict: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(documentID.uuidString):\(revision)" }
    let documentID: UUID
    let revision: Int
    let eventIDs: [UUID]
    let hashes: [String]
}

struct NexVaultScanResult: Sendable {
    let documents: [NexCanonicalDocument]
    let tombstonedIDs: Set<UUID>
    let conflicts: [NexVaultConflict]
    let pendingUbiquitousFiles: Int
    let ingestionFailures: [String]
}

struct NexVaultEvent: Codable, Equatable, Identifiable, Sendable {
    enum Action: String, Codable, Sendable { case upsert, delete }

    let schema: Int
    let id: UUID
    let documentID: UUID
    let revision: Int
    let parentRevision: Int
    let contentHash: String
    let action: Action
    let deviceID: UUID
    let createdAt: Date
}

struct NexDeletionTombstone: Codable, Equatable, Identifiable, Sendable {
    let schema: Int
    let id: UUID
    let deletedAt: Date
    let deviceID: UUID
    let lastKnownRevision: Int
}

enum NexVaultLocation {
    static func defaultURL(fileManager: FileManager = .default) -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        let obsidianICloud = home
            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents", isDirectory: true)
        if fileManager.fileExists(atPath: obsidianICloud.path) {
            return obsidianICloud.appendingPathComponent("Nex", isDirectory: true)
        }
        let iCloudDrive = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fileManager.fileExists(atPath: iCloudDrive.path) {
            return iCloudDrive.appendingPathComponent("Nex", isDirectory: true)
        }
        return home.appendingPathComponent("Documents/Nex", isDirectory: true)
    }
}

enum NexObsidianVaultError: LocalizedError, Equatable {
    case invalidDocument(String)
    case missingConversation(UUID)
    case unsupportedSchema(Int)
    case unsafePath
    case unsupportedEvidence

    var errorDescription: String? {
        switch self {
        case .invalidDocument(let detail): "Nex could not read the Obsidian document: \(detail)"
        case .missingConversation(let id): "Saved conversation \(id.uuidString) was not found in the Obsidian vault."
        case .unsupportedSchema(let schema): "Obsidian document schema \(schema) is not supported."
        case .unsafePath: "Nex refused an unsafe Obsidian path."
        case .unsupportedEvidence: "The proposed memory is not supported by finalized conversation messages."
        }
    }
}

/// Canonical, human-readable storage. This actor never writes the local index;
/// callers ingest its returned documents separately so Markdown stays the
/// source of truth and can always rebuild every derived database.
actor NexObsidianVault {
    static let folders = [
        "00 Inbox", "10 Profile", "20 Projects", "30 Goals", "40 People",
        "50 Organizations", "60 Decisions", "70 Knowledge", "80 Chats", "90 System",
        ".nex", ".nex/events", ".nex/tombstones"
    ]

    let rootURL: URL
    let deviceID: UUID
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootURL: URL = NexVaultLocation.defaultURL(),
        deviceID: UUID = NexDeviceIdentifier.current
    ) {
        // FileManager may enumerate `/var/...` as `/private/var/...`. Resolve
        // that alias once so a valid file never looks like an absolute path
        // outside the vault when we derive its relative location.
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.deviceID = deviceID
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func prepare() throws {
        for folder in Self.folders {
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let readme = rootURL.appendingPathComponent("90 System/README.md")
        if !fileManager.fileExists(atPath: readme.path) {
            let text = """
            # Nex Memory Vault

            Markdown in this vault is canonical. `.nex` contains small synchronized events and tombstones; each Mac builds its own SQLite retrieval index outside this vault.
            """
            try atomicWrite(Data(text.utf8), to: readme)
        }
    }

    func saveConversation(_ snapshot: NexConversationSnapshot) throws -> NexVaultWriteResult {
        try prepare()
        guard snapshot.schema == NexConversationSnapshot.schemaVersion else {
            throw NexObsidianVaultError.unsupportedSchema(snapshot.schema)
        }
        let preferred = chatRelativePath(id: snapshot.id, createdAt: snapshot.createdAt)
        let relativePath = try existingRelativePath(for: snapshot.id) ?? preferred
        let fileURL = try safeURL(for: relativePath)
        let existing = try? parseDocument(at: fileURL)
        let parentRevision = existing?.revision ?? 0
        let revision = parentRevision + 1
        let markdown = NexMarkdownCodec.renderConversation(
            snapshot,
            revision: revision,
            deviceID: deviceID
        )
        let hash = Self.sha256(markdown)
        try atomicWrite(Data(markdown.utf8), to: fileURL)
        try removeTombstone(id: snapshot.id)
        let event = NexVaultEvent(
            schema: 1,
            id: UUID(),
            documentID: snapshot.id,
            revision: revision,
            parentRevision: parentRevision,
            contentHash: hash,
            action: .upsert,
            deviceID: deviceID,
            createdAt: Date()
        )
        try writeEvent(event)
        let document = try parseDocument(at: fileURL)
        return .init(document: document, fileURL: fileURL, created: existing == nil)
    }

    func saveMemory(
        _ proposal: NexMemoryProposal,
        supportedBy conversation: NexConversationSnapshot
    ) throws -> NexVaultWriteResult {
        try prepare()
        let finalizedIDs = Set(conversation.turns.filter { $0.state == .finalized }.map(\.id))
        guard !proposal.evidenceMessageIDs.isEmpty,
              Set(proposal.evidenceMessageIDs).isSubset(of: finalizedIDs) else {
            throw NexObsidianVaultError.unsupportedEvidence
        }
        let documentID = Self.stableUUID(for: proposal.idempotencyKey)
        let preferred = "\(proposal.kind.folder)/\(proposal.kind.rawValue)-\(documentID.uuidString.lowercased()).md"
        let relativePath = try existingRelativePath(for: documentID) ?? preferred
        let fileURL = try safeURL(for: relativePath)
        let existing = try? parseDocument(at: fileURL)
        let parentRevision = existing?.revision ?? 0
        let revision = parentRevision + 1
        let now = Date()
        let markdown = NexMarkdownCodec.renderMemory(
            id: documentID,
            proposal: proposal,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            revision: revision,
            deviceID: deviceID
        )
        let hash = Self.sha256(markdown)
        try atomicWrite(Data(markdown.utf8), to: fileURL)
        try removeTombstone(id: documentID)
        try writeEvent(.init(
            schema: 1,
            id: UUID(),
            documentID: documentID,
            revision: revision,
            parentRevision: parentRevision,
            contentHash: hash,
            action: .upsert,
            deviceID: deviceID,
            createdAt: now
        ))
        let document = try parseDocument(at: fileURL)
        return .init(document: document, fileURL: fileURL, created: existing == nil)
    }

    func forget(documentID: UUID) throws {
        try prepare()
        let existingPath = try existingRelativePath(for: documentID)
        let existing = try existingPath.flatMap { try parseDocument(at: safeURL(for: $0)) }
        if let existingPath {
            let url = try safeURL(for: existingPath)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        let revision = (existing?.revision ?? 0) + 1
        let tombstone = NexDeletionTombstone(
            schema: 1,
            id: documentID,
            deletedAt: Date(),
            deviceID: deviceID,
            lastKnownRevision: revision
        )
        let tombstoneURL = rootURL.appendingPathComponent(".nex/tombstones/\(documentID.uuidString.lowercased()).json")
        try atomicWrite(try encoder.encode(tombstone), to: tombstoneURL)
        try writeEvent(.init(
            schema: 1,
            id: UUID(),
            documentID: documentID,
            revision: revision,
            parentRevision: existing?.revision ?? 0,
            contentHash: "",
            action: .delete,
            deviceID: deviceID,
            createdAt: Date()
        ))
    }

    func conversation(id: UUID) throws -> NexConversationSnapshot {
        guard let path = try existingRelativePath(for: id) else {
            throw NexObsidianVaultError.missingConversation(id)
        }
        let document = try parseDocument(at: safeURL(for: path))
        guard let conversation = document.conversation else {
            throw NexObsidianVaultError.missingConversation(id)
        }
        return conversation
    }

    func scan() throws -> NexVaultScanResult {
        try prepare()
        let tombstones = try loadTombstones()
        let tombstonedIDs = Set(tombstones.map(\.id))
        var documents: [NexCanonicalDocument] = []
        var pending = 0
        var ingestionFailures: [String] = []
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md", !url.path.contains("/90 System/") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if values?.isUbiquitousItem == true,
               values?.ubiquitousItemDownloadingStatus != .current {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                pending += 1
                continue
            }
            do {
                let document = try parseDocument(at: url)
                if !tombstonedIDs.contains(document.id) { documents.append(document) }
            } catch {
                let relative = (try? relativePathWithinVault(for: url)) ?? url.lastPathComponent
                ingestionFailures.append("\(relative): \(error.localizedDescription)")
            }
        }
        return .init(
            documents: documents,
            tombstonedIDs: tombstonedIDs,
            conflicts: try detectConflicts(),
            pendingUbiquitousFiles: pending,
            ingestionFailures: ingestionFailures.sorted()
        )
    }

    func rebuildableDocuments() throws -> [NexCanonicalDocument] {
        try scan().documents
    }

    private func parseDocument(at url: URL) throws -> NexCanonicalDocument {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw NexObsidianVaultError.invalidDocument("invalid UTF-8")
        }
        let relativePath = try relativePathWithinVault(for: url)
        return try NexMarkdownCodec.parse(markdown, relativePath: relativePath)
    }

    private func chatRelativePath(id: UUID, createdAt: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: createdAt)
        let month = calendar.component(.month, from: createdAt)
        return String(format: "80 Chats/%04d/%02d/chat-%@.md", year, month, id.uuidString.lowercased())
    }

    private func existingRelativePath(for id: UUID) throws -> String? {
        let target = id.uuidString.lowercased()
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md",
                  !url.path.contains("/90 System/"),
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  let prefix = String(data: data.prefix(4_096), encoding: .utf8),
                  prefix.lowercased().contains("id: \"\(target)\"") else { continue }
            return try relativePathWithinVault(for: url)
        }
        return nil
    }

    private func safeURL(for relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw NexObsidianVaultError.unsafePath
        }
        let candidate = rootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(rootURL.path + "/") else { throw NexObsidianVaultError.unsafePath }
        return candidate
    }

    private func relativePathWithinVault(for url: URL) throws -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = rootURL.path + "/"
        guard resolved.path.hasPrefix(prefix) else { throw NexObsidianVaultError.unsafePath }
        return String(resolved.path.dropFirst(prefix.count))
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func writeEvent(_ event: NexVaultEvent) throws {
        let url = rootURL.appendingPathComponent(".nex/events/\(event.id.uuidString.lowercased()).json")
        try atomicWrite(try encoder.encode(event), to: url)
    }

    private func loadEvents() throws -> [NexVaultEvent] {
        let directory = rootURL.appendingPathComponent(".nex/events")
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(NexVaultEvent.self, from: Data(contentsOf: $0)) }
    }

    private func loadTombstones() throws -> [NexDeletionTombstone] {
        let directory = rootURL.appendingPathComponent(".nex/tombstones")
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(NexDeletionTombstone.self, from: Data(contentsOf: $0)) }
    }

    private func removeTombstone(id: UUID) throws {
        let url = rootURL.appendingPathComponent(".nex/tombstones/\(id.uuidString.lowercased()).json")
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func detectConflicts() throws -> [NexVaultConflict] {
        let grouped = Dictionary(grouping: try loadEvents().filter { $0.action == .upsert }) {
            "\($0.documentID.uuidString):\($0.revision)"
        }
        return grouped.values.compactMap { events in
            let hashes = Set(events.map(\.contentHash))
            guard hashes.count > 1, let first = events.first else { return nil }
            return NexVaultConflict(
                documentID: first.documentID,
                revision: first.revision,
                eventIDs: events.map(\.id).sorted { $0.uuidString < $1.uuidString },
                hashes: hashes.sorted()
            )
        }.sorted { $0.id < $1.id }
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func stableUUID(for key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum NexDeviceIdentifier {
    static var current: UUID {
        let key = "nex.memory.device-id"
        if let saved = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: saved) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}

private enum NexMarkdownCodec {
    static func renderConversation(
        _ snapshot: NexConversationSnapshot,
        revision: Int,
        deviceID: UUID
    ) -> String {
        var output = frontmatter(
            id: snapshot.id,
            type: .chat,
            memoryKind: nil,
            title: snapshot.title,
            summary: snapshot.summary,
            topics: snapshot.topics,
            projects: snapshot.projects,
            entities: snapshot.entities,
            decisions: snapshot.decisions,
            openThreads: snapshot.openThreads,
            evidence: snapshot.turns.filter { $0.state == .finalized }.map(\.id),
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            revision: revision,
            status: .active,
            active: snapshot.isActive,
            importance: 0.65,
            confidence: 1,
            deviceID: deviceID
        )
        output += "\n# \(snapshot.title)\n\n"
        output += "## Summary\n\n\(snapshot.summary.isEmpty ? "No summary yet." : snapshot.summary)\n\n"
        output += section("Decisions", values: snapshot.decisions)
        output += section("Open threads", values: snapshot.openThreads)
        output += "## Retrieval guidance\n\nRetrieve for topics: \((snapshot.topics + snapshot.projects + snapshot.entities).joined(separator: ", ")).\n\n"
        output += "## Transcript\n"
        for turn in snapshot.turns {
            output += "\n### \(turn.role == .user ? "User" : "Nex")\n"
            output += "<!-- nex-message: \(turn.id.uuidString.lowercased()) | \(iso(turn.createdAt)) | \(turn.state.rawValue) -->\n"
            output += "\(turn.text)\n"
        }
        return output
    }

    static func renderMemory(
        id: UUID,
        proposal: NexMemoryProposal,
        createdAt: Date,
        updatedAt: Date,
        revision: Int,
        deviceID: UUID
    ) -> String {
        var output = frontmatter(
            id: id,
            type: .memory,
            memoryKind: proposal.kind,
            title: proposal.title,
            summary: proposal.summary.isEmpty ? proposal.statement : proposal.summary,
            topics: proposal.topics,
            projects: proposal.projects,
            entities: proposal.entities,
            decisions: proposal.kind == .decision ? [proposal.statement] : [],
            openThreads: [],
            evidence: proposal.evidenceMessageIDs,
            createdAt: createdAt,
            updatedAt: updatedAt,
            revision: revision,
            status: .active,
            active: true,
            importance: min(1, max(0, proposal.importance)),
            confidence: min(1, max(0, proposal.confidence)),
            deviceID: deviceID
        )
        output += "\n# \(proposal.title)\n\n\(proposal.statement)\n\n"
        output += "## Evidence\n\n"
        output += proposal.evidenceMessageIDs.map { "- Transcript message `\($0.uuidString.lowercased())`" }.joined(separator: "\n")
        output += "\n"
        return output
    }

    static func parse(_ markdown: String, relativePath: String) throws -> NexCanonicalDocument {
        let parsed = try parseFrontmatter(markdown)
        let schema = Int(parsed.scalar("nex_schema") ?? "") ?? 0
        guard schema == NexCanonicalDocument.schemaVersion else {
            throw NexObsidianVaultError.unsupportedSchema(schema)
        }
        guard let idText = parsed.scalar("id"), let id = UUID(uuidString: idText),
              let typeText = parsed.scalar("type"), let type = NexMemoryDocumentType(rawValue: typeText),
              let createdAt = date(parsed.scalar("created_at")),
              let updatedAt = date(parsed.scalar("updated_at")) else {
            throw NexObsidianVaultError.invalidDocument("required frontmatter is missing")
        }
        let status = parsed.scalar("status").flatMap(NexMemoryDocumentStatus.init) ?? .active
        let title = parsed.scalar("title") ?? "Untitled"
        let summary = parsed.scalar("summary") ?? ""
        let topics = parsed.array("topics")
        let projects = parsed.array("projects")
        let entities = parsed.array("entities")
        let decisions = parsed.array("decisions")
        let openThreads = parsed.array("open_threads")
        let evidence = parsed.array("evidence_message_ids").compactMap { UUID(uuidString: $0) }
        let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = type == .chat ? try parseConversation(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            title: title,
            summary: summary,
            topics: topics,
            projects: projects,
            entities: entities,
            decisions: decisions,
            openThreads: openThreads,
            active: Bool(parsed.scalar("active") ?? "") ?? false,
            body: body
        ) : nil
        let chunks = makeChunks(
            documentID: id,
            summary: summary,
            body: body,
            conversation: conversation
        )
        return .init(
            schema: schema,
            id: id,
            type: type,
            memoryKind: parsed.scalar("memory_kind").flatMap(NexMemoryKind.init),
            relativePath: relativePath,
            title: title,
            summary: summary,
            body: body,
            topics: topics,
            projects: projects,
            entities: entities,
            decisions: decisions,
            openThreads: openThreads,
            evidenceMessageIDs: evidence,
            createdAt: createdAt,
            updatedAt: updatedAt,
            revision: Int(parsed.scalar("revision") ?? "") ?? 1,
            status: status,
            isActiveConversation: Bool(parsed.scalar("active") ?? "") ?? false,
            importance: Double(parsed.scalar("importance") ?? "") ?? 0.5,
            confidence: Double(parsed.scalar("confidence") ?? "") ?? 1,
            contentHash: NexObsidianVault.sha256(markdown),
            chunks: chunks,
            conversation: conversation
        )
    }

    private static func frontmatter(
        id: UUID,
        type: NexMemoryDocumentType,
        memoryKind: NexMemoryKind?,
        title: String,
        summary: String,
        topics: [String],
        projects: [String],
        entities: [String],
        decisions: [String],
        openThreads: [String],
        evidence: [UUID],
        createdAt: Date,
        updatedAt: Date,
        revision: Int,
        status: NexMemoryDocumentStatus,
        active: Bool,
        importance: Double,
        confidence: Double,
        deviceID: UUID
    ) -> String {
        var lines = [
            "---",
            "nex_schema: 1",
            "id: \(quote(id.uuidString.lowercased()))",
            "type: \(quote(type.rawValue))",
            "memory_kind: \(quote(memoryKind?.rawValue ?? ""))",
            "title: \(quote(title))",
            "summary: \(quote(summary))",
            "created_at: \(quote(iso(createdAt)))",
            "updated_at: \(quote(iso(updatedAt)))",
            "revision: \(revision)",
            "status: \(quote(status.rawValue))",
            "active: \(active)",
            "importance: \(String(format: "%.3f", importance))",
            "confidence: \(String(format: "%.3f", confidence))",
            "device_id: \(quote(deviceID.uuidString.lowercased()))"
        ]
        appendArray("topics", topics, to: &lines)
        appendArray("projects", projects, to: &lines)
        appendArray("entities", entities, to: &lines)
        appendArray("decisions", decisions, to: &lines)
        appendArray("open_threads", openThreads, to: &lines)
        appendArray("evidence_message_ids", evidence.map { $0.uuidString.lowercased() }, to: &lines)
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func parseConversation(
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
        active: Bool,
        body: String
    ) throws -> NexConversationSnapshot {
        let pattern = #"(?ms)^### (User|Nex)\s*\n<!-- nex-message: ([0-9a-fA-F-]{36}) \| ([^|]+) \| (finalized|interrupted) -->\s*\n(.*?)(?=^### (?:User|Nex)\s*$|\z)"#
        let expression = try NSRegularExpression(pattern: pattern)
        let nsRange = NSRange(body.startIndex..., in: body)
        let turns: [NexConversationTurn] = expression.matches(in: body, range: nsRange).compactMap { match in
            guard let roleRange = Range(match.range(at: 1), in: body),
                  let idRange = Range(match.range(at: 2), in: body),
                  let dateRange = Range(match.range(at: 3), in: body),
                  let stateRange = Range(match.range(at: 4), in: body),
                  let textRange = Range(match.range(at: 5), in: body),
                  let messageID = UUID(uuidString: String(body[idRange])),
                  let turnDate = date(String(body[dateRange]).trimmingCharacters(in: .whitespaces)),
                  let state = NexConversationTurnState(rawValue: String(body[stateRange])) else { return nil }
            return .init(
                id: messageID,
                role: body[roleRange] == "User" ? .user : .assistant,
                text: String(body[textRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                createdAt: turnDate,
                state: state
            )
        }
        return .init(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            title: title,
            summary: summary,
            topics: topics,
            projects: projects,
            entities: entities,
            decisions: decisions,
            openThreads: openThreads,
            currentTask: turns.last(where: { $0.role == .user })?.text,
            isActive: active,
            turns: turns
        )
    }

    private static func makeChunks(
        documentID: UUID,
        summary: String,
        body: String,
        conversation: NexConversationSnapshot?
    ) -> [NexIndexedChunk] {
        var chunks: [NexIndexedChunk] = []
        if !summary.isEmpty {
            chunks.append(.init(
                id: "\(documentID.uuidString.lowercased()):summary",
                kind: "summary",
                text: summary,
                sourceMessageID: nil,
                ordinal: 0
            ))
        }
        if let conversation {
            for (index, turn) in conversation.turns.enumerated() where turn.state == .finalized {
                chunks.append(.init(
                    id: "\(documentID.uuidString.lowercased()):message:\(turn.id.uuidString.lowercased())",
                    kind: turn.role == .user ? "user_transcript" : "assistant_transcript",
                    text: turn.text,
                    sourceMessageID: turn.id,
                    ordinal: index + 1
                ))
            }
        } else {
            for (index, text) in chunk(body, maximumCharacters: 900).enumerated() {
                chunks.append(.init(
                    id: "\(documentID.uuidString.lowercased()):body:\(index)",
                    kind: "memory",
                    text: text,
                    sourceMessageID: nil,
                    ordinal: index + 1
                ))
            }
        }
        return chunks
    }

    private static func chunk(_ text: String, maximumCharacters: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var result: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if current.count + paragraph.count + 2 > maximumCharacters, !current.isEmpty {
                result.append(current)
                current = ""
            }
            if paragraph.count > maximumCharacters {
                if !current.isEmpty { result.append(current); current = "" }
                var remainder = paragraph[...]
                while remainder.count > maximumCharacters {
                    let end = remainder.index(remainder.startIndex, offsetBy: maximumCharacters)
                    result.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
                if !remainder.isEmpty { current = String(remainder) }
            } else {
                current += (current.isEmpty ? "" : "\n\n") + paragraph
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private struct ParsedFrontmatter {
        let values: [String: String]
        let arrays: [String: [String]]
        let body: String
        func scalar(_ key: String) -> String? { values[key] }
        func array(_ key: String) -> [String] { arrays[key] ?? [] }
    }

    private static func parseFrontmatter(_ markdown: String) throws -> ParsedFrontmatter {
        guard markdown.hasPrefix("---\n"), let range = markdown.range(of: "\n---\n", range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex) else {
            throw NexObsidianVaultError.invalidDocument("YAML frontmatter is missing")
        }
        let header = String(markdown[markdown.index(markdown.startIndex, offsetBy: 4)..<range.lowerBound])
        let body = String(markdown[range.upperBound...])
        var values: [String: String] = [:]
        var arrays: [String: [String]] = [:]
        var activeArray: String?
        for line in header.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("  - "), let activeArray {
                arrays[activeArray, default: []].append(unquote(String(line.dropFirst(4))))
                continue
            }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let raw = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty {
                activeArray = key
                arrays[key] = []
            } else {
                activeArray = nil
                values[key] = unquote(raw)
            }
        }
        return .init(values: values, arrays: arrays, body: body)
    }

    private static func appendArray(_ key: String, _ values: [String], to lines: inout [String]) {
        lines.append("\(key):")
        values.forEach { lines.append("  - \(quote($0))") }
    }

    private static func section(_ title: String, values: [String]) -> String {
        var output = "## \(title)\n\n"
        output += values.isEmpty ? "- None\n\n" : values.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        return output
    }

    private static func quote(_ string: String) -> String {
        let data = try? JSONEncoder().encode(string)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func unquote(_ string: String) -> String {
        guard string.hasPrefix("\"") else { return string }
        return (try? JSONDecoder().decode(String.self, from: Data(string.utf8))) ?? string
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter.nex.string(from: date) }
    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISO8601DateFormatter.nex.date(from: string)
    }
}

private extension ISO8601DateFormatter {
    static let nex: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
