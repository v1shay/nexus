import XCTest
@testable import nexus

final class NexMessagesActionTests: XCTestCase {
    private struct ContactsMock: NexContactsSearching {
        func search(name: String, limit: Int) async throws -> [NexContactMatch] {
            [.init(stableID: "contact-1", name: "Sam One", handles: ["sam@example.com"]), .init(stableID: "contact-2", name: "Sam Two", handles: ["+15555550123"])].prefix(limit).map { $0 }
        }
    }
    private struct HistoryMock: NexMessageHistoryReading {
        func search(query: String?, sender: String?, conversation: String?, after: Date?, before: Date?, limit: Int) async throws -> [NexMessageRecord] {
            [.init(stableID: "messages:7", sender: sender ?? "sam@example.com", recipient: "me", timestamp: Date(timeIntervalSince1970: 1_000), conversation: conversation ?? "Robotics", text: query ?? "robotics update", attachmentPath: "", attachmentType: "", isRead: false)]
        }
    }
    private actor SenderMock: NexMessageSending {
        var sent: [(String, String)] = []
        func open() async throws {}
        func openConversation(recipient: String) async throws {}
        func send(body: String, recipient: String) async throws { sent.append((body, recipient)) }
        func sentCount() -> Int { sent.count }
    }
    private struct Permissions: NexComputerPermissionChecking {
        func status(for requirement: NexComputerPermissionRequirement) async -> NexComputerPermissionStatus { .init(requirementID: requirement.id, state: .authorized, recovery: nil) }
        func request(for requirement: NexComputerPermissionRequirement) async -> NexComputerPermissionStatus { .init(requirementID: requirement.id, state: .authorized, recovery: nil) }
    }

    func testContactsRemainAmbiguousAndMessageSearchReturnsMetadata() async throws {
        let fixture = try await makeFixture()
        let contacts = try await fixture.core.execute(name: "messages.search_contacts", arguments: ["name": .string("Sam")])
        guard case .object(let contactObject) = contacts else { return XCTFail("Expected contacts") }
        XCTAssertEqual(contactObject["count"], .number(2))
        XCTAssertEqual(contactObject["items"]?.strings?.count, 2)

        let messages = try await fixture.core.execute(name: "messages.search", arguments: ["query": .string("robotics"), "sender": .string("sam@example.com")])
        guard case .object(let messageObject) = messages else { return XCTFail("Expected messages") }
        XCTAssertEqual(messageObject["count"], .number(1))
        XCTAssertTrue(messageObject["items"]?.strings?.first?.contains("messages:7") == true)
        XCTAssertTrue(messageObject["items"]?.strings?.first?.contains("read=false") == true)
    }

    func testDraftPersistsAndSendRequiresSeparateConfirmationWithoutSending() async throws {
        let fixture = try await makeFixture()
        let draftResult = try await fixture.core.execute(name: "messages.draft", arguments: ["recipient": .string("sam@example.com"), "body": .string("Fixture only")])
        guard case .object(let object) = draftResult, let draftID = object["messageDraftId"]?.string else { return XCTFail("Expected draft ID") }
        XCTAssertEqual(object["recipient"], .string("sam@example.com"))
        XCTAssertEqual(object["body"], .string("Fixture only"))
        XCTAssertEqual(object["items"]?.strings?.first?.contains("messages:7"), true, "A message draft card must receive real recent conversation data when history is available.")

        let reloaded = NexMessageDraftStore(fileURL: fixture.draftURL)
        let persistedDraft = await reloaded.draft(id: UUID(uuidString: draftID)!)
        XCTAssertNotNil(persistedDraft)
        let sendPending = try await fixture.core.execute(name: "messages.send_draft", arguments: [
            "messageDraftId": .string(draftID),
            "recipient": .string("sam@example.com"),
            "body": .string("Fixture only")
        ])
        let confirmationID = try actionID(sendPending)
        let sentCount = await fixture.sender.sentCount()
        XCTAssertEqual(sentCount, 0, "Tests must never send a real or mock message before explicit confirmation")

        let sent = try await fixture.core.execute(name: "confirm_action", arguments: ["actionId": .string(confirmationID)])
        XCTAssertEqual(sent.object?["status"], .string("sent"))
        let confirmedSendCount = await fixture.sender.sentCount()
        XCTAssertEqual(confirmedSendCount, 1, "The exact persisted draft must send only after the card confirmation.")
    }

    func testRequiredMessageActionsRegister() async throws {
        let fixture = try await makeFixture()
        let names = Set(await fixture.core.definitions().map(\.name))
        XCTAssertTrue(Set(["messages.open", "messages.search_contacts", "messages.search", "messages.triage", "messages.draft", "messages.send_draft", "messages.open_conversation"]).isSubset(of: names))
    }

    func testRecentMessagesIntentDiscoversTriageBeforeOpenOrDraft() async throws {
        let fixture = try await makeFixture()
        let search = NexToolSearchService(registry: fixture.core, computerRegistry: fixture.computer)
        try await search.registerIfNeeded()

        let result = await search.search(query: "Open Messages and pull my last couple messages")
        XCTAssertEqual(result.candidates.first?.tool, "messages.triage")
    }

    private func makeFixture() async throws -> (core: NexToolRegistry, computer: NexComputerRegistry, sender: SenderMock, draftURL: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexMessagesActionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let draftURL = root.appendingPathComponent("drafts.json")
        let sender = SenderMock()
        let core = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: core, confirmationGateway: NexComputerConfirmationGateway(store: NexComputerPendingActionStore(fileURL: root.appendingPathComponent("pending.json"))), permissionManager: NexComputerPermissionManager(backend: Permissions()))
        try await NexMessagesActionCatalog(contacts: ContactsMock(), history: HistoryMock(), sender: sender, drafts: NexMessageDraftStore(fileURL: draftURL)).register(on: computer)
        return (core, computer, sender, draftURL)
    }

    private func actionID(_ value: NexJSONValue) throws -> String {
        guard case .object(let object) = value, object["status"] == .string("confirmation_required"), let id = object["actionId"]?.string else { throw NexToolError.executionFailed(code: "missing_confirmation", message: "Expected confirmation") }
        return id
    }
}
