import Foundation

protocol NexConnectorAPITransporting: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct NexURLSessionConnectorTransport: NexConnectorAPITransporting {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NexToolError.executionFailed(code: "connector_invalid_response", message: "The provider returned an invalid HTTP response.")
        }
        return (data, http)
    }
}

struct NexConnectorRequestPlan: Equatable, Sendable {
    let method: String
    let url: URL
    let body: NexJSONValue?
}

/// Official-API connector executor. The model supplies only semantic fields;
/// this boundary chooses provider endpoints, adds credentials internally, and
/// returns a compact structured result. Tokens and raw request bodies never
/// cross back into the tool result or activity log.
actor NexOfficialConnectorExecutor: NexConnectorExecuting {
    private let session: NexAuthenticatedConnectorSession
    private let transport: any NexConnectorAPITransporting
    private var localDrafts: [String: (provider: String, action: String, arguments: [String: NexJSONValue])] = [:]

    init(
        session: NexAuthenticatedConnectorSession = NexAuthenticatedConnectorSession(),
        transport: any NexConnectorAPITransporting = NexURLSessionConnectorTransport()
    ) {
        self.session = session
        self.transport = transport
    }

    static func supports(action: String) -> Bool {
        NexConnectorRequestPlanner.supportedActions.contains(action)
    }

    func execute(
        provider: String,
        account: String,
        action: String,
        arguments: [String: NexJSONValue]
    ) async throws -> NexJSONValue {
        guard let providerID = NexConnectorProvider(rawValue: provider) else {
            throw NexToolError.executionFailed(code: "connector_provider_unknown", message: "Unknown connector provider: \(provider).")
        }
        let credential = try await session.validCredential(for: providerID)
        guard credential.account == account else {
            throw NexToolError.executionFailed(code: "connector_account_changed", message: "The connected account changed. Re-run the request for the current account.")
        }
        if Self.localDraftActions.contains(action) {
            let draftID = UUID().uuidString.lowercased()
            localDrafts[draftID] = (provider, action, arguments)
            return .object([
                "display": .string("Draft ready for review."), "status": .string("completed"),
                "provider": .string(provider), "action": .string(action), "id": .string(draftID),
                "items": .array([.object(["draft_id": .string(draftID)])]), "error": .string("")
            ])
        }
        var resolvedArguments = arguments
        if let draftID = arguments["draft_id"]?.string, let draft = localDrafts[draftID], draft.provider == provider {
            resolvedArguments = draft.arguments.merging(arguments) { _, current in current }
        }
        let plan = try NexConnectorRequestPlanner.plan(provider: providerID, action: action, arguments: resolvedArguments)
        var request = URLRequest(url: plan.url)
        request.httpMethod = plan.method
        request.timeoutInterval = 55
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(credential.tokenType) \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Nexus/1.0", forHTTPHeaderField: "User-Agent")
        if providerID == .notion { request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version") }
        if let body = plan.body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.connectorAPI.encode(body)
        }

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                try? await session.markRevoked(providerID)
            }
            throw NexToolError.executionFailed(
                code: "connector_http_\(response.statusCode)",
                message: Self.safeError(data: data, provider: providerID)
            )
        }
        try await session.markSuccessful(credential)
        if let draftID = arguments["draft_id"]?.string { localDrafts[draftID] = nil }
        let value = Self.safeJSON(data)
        return .object([
            "display": .string(Self.display(action: action, value: value)),
            "status": .string("completed"),
            "provider": .string(provider),
            "action": .string(action),
            "id": .string(Self.stableID(value) ?? UUID().uuidString.lowercased()),
            "items": .array(Self.items(value)),
            "error": .string("")
        ])
    }

    private static let localDraftActions: Set<String> = ["slack.draft_message", "calendar.draft_event", "discord.draft_message"]

    private static func safeJSON(_ data: Data) -> NexJSONValue {
        guard !data.isEmpty, let decoded = try? JSONDecoder().decode(NexJSONValue.self, from: data) else { return .object([:]) }
        return decoded
    }

    private static func items(_ value: NexJSONValue) -> [NexJSONValue] {
        if let array = value.array { return Array(array.prefix(100)) }
        guard let object = value.object else { return [] }
        for key in ["results", "items", "messages", "channels", "members", "files", "calendars", "events", "values"] {
            if let array = object[key]?.array { return Array(array.prefix(100)) }
        }
        return [value]
    }

    private static func stableID(_ value: NexJSONValue) -> String? {
        guard let object = value.object else { return nil }
        return object["id"]?.string ?? object["draftId"]?.string ?? object["ts"]?.string
    }

    private static func display(action: String, value: NexJSONValue) -> String {
        let count = items(value).count
        let verb = action.split(separator: ".").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? "request"
        return count > 1 ? "Completed \(verb) with \(count) results." : "Completed \(verb)."
    }

    private static func safeError(data: Data, provider: NexConnectorProvider) -> String {
        guard let object = (try? JSONDecoder().decode(NexJSONValue.self, from: data))?.object else {
            return "\(provider.title) rejected the request."
        }
        let nested = object["error"]?.object
        return nested?["message"]?.string
            ?? object["error_description"]?.string
            ?? object["message"]?.string
            ?? object["error"]?.string
            ?? "\(provider.title) rejected the request."
    }
}

enum NexConnectorRequestPlanner {
    static let supportedActions = Set(NexConnectorManager.specs.map(\.action)).subtracting(["discord.upload_file", "google.disconnect"])

    static func plan(
        provider: NexConnectorProvider,
        action: String,
        arguments: [String: NexJSONValue]
    ) throws -> NexConnectorRequestPlan {
        guard supportedActions.contains(action) else {
            throw NexToolError.executionFailed(code: "connector_action_unsupported", message: "No official API executor is registered for \(action).")
        }
        switch provider {
        case .notion: return try notion(action, arguments)
        case .slack: return try slack(action, arguments)
        case .google: return try google(action, arguments)
        case .github: return try github(action, arguments)
        case .discord: return try discord(action, arguments)
        }
    }

    private static func notion(_ action: String, _ args: [String: NexJSONValue]) throws -> NexConnectorRequestPlan {
        let base = "https://api.notion.com/v1"
        switch action {
        case "notion.search":
            return json("POST", base + "/search", ["query": args["query"] ?? .string(""), "page_size": .number(Double(limit(args)))])
        case "notion.search_databases":
            return json("POST", base + "/search", ["query": args["query"] ?? .string(""), "filter": .object(["property": .string("object"), "value": .string("database")]), "page_size": .number(Double(limit(args)))])
        case "notion.read_page", "notion.open_page": return get(base + "/pages/\(try required("id", args).urlPathEncoded)")
        case "notion.read_database": return get(base + "/databases/\(try required("database_id", args).urlPathEncoded)")
        case "notion.query_database": return json("POST", base + "/databases/\(try required("database_id", args).urlPathEncoded)/query", queryBody(args))
        case "notion.create_page": return json("POST", base + "/pages", notionPageBody(args, parentKey: "page_id"))
        case "notion.create_database_item": return json("POST", base + "/pages", notionPageBody(args, parentKey: "database_id"))
        case "notion.update_page", "notion.update_database_item": return json("PATCH", base + "/pages/\(try required("id", args).urlPathEncoded)", notionProperties(args))
        case "notion.append_content": return json("PATCH", base + "/blocks/\(try required("id", args).urlPathEncoded)/children", ["children": .array([paragraph(args["content"]?.string ?? args["body"]?.string ?? "")])])
        case "notion.archive_page": return json("PATCH", base + "/pages/\(try required("id", args).urlPathEncoded)", ["archived": .bool(true)])
        default: return try unsupported(action)
        }
    }

    private static func slack(_ action: String, _ args: [String: NexJSONValue]) throws -> NexConnectorRequestPlan {
        let base = "https://slack.com/api/"
        switch action {
        case "slack.search": return query(base + "search.messages", ["query": try required("query", args), "count": "\(limit(args))"])
        case "slack.list_channels": return query(base + "conversations.list", ["limit": "\(limit(args))", "exclude_archived": "true"])
        case "slack.open_channel", "slack.get_channel": return query(base + "conversations.info", ["channel": try required("channel_id", args)])
        case "slack.read_channel", "slack.list_recent_messages": return query(base + "conversations.history", ["channel": try required("channel_id", args), "limit": "\(limit(args))"])
        case "slack.read_thread": return query(base + "conversations.replies", ["channel": try required("channel_id", args), "ts": try required("thread_id", args), "limit": "\(limit(args))"])
        case "slack.get_user": return query(base + "users.info", ["user": try required("user_id", args)])
        case "slack.draft_message": return try unsupported(action) // intercepted by the executor's local draft store
        case "slack.send_draft", "slack.reply_to_thread": return json("POST", base + "chat.postMessage", slackMessage(args, includeSchedule: false))
        case "slack.add_reaction": return json("POST", base + "reactions.add", slackReaction(args))
        case "slack.remove_reaction": return json("POST", base + "reactions.remove", slackReaction(args))
        case "slack.upload_file": return json("POST", base + "files.getUploadURLExternal", ["filename": .string(URL(fileURLWithPath: try required("file_path", args)).lastPathComponent), "length": .number(0)])
        default: return try unsupported(action)
        }
    }

    private static func google(_ action: String, _ args: [String: NexJSONValue]) throws -> NexConnectorRequestPlan {
        if action.hasPrefix("gmail.") { return try gmail(action, args) }
        if action.hasPrefix("calendar.") { return try calendar(action, args) }
        if action.hasPrefix("contacts.") { return try contacts(action, args) }
        switch action {
        case "google.connection_status", "google.account_info": return get("https://openidconnect.googleapis.com/v1/userinfo")
        case "google.list_capabilities": return get("https://www.googleapis.com/oauth2/v3/tokeninfo")
        case "google.disconnect": return try unsupported(action) // credential removal is handled by connector management
        default: return try unsupported(action)
        }
    }

    private static func gmail(_ action: String, _ args: [String: NexJSONValue]) throws -> NexConnectorRequestPlan {
        let base = "https://gmail.googleapis.com/gmail/v1/users/me"
        switch action {
        case "gmail.search", "gmail.triage": return query(base + "/messages", ["q": args["query"]?.string ?? gmailQuery(args), "maxResults": "\(limit(args))"])
        case "gmail.read": return get(base + "/messages/\(try required("message_id", args).urlPathEncoded)?format=metadata")
        case "gmail.read_thread": return get(base + "/threads/\(try required("thread_id", args).urlPathEncoded)?format=metadata")
        case "gmail.list_labels": return get(base + "/labels")
        case "gmail.download_attachment": return get(base + "/messages/\(try required("message_id", args).urlPathEncoded)/attachments/\(try required("id", args).urlPathEncoded)")
        case "gmail.draft": return json("POST", base + "/drafts", ["message": .object(["raw": .string(rfc822(args))])])
        case "gmail.update_draft": return json("PUT", base + "/drafts/\(try required("draft_id", args).urlPathEncoded)", ["message": .object(["raw": .string(rfc822(args))])])
        case "gmail.send_draft": return json("POST", base + "/drafts/send", ["id": .string(try required("draft_id", args))])
        case "gmail.reply_draft", "gmail.forward": return json("POST", base + "/drafts", ["message": .object(["raw": .string(rfc822(args)), "threadId": args["thread_id"] ?? .null])])
        case "gmail.archive": return modifyGmail(base, args, add: [], remove: ["INBOX"])
        case "gmail.unarchive": return modifyGmail(base, args, add: ["INBOX"], remove: [])
        case "gmail.mark_read": return modifyGmail(base, args, add: [], remove: ["UNREAD"])
        case "gmail.mark_unread": return modifyGmail(base, args, add: ["UNREAD"], remove: [])
        case "gmail.star": return modifyGmail(base, args, add: ["STARRED"], remove: [])
        case "gmail.unstar": return modifyGmail(base, args, add: [], remove: ["STARRED"])
        case "gmail.apply_label": return modifyGmail(base, args, add: args["labels"]?.strings ?? [], remove: [])
        case "gmail.remove_label": return modifyGmail(base, args, add: [], remove: args["labels"]?.strings ?? [])
        case "gmail.trash": return json("POST", base + "/messages/\(try required("message_id", args).urlPathEncoded)/trash", [:])
        default: return try unsupported(action)
        }
    }

    private static func calendar(_ action: String, _ args: [String: NexJSONValue]) throws -> NexConnectorRequestPlan {
        let base = "https://www.googleapis.com/calendar/v3", calendarID = (args["calendar_id"]?.string ?? "primary").urlPathEncoded
        switch action {
        case "calendar.list_calendars": return query(base + "/users/me/calendarList", ["maxResults": "\(limit(args))"])
        case "calendar.list_events", "calendar.view_upcoming", "calendar.search_events":
            return query(base + "/calendars/\(calendarID)/events", calendarQuery(args))
        case "calendar.get_event", "calendar.open_event": return get(base + "/calendars/\(calendarID)/events/\(try required("id", args).urlPathEncoded)")
        case "calendar.find_availability": return json("POST", base + "/freeBusy", ["timeMin": args["start"] ?? .string(""), "timeMax": args["end"] ?? .string(""), "timeZone": args["timezone"] ?? .string("UTC"), "items": .array((args["calendars"]?.strings ?? [args["calendar_id"]?.string ?? "primary"]).map { .object(["id": .string($0)]) })])
        case "calendar.draft_event": return try unsupported(action) // intercepted by the executor's local draft store
        case "calendar.create_event", "calendar.create_focus_block", "calendar.create_recurring_event": return json("POST", base + "/calendars/\(calendarID)/events", calendarEvent(args, draft: false))
        case "calendar.update_event", "calendar.respond_to_invitation": return json("PATCH", base + "/calendars/\(calendarID)/events/\(try required("id", args).urlPathEncoded)", calendarEvent(args, draft: false))
        case "calendar.cancel_event": return json("PATCH", base + "/calendars/\(calendarID)/events/\(try required("id", args).urlPathEncoded)", ["status": .string("cancelled")])
        case "calendar.delete_event": return json("DELETE", base + "/calendars/\(calendarID)/events/\(try required("id", args).urlPathEncoded)", [:])
        default: return try unsupported(action)
        }
    }

    private static func contacts(_ action: String, _ args: [String: NexJSONValue]) throws -> NexConnectorRequestPlan {
        let people = "https://people.googleapis.com/v1"
        switch action {
        case "contacts.search", "contacts.resolve_person", "contacts.get_email", "contacts.get_phone": return query(people + "/people:searchContacts", ["query": try required("query", args), "readMask": "names,emailAddresses,phoneNumbers,organizations", "pageSize": "\(limit(args))"])
        case "contacts.list": return query(people + "/people/me/connections", ["personFields": "names,emailAddresses,phoneNumbers,organizations", "pageSize": "\(limit(args))"])
        case "contacts.get": return query(people + "/\(try required("id", args).urlPathEncoded)", ["personFields": "names,emailAddresses,phoneNumbers,organizations"])
        default: return try unsupported(action)
        }
    }

    private static func github(_ action: String, _ args: [String: NexJSONValue]) throws -> NexConnectorRequestPlan {
        let base = "https://api.github.com", repo = args["repository"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func repoPath() throws -> String { guard let repo, repo.split(separator: "/").count == 2 else { throw NexToolError.missingField("repository") }; return "/repos/\(repo)" }
        switch action {
        case "github.search_repositories": return query(base + "/search/repositories", ["q": try required("query", args), "per_page": "\(limit(args))"])
        case "github.get_repository": return get(base + (try repoPath()))
        case "github.list_issues": return query(base + (try repoPath()) + "/issues", ["per_page": "\(limit(args))", "state": args["filter"]?.string ?? "open"])
        case "github.get_issue": return get(base + (try repoPath()) + "/issues/\(try requiredNumber(args))")
        case "github.create_issue": return json("POST", base + (try repoPath()) + "/issues", compact(["title": args["title"], "body": args["body"], "labels": args["labels"]]))
        case "github.update_issue": return json("PATCH", base + (try repoPath()) + "/issues/\(try requiredNumber(args))", compact(["title": args["title"], "body": args["body"], "state": args["filter"]]))
        case "github.comment_issue": return json("POST", base + (try repoPath()) + "/issues/\(try requiredNumber(args))/comments", ["body": args["body"] ?? args["content"] ?? .string("")])
        case "github.list_pull_requests": return query(base + (try repoPath()) + "/pulls", ["per_page": "\(limit(args))", "state": args["filter"]?.string ?? "open"])
        case "github.get_pull_request": return get(base + (try repoPath()) + "/pulls/\(try requiredNumber(args))")
        case "github.create_pull_request": return json("POST", base + (try repoPath()) + "/pulls", compact(["title": args["title"], "body": args["body"], "head": args["head"], "base": args["base"]]))
        case "github.comment_pull_request": return json("POST", base + (try repoPath()) + "/issues/\(try requiredNumber(args))/comments", ["body": args["body"] ?? .string("")])
        case "github.merge_pull_request": return json("PUT", base + (try repoPath()) + "/pulls/\(try requiredNumber(args))/merge", compact(["commit_title": args["title"], "commit_message": args["body"]]))
        case "github.list_notifications": return query(base + "/notifications", ["per_page": "\(limit(args))"])
        case "github.mark_notification_read": return json("PATCH", base + "/notifications/threads/\(try required("id", args).urlPathEncoded)", [:])
        case "github.list_workflows": return query(base + (try repoPath()) + "/actions/workflows", ["per_page": "\(limit(args))"])
        case "github.get_workflow_run": return get(base + (try repoPath()) + "/actions/runs/\(try required("id", args).urlPathEncoded)")
        case "github.rerun_workflow": return json("POST", base + (try repoPath()) + "/actions/runs/\(try required("id", args).urlPathEncoded)/rerun", [:])
        case "github.cancel_workflow": return json("POST", base + (try repoPath()) + "/actions/runs/\(try required("id", args).urlPathEncoded)/cancel", [:])
        default: return try unsupported(action)
        }
    }

    private static func discord(_ action: String, _ args: [String: NexJSONValue]) throws -> NexConnectorRequestPlan {
        let base = "https://discord.com/api/v10"
        switch action {
        case "discord.list_guilds": return query(base + "/users/@me/guilds", ["limit": "\(min(limit(args), 200))"])
        case "discord.list_channels": return get(base + "/guilds/\(try required("id", args).urlPathEncoded)/channels")
        case "discord.read_channel", "discord.search_messages": return query(base + "/channels/\(try required("channel_id", args).urlPathEncoded)/messages", ["limit": "\(min(limit(args), 100))"])
        case "discord.read_thread": return query(base + "/channels/\(try required("thread_id", args).urlPathEncoded)/messages", ["limit": "\(min(limit(args), 100))"])
        case "discord.draft_message": return try unsupported(action) // intercepted by the executor's local draft store
        case "discord.send_draft", "discord.reply": return json("POST", base + "/channels/\(try required("channel_id", args).urlPathEncoded)/messages", ["content": args["content"] ?? args["body"] ?? .string("")])
        case "discord.add_reaction": return json("PUT", base + "/channels/\(try required("channel_id", args).urlPathEncoded)/messages/\(try required("message_id", args).urlPathEncoded)/reactions/\(try required("emoji", args).urlPathEncoded)/@me", [:])
        case "discord.remove_reaction": return json("DELETE", base + "/channels/\(try required("channel_id", args).urlPathEncoded)/messages/\(try required("message_id", args).urlPathEncoded)/reactions/\(try required("emoji", args).urlPathEncoded)/@me", [:])
        case "discord.upload_file": throw NexToolError.executionFailed(code: "discord_upload_requires_multipart", message: "Discord upload requires a bot/application multipart executor and is unavailable for a user OAuth connection.")
        default: return try unsupported(action)
        }
    }

    private static func get(_ raw: String) -> NexConnectorRequestPlan { .init(method: "GET", url: URL(string: raw)!, body: nil) }
    private static func json(_ method: String, _ raw: String, _ body: [String: NexJSONValue]) -> NexConnectorRequestPlan { .init(method: method, url: URL(string: raw)!, body: .object(body)) }
    private static func query(_ raw: String, _ items: [String: String]) -> NexConnectorRequestPlan {
        var components = URLComponents(string: raw)!
        components.queryItems = items.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        return .init(method: "GET", url: components.url!, body: nil)
    }
    private static func required(_ key: String, _ args: [String: NexJSONValue]) throws -> String { guard let value = args[key]?.string, !value.isEmpty else { throw NexToolError.missingField(key) }; return value }
    private static func requiredNumber(_ args: [String: NexJSONValue]) throws -> Int { guard let value = args["number"]?.integer else { throw NexToolError.missingField("number") }; return value }
    private static func limit(_ args: [String: NexJSONValue]) -> Int { min(250, max(1, args["limit"]?.integer ?? 25)) }
    private static func unsupported(_ action: String) throws -> NexConnectorRequestPlan { throw NexToolError.executionFailed(code: "connector_action_unsupported", message: "No official endpoint mapping exists for \(action).") }
    private static func compact(_ values: [String: NexJSONValue?]) -> [String: NexJSONValue] { values.compactMapValues { $0 } }

    private static func queryBody(_ args: [String: NexJSONValue]) -> [String: NexJSONValue] {
        compact(["filter": args["filter"], "sorts": args["sort"].map { .array([$0]) }, "page_size": .number(Double(limit(args)))])
    }
    private static func notionPageBody(_ args: [String: NexJSONValue], parentKey: String) -> [String: NexJSONValue] {
        let parentID = args[parentKey] ?? args["parent_id"] ?? .string("")
        return ["parent": .object([parentKey: parentID]), "properties": .object(notionProperties(args)), "children": .array([paragraph(args["content"]?.string ?? args["body"]?.string ?? "")])]
    }
    private static func notionProperties(_ args: [String: NexJSONValue]) -> [String: NexJSONValue] {
        guard let title = args["title"]?.string, !title.isEmpty else { return [:] }
        return ["title": .object(["title": .array([.object(["text": .object(["content": .string(title)])])])])]
    }
    private static func paragraph(_ text: String) -> NexJSONValue { .object(["object": .string("block"), "type": .string("paragraph"), "paragraph": .object(["rich_text": .array([.object(["type": .string("text"), "text": .object(["content": .string(text)])])])])]) }
    private static func slackMessage(_ args: [String: NexJSONValue], includeSchedule: Bool) -> [String: NexJSONValue] {
        var body = compact(["channel": args["channel_id"], "text": args["content"] ?? args["body"], "thread_ts": args["thread_id"]])
        if includeSchedule { body["post_at"] = .number(Date().addingTimeInterval(86_400).timeIntervalSince1970) }
        return body
    }
    private static func slackReaction(_ args: [String: NexJSONValue]) -> [String: NexJSONValue] { compact(["channel": args["channel_id"], "timestamp": args["message_id"], "name": args["emoji"]]) }
    private static func gmailQuery(_ args: [String: NexJSONValue]) -> String {
        var parts: [String] = []
        if let value = args["email"]?.string { parts.append("from:\(value)") }
        if let value = args["title"]?.string { parts.append("subject:(\(value))") }
        if args["unread"]?.bool == true { parts.append("is:unread") }
        if let labels = args["labels"]?.strings { parts += labels.map { "label:\($0)" } }
        if let value = args["query"]?.string { parts.append(value) }
        return parts.joined(separator: " ")
    }
    private static func rfc822(_ args: [String: NexJSONValue]) -> String {
        let text = "To: \(args["email"]?.string ?? "")\r\nSubject: \(args["title"]?.string ?? "")\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(args["body"]?.string ?? args["content"]?.string ?? "")"
        return Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func modifyGmail(_ base: String, _ args: [String: NexJSONValue], add: [String], remove: [String]) -> NexConnectorRequestPlan {
        let id = (args["message_id"]?.string ?? args["id"]?.string ?? "").urlPathEncoded
        return json("POST", base + "/messages/\(id)/modify", ["addLabelIds": .array(add.map(NexJSONValue.string)), "removeLabelIds": .array(remove.map(NexJSONValue.string))])
    }
    private static func calendarQuery(_ args: [String: NexJSONValue]) -> [String: String] {
        var query = ["maxResults": "\(limit(args))", "singleEvents": "true", "orderBy": "startTime"]
        if let value = args["start"]?.string { query["timeMin"] = value }
        if let value = args["end"]?.string { query["timeMax"] = value }
        if let value = args["query"]?.string { query["q"] = value }
        return query
    }
    private static func calendarEvent(_ args: [String: NexJSONValue], draft: Bool) -> [String: NexJSONValue] {
        var result = compact(["summary": args["title"], "description": args["description"] ?? args["content"], "location": args["location"], "recurrence": args["recurrence"]])
        if let start = args["start"] { result["start"] = .object(["dateTime": start, "timeZone": args["timezone"] ?? .string("UTC")]) }
        if let end = args["end"] { result["end"] = .object(["dateTime": end, "timeZone": args["timezone"] ?? .string("UTC")]) }
        if let attendees = args["attendees"]?.strings { result["attendees"] = .array(attendees.map { .object(["email": .string($0)]) }) }
        if draft { result["extendedProperties"] = .object(["private": .object(["nexusDraft": .string("true")])]) }
        return result
    }
}

private extension String {
    var urlPathEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? self }
}

private extension JSONEncoder {
    static var connectorAPI: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}
