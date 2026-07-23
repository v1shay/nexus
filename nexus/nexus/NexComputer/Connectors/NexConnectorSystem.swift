import CryptoKit
import Foundation

struct NexConnectorCapability: Codable, Equatable, Sendable {
    let action: String
    let available: Bool
    let missingScope: String?
    let providerLimitation: String?
}

struct NexConnectorCapabilityDocument: Codable, Equatable, Sendable {
    let provider: String
    let account: String
    let connected: Bool
    let grantedScopes: [String]
    let capabilities: [NexConnectorCapability]
}

extension NexConnectorCapabilityDocument {
    static func disconnected(_ provider: NexConnectorProvider) -> Self {
        let capabilities = NexConnectorManager.specs
            .filter { $0.provider == provider.rawValue }
            .map {
                NexConnectorCapability(
                    action: $0.action,
                    available: false,
                    missingScope: $0.scope,
                    providerLimitation: "Not connected"
                )
            }
        return .init(
            provider: provider.rawValue,
            account: "",
            connected: false,
            grantedScopes: [],
            capabilities: capabilities
        )
    }

    static func connected(_ credential: NexConnectorCredential) -> Self {
        let granted = NexConnectorScopeResolver.logicalScopes(
            for: credential.provider,
            granted: Set(credential.scopes)
        )
        let capabilities = NexConnectorManager.specs
            .filter { $0.provider == credential.provider.rawValue }
            .map { spec -> NexConnectorCapability in
                let supported = NexOfficialConnectorExecutor.supports(action: spec.action)
                let hasScope = spec.scope.isEmpty || granted.contains(spec.scope)
                return .init(
                    action: spec.action,
                    available: supported && hasScope,
                    missingScope: hasScope ? nil : spec.scope,
                    providerLimitation: supported ? nil : "No safe official-API executor is available for this action."
                )
            }
        return .init(
            provider: credential.provider.rawValue,
            account: credential.account,
            connected: true,
            grantedScopes: granted.sorted(),
            capabilities: capabilities
        )
    }
}

enum NexConnectorScopeResolver {
    static func logicalScopes(for provider: NexConnectorProvider, granted: Set<String>) -> Set<String> {
        var output = granted
        switch provider {
        case .google:
            if granted.contains("openid") { output.insert("openid") }
            if granted.contains("https://www.googleapis.com/auth/gmail.readonly") || granted.contains("https://www.googleapis.com/auth/gmail.modify") { output.insert("gmail.readonly") }
            if granted.contains("https://www.googleapis.com/auth/gmail.modify") { output.insert("gmail.modify") }
            if granted.contains("https://www.googleapis.com/auth/calendar.readonly") || granted.contains("https://www.googleapis.com/auth/calendar.events") { output.insert("calendar.readonly") }
            if granted.contains("https://www.googleapis.com/auth/calendar.events") { output.insert("calendar.events") }
            if granted.contains("https://www.googleapis.com/auth/contacts.readonly") { output.insert("contacts.readonly") }
        case .slack:
            if !granted.isDisjoint(with: ["channels:history", "groups:history", "im:history", "mpim:history", "search:read", "channels:read", "users:read"]) { output.insert("slack.history") }
            if !granted.isDisjoint(with: ["chat:write", "reactions:write", "files:write"]) { output.insert("slack.write") }
        case .github:
            if !granted.isDisjoint(with: ["repo", "public_repo", "read:org", "notifications"]) { output.insert("repo.read") }
            if !granted.isDisjoint(with: ["repo", "public_repo"]) { output.insert("repo.write") }
        case .notion:
            // Notion grants capabilities to the integration rather than
            // returning a conventional OAuth scope list. Preserve the scopes
            // selected during authorization as the local least-privilege policy.
            if granted.contains("notion.content.read") { output.insert("notion.content.read") }
            if granted.contains("notion.content.write") { output.insert("notion.content.write") }
        case .discord:
            if granted.contains("guilds") || granted.contains("bot.guilds") { output.insert("bot.guilds") }
        }
        return output
    }
}

struct NexConnectorActionSpec: Sendable {
    let action: String
    let provider: String
    let scope: String
    let description: String
    let risk: NexComputerRiskClass
    let confirmation: NexComputerConfirmationPolicy
}

protocol NexConnectorExecuting: Sendable {
    func execute(provider: String, account: String, action: String, arguments: [String: NexJSONValue]) async throws -> NexJSONValue
}

struct NexDisconnectedConnectorExecutor: NexConnectorExecuting {
    func execute(provider: String, account: String, action: String, arguments: [String: NexJSONValue]) async throws -> NexJSONValue {
        throw NexToolError.executionFailed(code: "connector_unavailable", message: "The \(provider) connector is not authenticated for \(account).")
    }
}

actor NexConnectorManager {
    private let executor: any NexConnectorExecuting
    private let pendingStore: NexConnectorPendingRequestStore
    private var documents: [String: NexConnectorCapabilityDocument] = [:]
    private var registeredActions: Set<String> = []
    init(executor: any NexConnectorExecuting = NexOfficialConnectorExecutor(), pendingStore: NexConnectorPendingRequestStore = NexConnectorPendingRequestStore()) {
        self.executor = executor
        self.pendingStore = pendingStore
    }

    func apply(_ document: NexConnectorCapabilityDocument, to registry: NexComputerRegistry) async throws {
        documents[document.provider] = document
        let declared = Dictionary(uniqueKeysWithValues: Self.specs.filter { $0.provider == document.provider }.map { ($0.action, $0) })
        for spec in declared.values where !registeredActions.contains(spec.action) {
            let manager = self
            do {
                try await registry.register(manifest: Self.manifest(spec)) { arguments, _ in
                    try await manager.executeOrRequest(spec: spec, arguments: arguments)
                }
            } catch NexToolError.duplicateRegistration {
                // A first-party local executor (for example authenticated `gh`)
                // remains authoritative over an equivalent connector action.
            }
            registeredActions.insert(spec.action)
        }
    }

    func capabilityDocument(provider: String) -> NexConnectorCapabilityDocument? { documents[provider] }
    func unavailableCapabilities(provider: String) -> [NexConnectorCapability] { documents[provider]?.capabilities.filter { !$0.available } ?? [] }
    func allDocuments() -> [NexConnectorCapabilityDocument] { documents.values.sorted { $0.provider < $1.provider } }

    func reloadStoredConnections(
        store: any NexConnectorCredentialStoring = NexKeychainConnectorCredentialStore(),
        registry: NexComputerRegistry
    ) async throws {
        for provider in NexConnectorProvider.allCases {
            let document: NexConnectorCapabilityDocument
            if let credential = try store.credential(for: provider) {
                document = .connected(credential)
            } else {
                document = .disconnected(provider)
            }
            try await apply(document, to: registry)
        }
    }

    func pendingRequest(id: UUID) async -> NexConnectorPendingRequest? { await pendingStore.request(id: id) }

    /// Returns the exact saved action and arguments. The caller must feed this
    /// back through `NexComputerRegistry.execute`, which preserves permission
    /// checks and confirmation binding for consequential resumed operations.
    func resumeRequest(id: UUID, expectedArguments: [String: NexJSONValue]? = nil) async throws -> (String, [String: NexJSONValue]) {
        let request = try await pendingStore.consume(id: id, expectedArguments: expectedArguments)
        guard let document = documents[request.provider], document.connected,
              let spec = Self.specs.first(where: { $0.action == request.action }),
              Self.isAvailable(spec: spec, document: document) else {
            throw NexToolError.executionFailed(code: "connector_still_unavailable", message: "\(request.provider.capitalized) is not connected with the required permission.")
        }
        return (request.action, request.arguments)
    }

    private func executeOrRequest(spec: NexConnectorActionSpec, arguments: [String: NexJSONValue]) async throws -> NexJSONValue {
        guard let document = documents[spec.provider], Self.isAvailable(spec: spec, document: document) else {
            let pending = try await pendingStore.create(provider: spec.provider, action: spec.action, arguments: arguments)
            return .object([
                "ok": .bool(false), "status": .string("connection_required"), "provider": .string(spec.provider),
                "action": .string(spec.action), "requestedAction": .string(spec.action),
                "connectionId": .string(pending.id.uuidString), "id": .string(""),
                "items": .array([]), "error": .string("not_connected"),
                "display": .string("Connect \(spec.provider.capitalized) to \(Self.humanPurpose(spec.action)).")
            ])
        }
        return try await executor.execute(provider: spec.provider, account: document.account, action: spec.action, arguments: arguments)
    }

    private static func isAvailable(spec: NexConnectorActionSpec, document: NexConnectorCapabilityDocument) -> Bool {
        document.connected && (spec.scope.isEmpty || document.grantedScopes.contains(spec.scope)) && document.capabilities.contains { $0.action == spec.action && $0.available }
    }

    private static func humanPurpose(_ action: String) -> String {
        action.split(separator: ".").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? "continue"
    }

    static let specs: [NexConnectorActionSpec] = {
        var result: [NexConnectorActionSpec] = []
        func add(_ provider: String, _ scope: String, _ reads: [String], _ writes: [String], _ high: [String] = [], writeScope: String? = nil) {
            result += reads.map { .init(action: $0, provider: provider, scope: scope, description: description($0), risk: .low, confirmation: .never) }
            result += writes.map { .init(action: $0, provider: provider, scope: writeScope ?? scope, description: description($0), risk: high.contains($0) ? .high : .medium, confirmation: .always) }
        }
        add("notion", "notion.content.read", ["notion.search", "notion.read_page", "notion.open_page", "notion.search_databases", "notion.read_database", "notion.query_database"], ["notion.create_page", "notion.update_page", "notion.append_content", "notion.create_database_item", "notion.update_database_item", "notion.archive_page"], ["notion.archive_page"], writeScope: "notion.content.write")
        add("slack", "slack.history", ["slack.search", "slack.list_channels", "slack.open_channel", "slack.read_channel", "slack.read_thread", "slack.list_recent_messages", "slack.draft_message", "slack.get_user", "slack.get_channel"], ["slack.send_draft", "slack.reply_to_thread", "slack.add_reaction", "slack.remove_reaction", "slack.upload_file"], ["slack.send_draft", "slack.reply_to_thread", "slack.upload_file"], writeScope: "slack.write")
        add("google", "gmail.readonly", ["gmail.search", "gmail.triage", "gmail.read", "gmail.read_thread", "gmail.list_labels", "gmail.download_attachment"], ["gmail.draft", "gmail.update_draft", "gmail.send_draft", "gmail.reply_draft", "gmail.forward", "gmail.archive", "gmail.unarchive", "gmail.mark_read", "gmail.mark_unread", "gmail.star", "gmail.unstar", "gmail.apply_label", "gmail.remove_label", "gmail.trash"], ["gmail.send_draft", "gmail.reply_draft", "gmail.forward", "gmail.trash"], writeScope: "gmail.modify")
        add("google", "calendar.readonly", ["calendar.list_calendars", "calendar.list_events", "calendar.view_upcoming", "calendar.search_events", "calendar.get_event", "calendar.find_availability", "calendar.draft_event", "calendar.open_event"], ["calendar.create_event", "calendar.update_event", "calendar.cancel_event", "calendar.delete_event", "calendar.respond_to_invitation", "calendar.create_focus_block", "calendar.create_recurring_event"], ["calendar.create_event", "calendar.update_event", "calendar.cancel_event", "calendar.delete_event", "calendar.respond_to_invitation", "calendar.create_focus_block", "calendar.create_recurring_event"], writeScope: "calendar.events")
        add("google", "contacts.readonly", ["contacts.search", "contacts.get", "contacts.list", "contacts.resolve_person", "contacts.get_email", "contacts.get_phone"], [])
        add("github", "repo.read", ["github.search_repositories", "github.get_repository", "github.list_issues", "github.get_issue", "github.list_pull_requests", "github.get_pull_request", "github.list_notifications", "github.list_workflows", "github.get_workflow_run"], ["github.create_issue", "github.update_issue", "github.comment_issue", "github.create_pull_request", "github.comment_pull_request", "github.merge_pull_request", "github.mark_notification_read", "github.rerun_workflow", "github.cancel_workflow"], ["github.create_issue", "github.update_issue", "github.comment_issue", "github.create_pull_request", "github.comment_pull_request", "github.merge_pull_request", "github.rerun_workflow", "github.cancel_workflow"], writeScope: "repo.write")
        add("discord", "bot.guilds", ["discord.list_guilds", "discord.list_channels", "discord.read_channel", "discord.read_thread", "discord.search_messages", "discord.draft_message"], ["discord.send_draft", "discord.reply", "discord.add_reaction", "discord.remove_reaction", "discord.upload_file"], ["discord.send_draft", "discord.reply", "discord.upload_file"])
        add("google", "openid", ["google.connection_status", "google.account_info", "google.list_capabilities"], ["google.disconnect"], ["google.disconnect"])
        return result
    }()

    private static func description(_ action: String) -> String {
        let words = action.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        return "Use the connected provider's official API to \(words). Inputs are semantic and tokens/raw provider bodies are never exposed."
    }

    private static let input = NexToolInputSchema(fields: [
        "query": .init(.string), "id": .init(.string), "parent_id": .init(.string), "database_id": .init(.string), "channel_id": .init(.string), "thread_id": .init(.string), "message_id": .init(.string), "user_id": .init(.string), "draft_id": .init(.string), "repository": .init(.string), "number": .init(.integer, minimum: 1), "title": .init(.string), "content": .init(.string), "body": .init(.string), "email": .init(.string), "start": .init(.string), "end": .init(.string), "timezone": .init(.string), "location": .init(.string), "description": .init(.string), "attendees": .init(.stringArray), "labels": .init(.stringArray), "recurrence": .init(.stringArray), "calendars": .init(.stringArray), "file_path": .init(.string), "emoji": .init(.string), "limit": .init(.integer, minimum: 1, maximum: 250), "filter": .init(.string), "sort": .init(.string), "response": .init(.string), "calendar_id": .init(.string), "head": .init(.string), "base": .init(.string), "unread": .init(.boolean)
    ])
    private static let output = NexToolInputSchema(fields: [
        "display": .init(.string, required: true), "status": .init(.string, required: true),
        "provider": .init(.string, required: true), "action": .init(.string, required: true),
        "id": .init(.string, required: true), "items": .init(.array, required: true),
        "error": .init(.string, required: true), "ok": .init(.boolean),
        "requestedAction": .init(.string), "connectionId": .init(.string)
    ])
    private static func manifest(_ spec: NexConnectorActionSpec) -> NexComputerActionManifest {
        .init(actionID: spec.action, application: spec.provider.capitalized, provider: "\(spec.provider.capitalized) Connector", description: spec.description, examples: [spec.action.replacingOccurrences(of: ".", with: " ")], aliases: [spec.action.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")], tags: [spec.provider, "connector", spec.action.split(separator: ".").first.map(String.init) ?? spec.provider], inputSchema: input, outputSchema: output, implementationMethod: .connector, requiredPermissions: [.init(id: "oauth.\(spec.provider).\(spec.scope)", permission: .network)], registryPermission: .network, riskClass: spec.risk, confirmationPolicy: spec.confirmation, availabilityCheck: .always, timeoutSeconds: 60, supportsCancellation: true, dryRunBehavior: .supported("Would call \(spec.action) with account-bound OAuth and semantic arguments."), previewRenderer: "connector.\(spec.provider)", tests: ["NexConnectorTests"])
    }
}

struct NexConnectorPendingRequest: Codable, Equatable, Identifiable, Sendable {
    static let schemaVersion = 1
    let version: Int
    let id: UUID
    let provider: String
    let action: String
    let arguments: [String: NexJSONValue]
    let argumentsDigest: String
    let createdAt: Date
    let expiresAt: Date
    var consumedAt: Date?
}

actor NexConnectorPendingRequestStore {
    private struct Snapshot: Codable { let version: Int; let requests: [NexConnectorPendingRequest] }
    private let fileURL: URL
    private let lifetime: TimeInterval
    private var requests: [UUID: NexConnectorPendingRequest]

    init(fileURL: URL? = nil, lifetime: TimeInterval = 15 * 60) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.fileURL = fileURL ?? support.appendingPathComponent("Nexus/NexComputer/pending-connections.json")
        self.lifetime = lifetime
        self.requests = Self.load(fileURL ?? support.appendingPathComponent("Nexus/NexComputer/pending-connections.json"))
    }

    func create(provider: String, action: String, arguments: [String: NexJSONValue], now: Date = .now) throws -> NexConnectorPendingRequest {
        let digest = try Self.digest(arguments)
        if let existing = requests.values.first(where: { $0.action == action && $0.argumentsDigest == digest && $0.consumedAt == nil && $0.expiresAt > now }) { return existing }
        let request = NexConnectorPendingRequest(version: NexConnectorPendingRequest.schemaVersion, id: UUID(), provider: provider, action: action, arguments: arguments, argumentsDigest: digest, createdAt: now, expiresAt: now.addingTimeInterval(lifetime), consumedAt: nil)
        requests[request.id] = request
        try persist()
        return request
    }

    func request(id: UUID, now: Date = .now) -> NexConnectorPendingRequest? {
        guard let value = requests[id], value.consumedAt == nil, value.expiresAt > now else { return nil }
        return value
    }

    func consume(id: UUID, expectedArguments: [String: NexJSONValue]?, now: Date = .now) throws -> NexConnectorPendingRequest {
        guard var value = requests[id] else { throw NexToolError.notFound(id.uuidString) }
        guard value.consumedAt == nil else { throw NexToolError.executionFailed(code: "connection_request_consumed", message: "That connection request was already resumed.") }
        guard value.expiresAt > now else { throw NexToolError.executionFailed(code: "connection_request_expired", message: "That connection request expired.") }
        if let expectedArguments, try Self.digest(expectedArguments) != value.argumentsDigest { throw NexToolError.executionFailed(code: "connection_arguments_changed", message: "The original connector arguments changed; Nexus will not resume them.") }
        value.consumedAt = now
        requests[id] = value
        try persist()
        return value
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let snapshot = Snapshot(version: NexConnectorPendingRequest.schemaVersion, requests: requests.values.sorted { $0.createdAt < $1.createdAt })
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    private static func load(_ url: URL) -> [UUID: NexConnectorPendingRequest] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data), snapshot.version == NexConnectorPendingRequest.schemaVersion else { return [:] }
        return Dictionary(uniqueKeysWithValues: snapshot.requests.map { ($0.id, $0) })
    }

    private static func digest(_ arguments: [String: NexJSONValue]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(arguments)).map { String(format: "%02x", $0) }.joined()
    }
}
