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

/// Action-owned vocabulary for connector capabilities. This is manifest data,
/// not a routing table: generic retrieval ranks these declared descriptions,
/// aliases, examples, and tags just like it does every other tool.
private struct NexConnectorActionSurface: Sendable {
    let application: String
    let provider: String
    let nouns: [String]
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
                try await registry.register(
                    manifest: Self.manifest(spec),
                    availability: { await manager.availability(for: spec) }
                ) { arguments, _ in
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
        for provider in NexConnectorProvider.allCases where provider.supportsUserConnection {
            let document: NexConnectorCapabilityDocument
            if let credential = try store.credential(for: provider) {
                document = .connected(credential)
            } else {
                document = .disconnected(provider)
            }
            try await apply(document, to: registry)
        }
    }

    /// Registers the complete connector surface without reading OAuth tokens.
    /// Headless discovery, planning, and dry-runs must never block behind a
    /// Keychain ACL or an authentication sheet just to determine which tool
    /// names exist. The live app reloads stored connections separately before
    /// it executes an account-bound action.
    func registerDisconnectedCapabilities(on registry: NexComputerRegistry) async throws {
        for provider in NexConnectorProvider.allCases where provider.supportsUserConnection {
            try await apply(.disconnected(provider), to: registry)
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

    private func availability(for spec: NexConnectorActionSpec) -> NexComputerAvailability {
        guard let document = documents[spec.provider], document.connected else {
            return .unavailable(
                "\(spec.provider.capitalized) is not connected.",
                recovery: "Connect \(spec.provider.capitalized) before using \(spec.action)."
            )
        }
        guard let capability = document.capabilities.first(where: { $0.action == spec.action }), capability.available else {
            let reason = document.capabilities.first(where: { $0.action == spec.action })?.providerLimitation
                ?? "\(spec.provider.capitalized) has not granted the required scope."
            return .unavailable(
                reason,
                recovery: "Reconnect \(spec.provider.capitalized) with \(spec.scope) permission before using \(spec.action)."
            )
        }
        return .available
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
        let surface = actionSurface(for: action)
        return "Use the connected \(surface.application) official API to \(humanPurpose(action)). This capability works with \(surface.nouns.joined(separator: ", ")). Inputs are semantic and tokens/raw provider bodies are never exposed."
    }

    private static func actionSurface(for action: String) -> NexConnectorActionSurface {
        switch action.split(separator: ".").first.map(String.init) {
        case "gmail":
            return .init(application: "Gmail", provider: "Google Connector", nouns: ["email", "mail", "inbox", "message", "thread", "label", "attachment"])
        case "calendar":
            return .init(application: "Google Calendar", provider: "Google Connector", nouns: ["calendar", "event", "meeting", "schedule", "invitation", "availability"])
        case "contacts":
            return .init(application: "Google Contacts", provider: "Google Connector", nouns: ["contact", "person", "address book", "email address", "phone number"])
        case "google":
            return .init(application: "Google Account", provider: "Google Connector", nouns: ["Google account", "connected service", "OAuth connection", "authorization"])
        case "notion":
            return .init(application: "Notion", provider: "Notion Connector", nouns: ["Notion page", "workspace", "database", "block", "document"])
        case "slack":
            return .init(application: "Slack", provider: "Slack Connector", nouns: ["Slack channel", "message", "conversation", "thread", "reaction", "workspace"])
        case "github":
            return .init(application: "GitHub", provider: "GitHub Connector", nouns: ["repository", "issue", "pull request", "workflow", "notification", "comment"])
        case "discord":
            return .init(application: "Discord", provider: "Discord Connector", nouns: ["Discord server", "channel", "message", "thread", "reaction"])
        default:
            return .init(application: "Connected Service", provider: "Connector", nouns: ["connected account", "remote data"])
        }
    }

    /// Field templates are deliberately projected into a small schema per
    /// action below. Giving every connector every field made a Calendar
    /// query look relevant to Contacts because `calendar_id` leaked into its
    /// lexical index, and also let models supply arguments an endpoint never
    /// reads. The action contract is now the source of both validation and
    /// natural-language discovery.
    private static let inputFields: [String: NexToolFieldSchema] = [
        "query": .init(.string, description: "Natural-language search criteria."),
        "id": .init(.string, description: "Stable identifier returned by a prior action."),
        "parent_id": .init(.string, description: "Parent page identifier for a new item."),
        "database_id": .init(.string, description: "Notion database identifier."),
        "channel_id": .init(.string, description: "Slack or Discord channel identifier."),
        "thread_id": .init(.string, description: "Email, Slack, or Discord thread identifier."),
        "message_id": .init(.string, description: "Email or chat message identifier."),
        "user_id": .init(.string, description: "Slack user identifier."),
        "draft_id": .init(.string, description: "Nexus connector draft identifier."),
        "repository": .init(.string, description: "GitHub repository in owner/name form."),
        "number": .init(.integer, description: "GitHub issue or pull-request number.", minimum: 1),
        "title": .init(.string, description: "Human-readable title or subject."),
        "content": .init(.string, description: "Message or document content."),
        "body": .init(.string, description: "Message or document body."),
        "email": .init(.string, description: "Email address or sender filter."),
        "start": .init(.string, description: "ISO-8601 start time."),
        "end": .init(.string, description: "ISO-8601 end time."),
        "timezone": .init(.string, description: "IANA timezone for calendar times."),
        "location": .init(.string, description: "Calendar event location."),
        "description": .init(.string, description: "Calendar event description."),
        "attendees": .init(.stringArray, description: "Calendar attendee email addresses."),
        "labels": .init(.stringArray, description: "Gmail labels or GitHub issue labels."),
        "recurrence": .init(.stringArray, description: "Calendar recurrence rules."),
        "calendars": .init(.stringArray, description: "Calendar identifiers for availability."),
        "file_path": .init(.string, description: "Absolute local file path to upload."),
        "emoji": .init(.string, description: "Slack or Discord reaction emoji."),
        "limit": .init(.integer, description: "Maximum number of results.", minimum: 1, maximum: 250),
        "filter": .init(.string, description: "Provider-supported state or query filter."),
        "sort": .init(.string, description: "Provider-supported sort order."),
        "response": .init(.string, description: "Your Google Calendar invitation response.", allowedValues: ["accepted", "declined", "tentative"]),
        "calendar_id": .init(.string, description: "Google Calendar identifier; defaults to primary."),
        "head": .init(.string, description: "GitHub source branch for a pull request."),
        "base": .init(.string, description: "GitHub destination branch for a pull request."),
        "unread": .init(.boolean, description: "Restrict Gmail search to unread mail.")
    ]

    private static func inputSchema(for action: String) -> NexToolInputSchema {
        switch action {
        case "notion.search", "notion.search_databases": return schema(optional: ["query", "limit"])
        case "notion.read_page", "notion.open_page", "notion.archive_page": return schema(required: ["id"])
        case "notion.read_database": return schema(required: ["database_id"])
        case "notion.query_database": return schema(required: ["database_id"], optional: ["filter", "sort", "limit"])
        case "notion.create_page": return schema(required: ["parent_id", "title"], optional: ["content", "body"])
        case "notion.create_database_item": return schema(required: ["database_id", "title"], optional: ["content", "body"])
        case "notion.update_page", "notion.update_database_item": return schema(required: ["id"], optional: ["title"])
        case "notion.append_content": return schema(required: ["id", "content"])

        case "slack.search": return schema(required: ["query"], optional: ["limit"])
        case "slack.list_channels": return schema(optional: ["limit"])
        case "slack.open_channel", "slack.get_channel": return schema(required: ["channel_id"])
        case "slack.read_channel", "slack.list_recent_messages": return schema(required: ["channel_id"], optional: ["limit"])
        case "slack.read_thread": return schema(required: ["channel_id", "thread_id"], optional: ["limit"])
        case "slack.get_user": return schema(required: ["user_id"])
        case "slack.draft_message": return schema(required: ["channel_id", "content"], optional: ["thread_id"])
        case "slack.send_draft": return schema(required: ["draft_id"])
        case "slack.reply_to_thread": return schema(required: ["channel_id", "thread_id", "content"])
        case "slack.add_reaction", "slack.remove_reaction": return schema(required: ["channel_id", "message_id", "emoji"])
        case "slack.upload_file": return schema(required: ["file_path"])

        case "gmail.search", "gmail.triage": return schema(optional: ["query", "email", "title", "unread", "labels", "limit"])
        case "gmail.read": return schema(required: ["message_id"])
        case "gmail.read_thread": return schema(required: ["thread_id"])
        case "gmail.list_labels": return schema()
        case "gmail.download_attachment": return schema(required: ["message_id", "id"])
        case "gmail.draft": return schema(required: ["email", "title", "content"])
        case "gmail.update_draft": return schema(required: ["draft_id", "email", "title", "content"])
        case "gmail.send_draft": return schema(required: ["draft_id"])
        case "gmail.reply_draft", "gmail.forward": return schema(required: ["email", "title", "content"], optional: ["thread_id"])
        case "gmail.archive", "gmail.unarchive", "gmail.mark_read", "gmail.mark_unread", "gmail.star", "gmail.unstar", "gmail.trash": return schema(required: ["message_id"])
        case "gmail.apply_label", "gmail.remove_label": return schema(required: ["message_id", "labels"])

        case "calendar.list_calendars": return schema(optional: ["limit"])
        case "calendar.list_events", "calendar.view_upcoming": return schema(optional: ["calendar_id", "start", "end", "limit"])
        case "calendar.search_events": return schema(required: ["query"], optional: ["calendar_id", "start", "end", "limit"])
        case "calendar.get_event", "calendar.open_event": return schema(required: ["id"], optional: ["calendar_id"])
        case "calendar.find_availability": return schema(required: ["start", "end"], optional: ["calendars", "calendar_id", "timezone"])
        case "calendar.draft_event", "calendar.create_event", "calendar.create_focus_block", "calendar.create_recurring_event": return schema(required: ["title", "start", "end"], optional: ["calendar_id", "description", "content", "location", "attendees", "recurrence", "timezone"])
        case "calendar.update_event": return schema(required: ["id"], optional: ["calendar_id", "title", "start", "end", "description", "content", "location", "attendees", "recurrence", "timezone"])
        case "calendar.respond_to_invitation": return schema(required: ["id", "response"], optional: ["calendar_id"])
        case "calendar.cancel_event", "calendar.delete_event": return schema(required: ["id"], optional: ["calendar_id"])

        case "contacts.search", "contacts.resolve_person", "contacts.get_email", "contacts.get_phone": return schema(required: ["query"], optional: ["limit"])
        case "contacts.list": return schema(optional: ["limit"])
        case "contacts.get": return schema(required: ["id"])

        case "github.search_repositories": return schema(required: ["query"], optional: ["limit"])
        case "github.get_repository": return schema(required: ["repository"])
        case "github.list_issues", "github.list_pull_requests": return schema(required: ["repository"], optional: ["filter", "limit"])
        case "github.get_issue", "github.get_pull_request": return schema(required: ["repository", "number"])
        case "github.create_issue": return schema(required: ["repository", "title"], optional: ["body", "labels"])
        case "github.update_issue": return schema(required: ["repository", "number"], optional: ["title", "body", "filter"])
        case "github.comment_issue", "github.comment_pull_request": return schema(required: ["repository", "number", "body"])
        case "github.create_pull_request": return schema(required: ["repository", "title", "head", "base"], optional: ["body"])
        case "github.merge_pull_request": return schema(required: ["repository", "number"], optional: ["title", "body"])
        case "github.list_notifications": return schema(optional: ["limit"])
        case "github.mark_notification_read": return schema(required: ["id"])
        case "github.list_workflows": return schema(required: ["repository"], optional: ["limit"])
        case "github.get_workflow_run", "github.rerun_workflow", "github.cancel_workflow": return schema(required: ["repository", "id"])

        case "discord.list_guilds": return schema(optional: ["limit"])
        case "discord.list_channels": return schema(required: ["id"])
        case "discord.read_channel", "discord.search_messages": return schema(required: ["channel_id"], optional: ["limit"])
        case "discord.read_thread": return schema(required: ["thread_id"], optional: ["limit"])
        case "discord.draft_message", "discord.send_draft", "discord.reply": return schema(required: ["channel_id", "content"])
        case "discord.add_reaction", "discord.remove_reaction": return schema(required: ["channel_id", "message_id", "emoji"])
        case "discord.upload_file": return schema(required: ["file_path"])

        case "google.connection_status", "google.account_info", "google.list_capabilities", "google.disconnect": return schema()
        default: return schema()
        }
    }

    private static func schema(required: [String] = [], optional: [String] = []) -> NexToolInputSchema {
        let requiredSet = Set(required)
        let selected = required + optional.filter { !requiredSet.contains($0) }
        return .init(fields: Dictionary(uniqueKeysWithValues: selected.map { name in
            let template = inputFields[name]!
            return (name, .init(
                template.type,
                required: requiredSet.contains(name),
                description: template.description,
                allowedValues: template.allowedValues,
                minimum: template.minimum,
                maximum: template.maximum,
                deprecated: template.deprecated
            ))
        }))
    }

    private static func intentAliases(for action: String) -> [String] {
        switch humanPurpose(action) {
        case "search", "search events", "search messages", "search repositories":
            return ["find", "look up", "locate", "search"]
        case "list", "list channels", "list events", "list calendars", "list guilds", "list labels", "list workflows", "list notifications", "list recent messages", "list pull requests", "list issues":
            return ["show", "browse", "list"]
        default:
            return []
        }
    }
    private static let output = NexToolInputSchema(fields: [
        "display": .init(.string, required: true), "status": .init(.string, required: true),
        "provider": .init(.string, required: true), "action": .init(.string, required: true),
        "id": .init(.string, required: true), "items": .init(.array, required: true),
        "error": .init(.string, required: true), "ok": .init(.boolean),
        "requestedAction": .init(.string), "connectionId": .init(.string)
    ])
    private static func manifest(_ spec: NexConnectorActionSpec) -> NexComputerActionManifest {
        let surface = actionSurface(for: spec.action)
        let operation = humanPurpose(spec.action)
        let namespace = spec.action.split(separator: ".").first.map(String.init) ?? spec.provider
        let intents = intentAliases(for: spec.action)
        return .init(
            actionID: spec.action,
            application: surface.application,
            provider: surface.provider,
            description: spec.description,
            examples: ["\(operation.capitalized) in \(surface.application)."],
            // Broad domain nouns live in the action description. Only the
            // discovery-oriented operations declare them as high-weight
            // aliases, so “find an email” prefers search over an arbitrary
            // read, archive, or label action in the same connector.
            aliases: [operation, "\(operation) \(surface.application)"] + intents.map { "\($0) \(surface.nouns.joined(separator: " "))" },
            tags: [namespace, "connector", operation] + intents,
            inputSchema: inputSchema(for: spec.action),
            outputSchema: output,
            implementationMethod: .connector,
            requiredPermissions: [.init(id: "oauth.\(spec.provider).\(spec.scope)", permission: .network)],
            registryPermission: .network,
            riskClass: spec.risk,
            confirmationPolicy: spec.confirmation,
            availabilityCheck: .always,
            timeoutSeconds: 60,
            supportsCancellation: true,
            dryRunBehavior: .supported("Would call \(spec.action) with account-bound OAuth and semantic arguments."),
            previewRenderer: "connector.\(spec.provider)",
            tests: ["NexConnectorTests"]
        )
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
