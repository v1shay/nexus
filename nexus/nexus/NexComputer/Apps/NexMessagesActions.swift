import AppKit
import Contacts
import Foundation
import SQLite3

private let nexSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct NexContactMatch: Equatable, Sendable {
    let stableID: String
    let name: String
    let handles: [String]
}

struct NexMessageRecord: Equatable, Sendable {
    let stableID: String
    let sender: String
    let recipient: String
    let timestamp: Date
    let conversation: String
    let text: String
    let attachmentPath: String
    let attachmentType: String
    let isRead: Bool
}

protocol NexContactsSearching: Sendable { func search(name: String, limit: Int) async throws -> [NexContactMatch] }
protocol NexMessageHistoryReading: Sendable { func search(query: String?, sender: String?, conversation: String?, after: Date?, before: Date?, limit: Int) async throws -> [NexMessageRecord] }
protocol NexMessageSending: Sendable { func open() async throws; func openConversation(recipient: String) async throws; func send(body: String, recipient: String) async throws }

final class NexSystemContactsProvider: NexContactsSearching, @unchecked Sendable {
    func search(name: String, limit: Int) async throws -> [NexContactMatch] {
        let keys = [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var matches: [NexContactMatch] = []
        try CNContactStore().enumerateContacts(with: request) { contact, stop in
            let display = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            guard display.localizedCaseInsensitiveContains(name) else { return }
            let handles = contact.phoneNumbers.map { $0.value.stringValue } + contact.emailAddresses.map { String($0.value) }
            matches.append(.init(stableID: contact.identifier, name: display, handles: handles))
            if matches.count >= min(max(limit, 1), 25) { stop.pointee = true }
        }
        return matches
    }
}

final class NexMessagesReadOnlyDatabase: NexMessageHistoryReading, @unchecked Sendable {
    private let databaseURL: URL
    init(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")) { self.databaseURL = databaseURL }

    func search(query: String?, sender: String?, conversation: String?, after: Date?, before: Date?, limit: Int) async throws -> [NexMessageRecord] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
            throw NexToolError.executionFailed(code: "messages_database_unavailable", message: "Messages history is unavailable. Grant Nexus Full Disk Access, then retry.")
        }
        defer { sqlite3_close(database) }
        let sql = """
        SELECT m.ROWID, COALESCE(h.id,''), COALESCE(c.chat_identifier,''), COALESCE(m.text,''),
               m.date, COALESCE(m.is_read,0), COALESCE(m.is_from_me,0),
               COALESCE(a.filename,''), COALESCE(a.mime_type,'')
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN message_attachment_join maj ON maj.message_id = m.ROWID
        LEFT JOIN attachment a ON a.ROWID = maj.attachment_id
        WHERE (?1 = '' OR m.text LIKE '%' || ?1 || '%')
          AND (?2 = '' OR h.id LIKE '%' || ?2 || '%')
          AND (?3 = '' OR c.chat_identifier LIKE '%' || ?3 || '%')
          AND (?4 = 0 OR m.date >= ?4)
          AND (?5 = 0 OR m.date <= ?5)
        ORDER BY m.date DESC LIMIT ?6
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NexToolError.executionFailed(code: "messages_schema_unavailable", message: "This macOS Messages database schema is not supported.")
        }
        defer { sqlite3_finalize(statement) }
        bind(query ?? "", 1, statement); bind(sender ?? "", 2, statement); bind(conversation ?? "", 3, statement)
        sqlite3_bind_int64(statement, 4, appleNanoseconds(after)); sqlite3_bind_int64(statement, 5, appleNanoseconds(before))
        sqlite3_bind_int(statement, 6, Int32(min(max(limit, 1), 200)))
        var records: [NexMessageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let fromMe = sqlite3_column_int(statement, 6) != 0
            let handle = text(statement, 1)
            records.append(.init(
                stableID: "messages:\(sqlite3_column_int64(statement, 0))", sender: fromMe ? "me" : handle,
                recipient: fromMe ? handle : "me", timestamp: date(sqlite3_column_int64(statement, 4)),
                conversation: text(statement, 2), text: text(statement, 3), attachmentPath: text(statement, 7),
                attachmentType: text(statement, 8), isRead: sqlite3_column_int(statement, 5) != 0
            ))
        }
        return records
    }

    private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer) { sqlite3_bind_text(statement, index, value, -1, nexSQLiteTransient) }
    private func text(_ statement: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
    private func appleNanoseconds(_ date: Date?) -> Int64 { date.map { Int64(($0.timeIntervalSince1970 - 978_307_200) * 1_000_000_000) } ?? 0 }
    private func date(_ nanoseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000 + 978_307_200) }
}

final class NexMessagesApplicationController: NexMessageSending, @unchecked Sendable {
    func open() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") else { throw NexToolError.executionFailed(code: "messages_unavailable", message: "Messages is unavailable.") }
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
    func openConversation(recipient: String) async throws {
        guard let encoded = recipient.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: "sms:\(encoded)"), NSWorkspace.shared.open(url) else { throw NexToolError.executionFailed(code: "conversation_open_failed", message: "Messages could not open that recipient.") }
    }
    func send(body: String, recipient: String) async throws {
        let escapedBody = Self.escape(body), escapedRecipient = Self.escape(recipient)
        var error: NSDictionary?
        _ = NSAppleScript(source: """
        tell application "Messages"
            set targetBuddy to missing value
            repeat with targetService in services
                try
                    set targetBuddy to buddy "\(escapedRecipient)" of targetService
                    if targetBuddy is not missing value then exit repeat
                end try
            end repeat
            if targetBuddy is missing value then error "Recipient was not found."
            send "\(escapedBody)" to targetBuddy
        end tell
        """)?.executeAndReturnError(&error)
        if let error { throw NexToolError.executionFailed(code: "messages_send_failed", message: error[NSAppleScript.errorMessage] as? String ?? error.description) }
    }
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
}

struct NexMessageDraft: Codable, Equatable, Sendable { let id: UUID; let recipient: String; let body: String; let createdAt: Date; var sentAt: Date? }

actor NexMessageDraftStore {
    private let fileURL: URL
    private var drafts: [UUID: NexMessageDraft]
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nexus/NexComputer/message-drafts.json")
        self.drafts = [:]
        if let data = try? Data(contentsOf: self.fileURL), let loaded = try? JSONDecoder().decode([UUID: NexMessageDraft].self, from: data) { self.drafts = loaded }
    }
    func create(recipient: String, body: String) throws -> NexMessageDraft {
        let draft = NexMessageDraft(id: UUID(), recipient: recipient, body: body, createdAt: .now, sentAt: nil); drafts[draft.id] = draft; try persist(); return draft
    }
    func draft(id: UUID) -> NexMessageDraft? { drafts[id] }
    func markSent(id: UUID) throws { guard var draft = drafts[id] else { throw NexToolError.invalidStableID(id.uuidString) }; draft.sentAt = .now; drafts[id] = draft; try persist() }
    private func persist() throws { try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(drafts).write(to: fileURL, options: .atomic) }
}

actor NexMessagesActionCatalog {
    private let contacts: any NexContactsSearching
    private let history: any NexMessageHistoryReading
    private let sender: any NexMessageSending
    private let drafts: NexMessageDraftStore
    private var registered = false
    init(contacts: any NexContactsSearching = NexSystemContactsProvider(), history: any NexMessageHistoryReading = NexMessagesReadOnlyDatabase(), sender: any NexMessageSending = NexMessagesApplicationController(), drafts: NexMessageDraftStore = NexMessageDraftStore()) { self.contacts = contacts; self.history = history; self.sender = sender; self.drafts = drafts }

    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }; let contacts = contacts, history = history, sender = sender, drafts = drafts
        try await registry.register(manifest: Self.openManifest) { _, _ in try await sender.open(); return Self.simple("Opened Messages.") }
        try await registry.register(manifest: Self.contactsManifest) { args, _ in
            guard let name = args["name"]?.string else { throw NexToolError.missingField("name") }
            let matches = try await contacts.search(name: name, limit: args["limit"]?.integer ?? 10)
            return .object(["display": .string("Found \(matches.count) contact\(matches.count == 1 ? "" : "s")."), "count": .number(Double(matches.count)), "items": .array(matches.map { .string("\($0.stableID)|\($0.name)|\($0.handles.joined(separator: ","))") })])
        }
        let searchHandler: NexRegisteredTool.Handler = { args, _ in
            let records = try await history.search(query: args["query"]?.string, sender: args["sender"]?.string, conversation: args["conversation"]?.string, after: Self.date(args["after"]?.string), before: Self.date(args["before"]?.string), limit: args["limit"]?.integer ?? 50)
            return .object(["display": .string("Found \(records.count) message\(records.count == 1 ? "" : "s")."), "count": .number(Double(records.count)), "items": .array(records.map(Self.recordString))])
        }
        try await registry.register(manifest: Self.searchManifest, handler: searchHandler)
        try await registry.register(manifest: Self.triageManifest, handler: searchHandler)
        try await registry.register(manifest: Self.draftManifest) { args, _ in
            guard let recipient = args["recipient"]?.string, let body = args["body"]?.string else { throw NexToolError.missingField(args["recipient"] == nil ? "recipient" : "body") }
            let draft = try await drafts.create(recipient: recipient, body: body)
            // The card is meant to look like a real conversation, not a
            // decorative confirmation. History is best-effort because Full
            // Disk Access may not be granted; the draft itself remains fully
            // usable either way.
            let recent = (try? await history.search(
                query: nil,
                sender: recipient,
                conversation: nil,
                after: nil,
                before: nil,
                limit: 4
            )) ?? []
            return .object([
                "display": .string("Drafted a message to \(recipient)."),
                "messageDraftId": .string(draft.id.uuidString),
                "recipient": .string(recipient),
                "body": .string(body),
                "items": .array(recent.map(Self.recordString)),
                "status": .string("drafted")
            ])
        }
        try await registry.register(manifest: Self.sendManifest) { args, _ in
            guard let raw = args["messageDraftId"]?.string,
                  let id = UUID(uuidString: raw),
                  let draft = await drafts.draft(id: id),
                  draft.sentAt == nil,
                  args["recipient"]?.string == draft.recipient,
                  args["body"]?.string == draft.body else {
                throw NexToolError.invalidStableID(args["messageDraftId"]?.string ?? "")
            }
            try await sender.send(body: draft.body, recipient: draft.recipient); try await drafts.markSent(id: id)
            return .object([
                "display": .string("Sent the confirmed message to \(draft.recipient)."),
                "messageDraftId": .string(id.uuidString),
                "recipient": .string(draft.recipient),
                "body": .string(draft.body),
                "status": .string("sent")
            ])
        }
        try await registry.register(manifest: Self.conversationManifest) { args, _ in guard let recipient = args["recipient"]?.string else { throw NexToolError.missingField("recipient") }; try await sender.openConversation(recipient: recipient); return Self.simple("Opened the Messages conversation.") }
        registered = true
    }

    private static func date(_ raw: String?) -> Date? { raw.flatMap { ISO8601DateFormatter().date(from: $0) } }
    private static func recordString(_ record: NexMessageRecord) -> NexJSONValue { .string("\(record.stableID)|\(ISO8601DateFormatter().string(from: record.timestamp))|from=\(record.sender)|to=\(record.recipient)|chat=\(record.conversation)|read=\(record.isRead)|attachment=\(record.attachmentPath)|\(record.text)") }
    private static func simple(_ display: String) -> NexJSONValue { .object(["display": .string(display), "status": .string("completed")]) }
    private static let simpleOutput = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true)])
    private static let listOutput = NexToolInputSchema(fields: ["display": .init(.string, required: true), "count": .init(.integer, required: true), "items": .init(.stringArray, required: true)])
    private static let draftOutput = NexToolInputSchema(fields: [
        "display": .init(.string, required: true), "messageDraftId": .init(.string, required: true),
        "recipient": .init(.string, required: true), "body": .init(.string, required: true),
        "items": .init(.stringArray),
        "status": .init(.string, required: true)
    ])
    private static let messagePermissions = [NexComputerPermissionRequirement(id: "full_disk_access.messages", permission: .files, recovery: "Open System Settings > Privacy & Security > Full Disk Access and allow Nexus to read Messages history.")]
    private static let contactsPermissions = [NexComputerPermissionRequirement(id: "contacts", permission: .automation)]
    private static let automationPermissions = [NexComputerPermissionRequirement(id: "automation.com.apple.MobileSMS", permission: .automation)]
    private static let searchInput = NexToolInputSchema(fields: ["query": .init(.string), "sender": .init(.string), "conversation": .init(.string), "after": .init(.string), "before": .init(.string), "limit": .init(.integer, minimum: 1, maximum: 200)])
    private static let openManifest = manifest("messages.open", "Open or activate Messages.", ["Open Messages"], .init(fields: [:]), simpleOutput, .low, .never, [], .nativeAPI)
    private static let contactsManifest = manifest("messages.search_contacts", "Search Contacts by person name and return stable contact IDs plus all candidate handles for safe ambiguity resolution.", ["Find Sam in my contacts"], .init(fields: ["name": .init(.string, required: true), "limit": .init(.integer, minimum: 1, maximum: 25)]), listOutput, .low, .never, contactsPermissions, .nativeAPI)
    private static let searchManifest = manifest("messages.search", "Read-only search of local Messages history by text, sender, conversation, date range, and limit.", ["Find messages from Sam about robotics"], searchInput, listOutput, .low, .never, messagePermissions, .nativeAPI)
    private static let triageManifest = manifest("messages.triage", "Return bounded Messages records with stable IDs, participants, timestamps, conversation, attachment metadata, read state, and text for triage.", ["Triage my recent unread project messages"], searchInput, listOutput, .low, .never, messagePermissions, .nativeAPI)
    private static let draftManifest = manifest("messages.draft", "Create and persist a message draft for one exact recipient handle without sending it.", ["Draft a message to this contact"], .init(fields: ["recipient": .init(.string, required: true), "body": .init(.string, required: true)]), draftOutput, .low, .never, [], .nativeAPI)
    private static let sendManifest = manifest("messages.send_draft", "Send one immutable persisted message draft. recipient and body must exactly match the stored draft, so the confirmation previews the real message.", ["Send the drafted message"], .init(fields: ["messageDraftId": .init(.string, required: true), "recipient": .init(.string, required: true), "body": .init(.string, required: true)]), draftOutput, .high, .always, automationPermissions, .appleScript)
    private static let conversationManifest = manifest("messages.open_conversation", "Open Messages to one exact resolved phone number or email address.", ["Open my conversation with Sam"], .init(fields: ["recipient": .init(.string, required: true)]), simpleOutput, .low, .never, [], .urlScheme)
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ input: NexToolInputSchema, _ output: NexToolInputSchema, _ risk: NexComputerRiskClass, _ confirmation: NexComputerConfirmationPolicy, _ permissions: [NexComputerPermissionRequirement], _ method: NexComputerImplementationMethod) -> NexComputerActionManifest {
        .init(actionID: id, application: "Messages", provider: "Apple Messages", bundleIdentifier: method == .appleScript ? "com.apple.MobileSMS" : nil, description: description, examples: examples,
              aliases: [id.replacingOccurrences(of: ".", with: " ")], tags: ["messages", "imessage", "sms", "contact", "chat"], inputSchema: input, outputSchema: output,
              implementationMethod: method, requiredPermissions: permissions, registryPermission: method == .nativeAPI && risk == .low ? .files : .automation,
              riskClass: risk, confirmationPolicy: confirmation, availabilityCheck: method == .appleScript ? .application(bundleIdentifier: "com.apple.MobileSMS") : .always,
              timeoutSeconds: 30, supportsCancellation: id == "messages.search" || id == "messages.triage", dryRunBehavior: .supported("Would perform \(id) without sending a message."), previewRenderer: "messages.action", tests: ["NexMessagesActionTests"])
    }
}
