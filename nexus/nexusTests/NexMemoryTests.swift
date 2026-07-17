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
            deviceID: UUID()
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

    func testMemoryToolSchemasRejectUnknownFieldsAndUnauthorizedWrites() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        await session.appendUser("Remember that Project Atlas uses OCR")
        let snapshot = await session.snapshot()
        let evidence = try XCTUnwrap(snapshot.turns.last?.id)
        let registry = NexToolRegistry()
        let service = NexMemoryService(
            vault: fixture.vault,
            index: fixture.index,
            registry: registry,
            conversation: session
        )
        _ = try await service.prepare()

        do {
            _ = try await registry.execute(
                name: "memory_search",
                arguments: ["query": .string("Atlas"), "raw_sql": .string("SELECT *")]
            )
            XCTFail("Unknown fields must fail")
        } catch let error as NexToolError {
            XCTAssertEqual(error, .unknownField("raw_sql"))
        }

        let proposal: [String: NexJSONValue] = [
            "idempotency_key": .string("atlas-ocr"),
            "kind": .string("project"),
            "title": .string("Atlas OCR"),
            "statement": .string("Project Atlas uses OCR."),
            "evidence_message_ids": .array([.string(evidence.uuidString)])
        ]
        do {
            _ = try await registry.execute(
                name: "memory_propose",
                arguments: proposal,
                invocation: .modelReadOnly
            )
            XCTFail("A model cannot silently write durable memory")
        } catch let error as NexToolError {
            XCTAssertEqual(error, .permissionDenied(.writeMemory))
        }
    }

    func testToolLifecycleAndFutureRegistrationAreGeneric() async throws {
        let bus = NexToolEventBus()
        let registry = NexToolRegistry(events: bus)
        try await registry.register(.init(
            name: "future_weather",
            description: "Test future tool",
            statusLabel: "Checking weather…",
            spokenStatus: "Checking weather.",
            iconSystemName: "cloud.sun",
            permission: .network,
            schema: .init(fields: ["city": .init(.string, required: true)]),
            handler: { arguments, context in
                await context.reportProgress("Reading forecast…", 0.5)
                return .object(["city": arguments["city"] ?? .null])
            }
        ))
        let stream = await bus.events()
        let eventsTask = Task { () -> [NexToolLifecycleEvent] in
            var events: [NexToolLifecycleEvent] = []
            for await event in stream {
                events.append(event)
                if event.phase == .completed { break }
            }
            return events
        }

        let result = try await registry.execute(
            name: "future_weather",
            arguments: ["city": .string("Cupertino")]
        )
        let events = await eventsTask.value

        XCTAssertEqual(result, .object(["city": .string("Cupertino")]))
        XCTAssertEqual(events.map(\.phase), [.started, .progress, .completed])
        XCTAssertTrue(events.allSatisfy { $0.toolName == "future_weather" })
    }

    func testDirectVaultDeletionIsRemovedFromLocalRetrieval() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        await session.appendUser("The Quartz project uses Metal")
        await session.appendAssistant("That is saved project context.")
        let write = try await fixture.vault.saveConversation(await session.snapshot())
        let registry = NexToolRegistry()
        let service = NexMemoryService(
            vault: fixture.vault,
            index: fixture.index,
            registry: registry,
            conversation: session
        )
        _ = try await service.prepare()
        let beforeDeletion = try await service.search("Quartz Metal")
        XCTAssertFalse(beforeDeletion.isEmpty)

        try FileManager.default.removeItem(at: write.fileURL)
        _ = try await service.synchronize()

        let afterDeletion = try await service.search("Quartz Metal")
        XCTAssertTrue(afterDeletion.isEmpty)
    }

    func testCompoundQuestionSeparatesImmediateAndMemoryDependentParts() {
        let split = NexCompoundMemoryQuery.split("What is a neural network and have I used one in my projects?")

        XCTAssertEqual(split?.immediateQuestion, "What is a neural network")
        XCTAssertEqual(split?.memoryQuestion, "have I used one in my projects?")
        XCTAssertNil(NexCompoundMemoryQuery.split("Why?"))
        XCTAssertNil(NexCompoundMemoryQuery.split("Explain neural networks"))
    }

    func testStreamingCursorPreservesOrderedTwoPhaseAnswer() {
        var cursor = StreamedSpeechCursor()
        XCTAssertEqual(cursor.consume(delta: "First", accumulated: "First answer."), "First answer.")
        cursor.beginSegment()
        XCTAssertEqual(cursor.consume(delta: "Second", accumulated: "Second answer."), "Second answer.")
        XCTAssertEqual(cursor.text, "First answer.\n\nSecond answer.")
    }

    @MainActor
    func testSaveControlTransitionsWithoutPersistingUnsavedChat() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        let memory = NexMemoryController(
            conversation: session,
            vaultURL: fixture.vaultURL,
            databaseURL: fixture.root.appendingPathComponent("controller.sqlite"),
            embeddingProvider: NexTestEmbeddingProvider()
        )
        await session.appendUser("Save this chat")
        await session.appendAssistant("It has a complete exchange.")
        await memory.conversationDidChange()
        XCTAssertEqual(memory.saveState, .ready)
        XCTAssertTrue(memory.hasValuableUnsavedConversation)

        await memory.save()
        XCTAssertEqual(memory.saveState, .saved)
        XCTAssertFalse(memory.hasValuableUnsavedConversation)
        let scan = try await fixture.vault.scan()
        XCTAssertEqual(scan.documents.count, 1)

        await session.appendUser("One more change")
        await memory.conversationDidChange()
        XCTAssertEqual(memory.saveState, .dirty)
    }

    func testEmbeddingProviderChangeRebuildsFromCanonicalMarkdown() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        await session.appendUser("Project Ember uses OCR")
        await session.appendAssistant("That is saved context.")
        _ = try await fixture.vault.saveConversation(await session.snapshot())
        let firstService = NexMemoryService(
            vault: fixture.vault,
            index: fixture.index,
            conversation: session
        )
        _ = try await firstService.prepare()

        let replacementIndex = try NexMemoryIndex(
            databaseURL: fixture.root.appendingPathComponent("local-index.sqlite"),
            embeddingProvider: NexTestEmbeddingProvider(identifier: "test-keyword-v2")
        )
        let replacementService = NexMemoryService(
            vault: fixture.vault,
            index: replacementIndex,
            conversation: session
        )
        let report = try await replacementService.prepare()
        let results = try await replacementService.search("Ember OCR")
        let stillRequiresRebuild = try await replacementIndex.requiresEmbeddingRebuild()

        XCTAssertEqual(report.ingestedDocuments, 1)
        XCTAssertFalse(results.isEmpty)
        XCTAssertFalse(stillRequiresRebuild)
    }

    func testUnreadableVaultChangePreventsFullySynchronizedClaim() async throws {
        let fixture = try NexMemoryFixture()
        try await fixture.vault.prepare()
        let invalid = fixture.vaultURL.appendingPathComponent("00 Inbox/broken.md")
        try Data("# Missing required frontmatter".utf8).write(to: invalid, options: .atomic)

        let scan = try await fixture.vault.scan()
        let service = NexMemoryService(
            vault: fixture.vault,
            index: fixture.index,
            conversation: NexConversationSession()
        )
        let report = try await service.synchronize()

        XCTAssertEqual(scan.ingestionFailures.count, 1)
        XCTAssertEqual(report.ingestionFailures.count, 1)
        XCTAssertFalse(report.isFullyIngested)
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
    let identifier: String
    private let vocabulary = ["atlas", "neural", "network", "classifier", "moss", "metal", "swift", "nebula", "ocr"]

    init(identifier: String = "test-keyword-v1") {
        self.identifier = identifier
    }

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
