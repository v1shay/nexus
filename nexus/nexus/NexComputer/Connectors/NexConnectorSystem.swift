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
    private var documents: [String: NexConnectorCapabilityDocument] = [:]
    private var registeredActions: Set<String> = []
    init(executor: any NexConnectorExecuting = NexDisconnectedConnectorExecutor()) { self.executor = executor }

    func apply(_ document: NexConnectorCapabilityDocument, to registry: NexComputerRegistry) async throws {
        guard document.connected else { documents[document.provider] = document; return }
        documents[document.provider] = document
        let declared = Dictionary(uniqueKeysWithValues: Self.specs.filter { $0.provider == document.provider }.map { ($0.action, $0) })
        for capability in document.capabilities where capability.available && !registeredActions.contains(capability.action) {
            guard let spec = declared[capability.action], document.grantedScopes.contains(spec.scope) || spec.scope.isEmpty else { continue }
            let executor = executor, account = document.account
            try await registry.register(manifest: Self.manifest(spec)) { arguments, _ in
                try await executor.execute(provider: spec.provider, account: account, action: spec.action, arguments: arguments)
            }
            registeredActions.insert(spec.action)
        }
    }

    func capabilityDocument(provider: String) -> NexConnectorCapabilityDocument? { documents[provider] }
    func unavailableCapabilities(provider: String) -> [NexConnectorCapability] { documents[provider]?.capabilities.filter { !$0.available } ?? [] }
    func allDocuments() -> [NexConnectorCapabilityDocument] { documents.values.sorted { $0.provider < $1.provider } }

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
        "query": .init(.string), "id": .init(.string), "parent_id": .init(.string), "database_id": .init(.string), "channel_id": .init(.string), "thread_id": .init(.string), "message_id": .init(.string), "user_id": .init(.string), "draft_id": .init(.string), "repository": .init(.string), "number": .init(.integer, minimum: 1), "title": .init(.string), "content": .init(.string), "body": .init(.string), "email": .init(.string), "start": .init(.string), "end": .init(.string), "timezone": .init(.string), "location": .init(.string), "description": .init(.string), "attendees": .init(.stringArray), "labels": .init(.stringArray), "recurrence": .init(.stringArray), "file_path": .init(.string), "emoji": .init(.string), "limit": .init(.integer, minimum: 1, maximum: 250), "filter": .init(.string), "sort": .init(.string), "response": .init(.string), "calendar_id": .init(.string)
    ])
    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "provider": .init(.string, required: true), "action": .init(.string, required: true), "id": .init(.string, required: true), "items": .init(.array, required: true), "error": .init(.string, required: true)])
    private static func manifest(_ spec: NexConnectorActionSpec) -> NexComputerActionManifest {
        .init(actionID: spec.action, application: spec.provider.capitalized, provider: "\(spec.provider.capitalized) Connector", description: spec.description, examples: [spec.action.replacingOccurrences(of: ".", with: " ")], aliases: [spec.action.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")], tags: [spec.provider, "connector", spec.action.split(separator: ".").first.map(String.init) ?? spec.provider], inputSchema: input, outputSchema: output, implementationMethod: .connector, requiredPermissions: [.init(id: "oauth.\(spec.provider).\(spec.scope)", permission: .network)], registryPermission: .network, riskClass: spec.risk, confirmationPolicy: spec.confirmation, availabilityCheck: .always, timeoutSeconds: 60, supportsCancellation: true, dryRunBehavior: .supported("Would call \(spec.action) with account-bound OAuth and semantic arguments."), previewRenderer: "connector.\(spec.provider)", tests: ["NexConnectorTests"])
    }
}
