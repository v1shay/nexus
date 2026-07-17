import XCTest
@testable import nexus

extension NexusGeometryTests {
    func testUnsavedConversationStaysInSessionAndNeverEntersVault() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        await session.appendUser("Keep this temporary")
        await session.appendAssistant("It is available in this live session.")

        let messages = await session.contextMessages()
        let scan = try await fixture.vault.scan()

        XCTAssertTrue(messages.contains(where: { $0.content == "Keep this temporary" }))
        XCTAssertTrue(scan.documents.isEmpty)
    }

    func testSavingConversationCreatesOneStructuredFileAndUpdatesItInPlace() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        await session.appendUser("Use a neural network in Project Atlas")
        await session.appendAssistant("We decided to use a compact convolutional network.")
        let firstSnapshot = await session.snapshot()

        let first = try await fixture.vault.saveConversation(firstSnapshot)
        await session.appendUser("Continue")
        await session.appendAssistant("Next, prepare the image dataset.")
        let second = try await fixture.vault.saveConversation(await session.snapshot())
        let scan = try await fixture.vault.scan()
        let markdown = try String(contentsOf: second.fileURL, encoding: .utf8)

        XCTAssertTrue(first.created)
        XCTAssertFalse(second.created)
        XCTAssertEqual(first.fileURL, second.fileURL)
        XCTAssertEqual(scan.documents.count, 1)
        XCTAssertEqual(scan.documents.first?.revision, 2)
        XCTAssertEqual(scan.documents.first?.conversation?.id, firstSnapshot.id)
        XCTAssertEqual(scan.documents.first?.conversation?.turns.count, 4)
        XCTAssertTrue(markdown.contains("nex_schema: 1"))
        XCTAssertTrue(markdown.contains("evidence_message_ids:"))
        XCTAssertTrue(markdown.contains("## Transcript"))
    }

    func testSavedChatIngestsAndResumesOnASecondDevice() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        await session.appendUser("Plan the Aurora launch")
        await session.appendAssistant("The open thread is choosing a launch date.")
        let snapshot = await session.snapshot()
        _ = try await fixture.vault.saveConversation(snapshot)

        let secondDeviceVault = NexObsidianVault(
            rootURL: fixture.vaultURL,
            deviceID: UUID(),
            fileManager: .default
        )
        let secondIndex = try NexMemoryIndex(
            databaseURL: fixture.root.appendingPathComponent("device-b.sqlite"),
            embeddingProvider: NexTestEmbeddingProvider()
        )
        let synchronized = try await secondDeviceVault.scan()
        try await secondIndex.rebuild(
            documents: synchronized.documents,
            tombstonedIDs: synchronized.tombstonedIDs
        )
        let summaries = try await secondIndex.savedConversations()
        let resumed = try await secondDeviceVault.conversation(id: snapshot.id)

        XCTAssertEqual(summaries.map(\.id), [snapshot.id])
        XCTAssertEqual(resumed.id, snapshot.id)
        XCTAssertEqual(resumed.turns.map(\.id), snapshot.turns.map(\.id))
        XCTAssertEqual(resumed.turns.map(\.role), snapshot.turns.map(\.role))
        XCTAssertEqual(resumed.turns.map(\.text), snapshot.turns.map(\.text))
        XCTAssertEqual(resumed.turns.map(\.state), snapshot.turns.map(\.state))
        for (restored, original) in zip(resumed.turns, snapshot.turns) {
            XCTAssertEqual(restored.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
        }
        XCTAssertEqual(resumed.openThreads, snapshot.openThreads)
    }

    func testDurableMemoryAndAllRelevantSavedHistoryAreSearchable() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        await session.appendUser("My Atlas classifier uses a neural network")
        let userSnapshot = await session.snapshot()
        let userMessage = try XCTUnwrap(userSnapshot.turns.last)
        await session.appendAssistant("That is durable project context.")
        let conversation = await session.snapshot()
        let chat = try await fixture.vault.saveConversation(conversation)
        let memory = try await fixture.vault.saveMemory(
            .init(
                idempotencyKey: "atlas-neural-network",
                kind: .project,
                title: "Project Atlas model",
                statement: "Project Atlas uses a neural network image classifier.",
                topics: ["neural network", "image classification"],
                projects: ["Project Atlas"],
                entities: ["Project Atlas"],
                evidenceMessageIDs: [userMessage.id]
            ),
            supportedBy: conversation
        )
        try await fixture.index.index(chat.document)
        try await fixture.index.index(memory.document)

        let relevant = try await fixture.index.search(query: "Have I used neural networks in Atlas?")
        let unrelated = try await fixture.index.search(query: "medieval sourdough taxation")

        XCTAssertTrue(relevant.contains(where: { $0.sourceID == memory.document.id }))
        XCTAssertTrue(relevant.contains(where: { $0.sourceID == chat.document.id }))
        XCTAssertTrue(relevant.allSatisfy(\.storedEvidence))
        XCTAssertTrue(unrelated.isEmpty)
    }

    func testDirectObsidianEditReindexesAndForgottenDocumentIsExcluded() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        await session.appendUser("Remember that Project Moss uses Swift")
        let userSnapshot = await session.snapshot()
        let message = try XCTUnwrap(userSnapshot.turns.last)
        await session.appendAssistant("Saved as supported project context.")
        let conversation = await session.snapshot()
        let write = try await fixture.vault.saveMemory(
            .init(
                idempotencyKey: "project-moss-language",
                kind: .project,
                title: "Project Moss language",
                statement: "Project Moss uses Swift.",
                projects: ["Project Moss"],
                evidenceMessageIDs: [message.id]
            ),
            supportedBy: conversation
        )
        try await fixture.index.index(write.document)

        var markdown = try String(contentsOf: write.fileURL, encoding: .utf8)
        markdown = markdown.replacingOccurrences(of: "Project Moss uses Swift.", with: "Project Moss uses Swift and Metal rendering.")
        try Data(markdown.utf8).write(to: write.fileURL, options: .atomic)
        let editedScan = try await fixture.vault.scan()
        let edited = editedScan.documents.first { $0.id == write.document.id }
        let editedDocument = try XCTUnwrap(edited)
        XCTAssertNotEqual(editedDocument.contentHash, write.document.contentHash)
        try await fixture.index.index(editedDocument)
        let editedResults = try await fixture.index.search(query: "Moss Metal rendering")
        XCTAssertTrue(editedResults.contains(where: { $0.sourceID == write.document.id }))

        try await fixture.vault.forget(documentID: write.document.id)
        let afterForget = try await fixture.vault.scan()
        try await fixture.index.rebuild(documents: afterForget.documents, tombstonedIDs: afterForget.tombstonedIDs)

        XCTAssertTrue(afterForget.tombstonedIDs.contains(write.document.id))
        XCTAssertFalse(afterForget.documents.contains(where: { $0.id == write.document.id }))
        let forgottenResults = try await fixture.index.search(query: "Moss Metal rendering")
        XCTAssertTrue(forgottenResults.isEmpty)
    }

    func testLocalIndexRebuildsEntirelyFromCanonicalVault() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        await session.appendUser("The Nebula project uses OCR")
        await session.appendAssistant("That project detail is in the saved conversation.")
        _ = try await fixture.vault.saveConversation(await session.snapshot())
        let scan = try await fixture.vault.scan()

        try await fixture.index.rebuild(documents: scan.documents, tombstonedIDs: scan.tombstonedIDs)

        let conversations = try await fixture.index.savedConversations()
        let rebuiltResults = try await fixture.index.search(query: "Nebula OCR")
        XCTAssertEqual(conversations.count, 1)
        XCTAssertFalse(rebuiltResults.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultURL.appendingPathComponent("index.sqlite").path))
    }
}

private struct NexMemoryFixture {
    let root: URL
    let vaultURL: URL
    let vault: NexObsidianVault
    let index: NexMemoryIndex

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexMemoryTests-\(UUID().uuidString)", isDirectory: true)
        vaultURL = root.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = NexObsidianVault(rootURL: vaultURL, deviceID: UUID())
        index = try NexMemoryIndex(
            databaseURL: root.appendingPathComponent("local-index.sqlite"),
            embeddingProvider: NexTestEmbeddingProvider()
        )
    }
}

private struct NexTestEmbeddingProvider: NexEmbeddingProviding {
    let identifier = "test-keyword-v1"
    private let vocabulary = ["atlas", "neural", "network", "classifier", "moss", "metal", "swift", "nebula", "ocr"]

    func vector(for text: String) -> [Float] {
        let lower = text.lowercased()
        var values = vocabulary.map { lower.contains($0) ? Float(1) : Float(0) }
        let magnitude = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        if magnitude > 0 {
            for index in values.indices { values[index] /= magnitude }
        }
        return values
    }
}
