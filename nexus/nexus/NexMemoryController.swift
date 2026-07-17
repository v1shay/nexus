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
                "include_transcript_excerpts": .bool(true)
            ],
            invocation: .modelReadOnly
        )
        guard case .object(let object) = output,
              case .array(let results) = object["results"],
              !results.isEmpty else { return nil }
        var lines = [
            "Stored evidence retrieved by the memory_search tool follows.",
            "Stored evidence is not model inference. Cite source_id internally and admit uncertainty or conflicts."
        ]
        for value in results.prefix(6) {
            guard case .object(let result) = value,
                  let sourceID = result["source_id"]?.string,
                  let title = result["title"]?.string,
                  let excerpt = result["excerpt"]?.string else { continue }
            let message = result["message_id"]?.string.map { "; message_id=\($0)" } ?? ""
            lines.append("[source_id=\(sourceID)\(message); title=\(title)] \(excerpt)")
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
