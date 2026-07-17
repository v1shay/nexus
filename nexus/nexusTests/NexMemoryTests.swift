import XCTest
@testable import nexus

extension NexusGeometryTests {
    @MainActor
    func testAutomaticMemoryInferenceRunsForImplicitDurableInformationWithoutKeywords() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        await session.appendUser("I'm building Driftglass, a local Swift app that indexes research PDFs with SQLite.")
        let appendedAssistant = await session.appendAssistant("That sounds like a focused offline research tool.")
        let assistant = try XCTUnwrap(appendedAssistant)
        let controller = NexMemoryController(
            conversation: session,
            vaultURL: fixture.vaultURL,
            databaseURL: fixture.root.appendingPathComponent("controller.sqlite"),
            embeddingProvider: NexTestEmbeddingProvider()
        )

        let request = try await controller.automaticMemoryInferenceRequest(after: assistant.id)

        XCTAssertNotNil(request)
        XCTAssertTrue(request?.messages.contains(where: {
            $0.content.contains("Infer meaning; do not look for trigger phrases")
        }) == true)
        XCTAssertTrue(request?.messages.last?.content.contains("Driftglass") == true)
    }

    func testAutomaticMemoryInferenceAcceptsSupportedImplicitFact() throws {
        let user = NexConversationTurn(
            role: .user,
            text: "I'm building Driftglass, a local Swift app that indexes research PDFs with SQLite."
        )
        let assistant = NexConversationTurn(role: .assistant, text: "That architecture fits an offline app.")
        let request = automaticInferenceRequest(user: user, assistant: assistant)
        let json = """
        {"proposals":[{"idempotency_key":"stable-concept-key","kind":"project","title":"Driftglass","statement":"Driftglass is a local Swift app that indexes research PDFs with SQLite.","summary":"User is building the local research-PDF indexer Driftglass in Swift with SQLite.","topics":["PDF indexing","local software"],"projects":["Driftglass"],"entities":["Driftglass","Swift","SQLite"],"evidence":[{"message_id":"\(user.id.uuidString)","quote":"I'm building Driftglass, a local Swift app that indexes research PDFs with SQLite."}],"importance":0.91,"confidence":0.97,"supersedes_source_id":null}]}
        """

        let proposals = try NexAutomaticMemoryInferenceParser.proposals(from: json, request: request)

        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.kind, .project)
        XCTAssertEqual(proposals.first?.idempotencyKey, "project-driftglass")
        XCTAssertEqual(proposals.first?.projects, ["Driftglass"])
        XCTAssertEqual(proposals.first?.evidenceMessageIDs, [user.id])
    }

    func testAutomaticMemoryInferenceRejectsLowConfidenceUnsupportedAndSensitiveProposals() throws {
        let user = NexConversationTurn(role: .user, text: "I'm tired today; my fake API key is sk-exampleexampleexample.")
        let assistant = NexConversationTurn(role: .assistant, text: "Your permanent favorite color is probably blue.")
        let request = automaticInferenceRequest(user: user, assistant: assistant)
        let lowConfidence = """
        {"proposals":[{"idempotency_key":"temporary-mood","kind":"personal_context","title":"Mood","statement":"The user is tired.","summary":"Temporary mood","topics":[],"projects":[],"entities":[],"evidence":[{"message_id":"\(user.id.uuidString)","quote":"I'm tired today"}],"importance":0.4,"confidence":0.7,"supersedes_source_id":null}]}
        """
        XCTAssertTrue(try NexAutomaticMemoryInferenceParser.proposals(from: lowConfidence, request: request).isEmpty)

        let assistantGuess = """
        {"proposals":[{"idempotency_key":"favorite-color","kind":"preference","title":"Favorite color","statement":"The user's favorite color is blue.","summary":"Favorite color","topics":[],"projects":[],"entities":[],"evidence":[{"message_id":"\(assistant.id.uuidString)","quote":"favorite color is probably blue"}],"importance":0.9,"confidence":0.95,"supersedes_source_id":null}]}
        """
        XCTAssertThrowsError(try NexAutomaticMemoryInferenceParser.proposals(from: assistantGuess, request: request))

        let sensitive = """
        {"proposals":[{"idempotency_key":"credential","kind":"knowledge","title":"Credential","statement":"The user supplied a credential.","summary":"Credential","topics":[],"projects":[],"entities":[],"evidence":[{"message_id":"\(user.id.uuidString)","quote":"my fake API key is sk-exampleexampleexample"}],"importance":0.95,"confidence":0.99,"supersedes_source_id":null}]}
        """
        XCTAssertThrowsError(try NexAutomaticMemoryInferenceParser.proposals(from: sensitive, request: request)) { error in
            XCTAssertEqual(error as? NexAutomaticMemoryInferenceError, .unsafeContent)
        }
    }

    @MainActor
    func testAutomaticMemoryCorrectionUpdatesOneObsidianFileInsteadOfDuplicating() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        let appendedFirstUser = await session.appendUser("My research app is called Driftglass.")
        let firstUser = try XCTUnwrap(appendedFirstUser)
        let appendedFirstAssistant = await session.appendAssistant("Got it.")
        let firstAssistant = try XCTUnwrap(appendedFirstAssistant)
        let controller = NexMemoryController(
            conversation: session,
            vaultURL: fixture.vaultURL,
            databaseURL: fixture.root.appendingPathComponent("writer.sqlite"),
            embeddingProvider: NexTestEmbeddingProvider()
        )
        let firstRequest = automaticInferenceRequest(user: firstUser, assistant: firstAssistant)
        let firstJSON = """
        {"proposals":[{"idempotency_key":"research-app-name","kind":"project","title":"Driftglass","statement":"The user's research app is called Driftglass.","summary":"Research app name","topics":[],"projects":["Driftglass"],"entities":["Driftglass"],"evidence":[{"message_id":"\(firstUser.id.uuidString)","quote":"My research app is called Driftglass."}],"importance":0.85,"confidence":0.99,"supersedes_source_id":null}]}
        """
        let initialWriteCount = try await controller.persistAutomaticMemoryInference(firstJSON, request: firstRequest)
        XCTAssertEqual(initialWriteCount, 1)
        let initialScan = try await fixture.vault.scan()
        let original = try XCTUnwrap(initialScan.documents.first)

        let appendedCorrectedUser = await session.appendUser("I renamed my research app from Driftglass to Glasswork.")
        let correctedUser = try XCTUnwrap(appendedCorrectedUser)
        let appendedCorrectedAssistant = await session.appendAssistant("Glasswork it is.")
        let correctedAssistant = try XCTUnwrap(appendedCorrectedAssistant)
        let correctedSnapshot = await session.snapshot()
        let correctedRequest = NexAutomaticMemoryInferenceRequest(
            conversationID: correctedSnapshot.id,
            assistantMessageID: correctedAssistant.id,
            turns: [correctedUser, correctedAssistant],
            supportedUserTurns: [correctedUser],
            candidates: [.init(
                sourceID: original.id,
                kind: .project,
                title: original.title,
                excerpt: original.summary
            )]
        )
        let correctedJSON = """
        {"proposals":[{"idempotency_key":"research-app-name","kind":"project","title":"Glasswork","statement":"The user's research app is called Glasswork, formerly Driftglass.","summary":"Current research app name","topics":[],"projects":["Glasswork"],"entities":["Glasswork","Driftglass"],"evidence":[{"message_id":"\(correctedUser.id.uuidString)","quote":"I renamed my research app from Driftglass to Glasswork."}],"importance":0.9,"confidence":0.99,"supersedes_source_id":"\(original.id.uuidString)"}]}
        """

        let correctedWriteCount = try await controller.persistAutomaticMemoryInference(correctedJSON, request: correctedRequest)
        XCTAssertEqual(correctedWriteCount, 1)
        let scan = try await fixture.vault.scan()
        XCTAssertEqual(scan.documents.count, 1)
        XCTAssertEqual(scan.documents.first?.id, original.id)
        XCTAssertEqual(scan.documents.first?.revision, 2)
        XCTAssertTrue(scan.documents.first?.body.contains("Glasswork") == true)
    }

    private func automaticInferenceRequest(
        user: NexConversationTurn,
        assistant: NexConversationTurn
    ) -> NexAutomaticMemoryInferenceRequest {
        NexAutomaticMemoryInferenceRequest(
            conversationID: UUID(),
            assistantMessageID: assistant.id,
            turns: [user, assistant],
            supportedUserTurns: [user],
            candidates: []
        )
    }

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

        let relevant = try await fixture.index.search(
            query: "Have I used neural networks in Atlas?",
            options: .init(evidenceOnly: true)
        )
        let unrelated = try await fixture.index.search(query: "medieval sourdough taxation")

        XCTAssertTrue(relevant.contains(where: { $0.sourceID == memory.document.id }))
        XCTAssertTrue(relevant.contains(where: { $0.sourceID == chat.document.id }))
        XCTAssertTrue(relevant.allSatisfy(\.storedEvidence))
        XCTAssertTrue(unrelated.isEmpty)
    }

    func testMemoryGraphUsesDurableVaultMemoryAndExcludesChatFiles() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        let appendedFirst = await session.appendUser("Project Atlas uses a neural network.")
        let first = try XCTUnwrap(appendedFirst)
        let appendedSecond = await session.appendUser("Project Atlas also uses OCR.")
        let second = try XCTUnwrap(appendedSecond)
        await session.appendAssistant("Those are durable project details.")
        let snapshot = await session.snapshot()
        _ = try await fixture.vault.saveConversation(snapshot)
        _ = try await fixture.vault.saveMemory(
            .init(
                idempotencyKey: "atlas-neural-model",
                kind: .project,
                title: "Atlas model",
                statement: "Project Atlas uses a neural network.",
                topics: ["machine learning"],
                projects: ["Project Atlas"],
                evidenceMessageIDs: [first.id]
            ),
            supportedBy: snapshot
        )
        _ = try await fixture.vault.saveMemory(
            .init(
                idempotencyKey: "atlas-ocr",
                kind: .knowledge,
                title: "Atlas OCR",
                statement: "Project Atlas uses OCR.",
                topics: ["document processing"],
                projects: ["Project Atlas"],
                evidenceMessageIDs: [second.id]
            ),
            supportedBy: snapshot
        )

        let graph = NexMemoryGraphSnapshot(documents: try await fixture.vault.scan().documents)

        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(Set(graph.nodes.map(\.title)), ["Atlas model", "Atlas OCR"])
        XCTAssertTrue(graph.nodes.allSatisfy { !$0.relativePath.isEmpty })
        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertGreaterThan(graph.edges[0].strength, 0.5)
    }

    func testUserNameQuestionRetrievesTheStoredUserIdentity() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        await session.appendUser("My full name is Vishay Agarwal")
        let snapshot = await session.snapshot()
        let evidence = try XCTUnwrap(snapshot.turns.last?.id)
        let write = try await fixture.vault.saveMemory(
            .init(
                idempotencyKey: "user-full-name",
                kind: .personalContext,
                title: "User identity",
                statement: "The user's full name is Vishay Agarwal.",
                topics: ["identity", "name"],
                entities: ["Vishay Agarwal"],
                evidenceMessageIDs: [evidence],
                importance: 1,
                confidence: 1
            ),
            supportedBy: snapshot
        )
        try await fixture.index.index(write.document)

        let results = try await fixture.index.search(query: "What's my name?")
        let service = NexMemoryService(
            vault: fixture.vault,
            index: fixture.index,
            conversation: session
        )
        let modelContext = try await service.retrievalContext(for: "What's my name?")

        XCTAssertEqual(results.first?.sourceID, write.document.id)
        XCTAssertTrue(results.first?.excerpt.contains("Vishay Agarwal") == true)
        XCTAssertTrue(modelContext?.contains("Vishay Agarwal") == true)
        XCTAssertFalse(modelContext?.contains("source_id") == true)
        XCTAssertFalse(modelContext?.contains(write.document.id.uuidString.lowercased()) == true)
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
            completionLabel: "Used weather",
            spokenStatus: "Checking weather.",
            iconSystemName: "cloud.sun",
            permission: .network,
            schema: .init(fields: ["city": .init(.string, required: true)]),
            handler: { arguments, context in
                await context.reportProgress("Reading forecast…", 0.5)
                return .object([
                    "city": arguments["city"] ?? .null,
                    "count": .number(2)
                ])
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

        XCTAssertEqual(result, .object([
            "city": .string("Cupertino"),
            "count": .number(2)
        ]))
        XCTAssertEqual(events.map(\.phase), [.started, .progress, .completed])
        XCTAssertTrue(events.allSatisfy { $0.toolName == "future_weather" })
        XCTAssertEqual(events.last?.message, "Used weather · 2 sources")
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

    func testPersonalQuestionsTriggerMemoryWhileOrdinaryQuestionsDoNot() {
        let personalPrompts = [
            "What's my name?",
            "Who am I?",
            "What is my GitHub handle?",
            "Where do I go to high school?",
            "What are my current research roles?",
            "How do I prefer answers to be written?",
            "Check your memory: what is Moonshot Robotics?",
            "Should I do open source contributions for college?",
            "What is the best demo for my AI agent?",
            "Give me an ab workout I can do on my bed"
        ]

        XCTAssertTrue(personalPrompts.allSatisfy(NexMemoryRetrievalIntent.shouldSearch))
        XCTAssertFalse(NexMemoryRetrievalIntent.shouldSearch(prompt: "What's the weather?"))
        XCTAssertFalse(NexMemoryRetrievalIntent.shouldSearch(prompt: "Why?"))
        XCTAssertFalse(NexMemoryRetrievalIntent.shouldSearch(prompt: "Continue"))
    }

    func testEvidenceOnlyRetrievalRejectsSavedAssistantHallucinations() async throws {
        let fixture = try NexMemoryFixture()
        let session = NexConversationSession()
        await session.appendUser("I attend Lynbrook High School.")
        let identitySnapshot = await session.snapshot()
        let evidenceID = try XCTUnwrap(identitySnapshot.turns.last?.id)
        let memory = try await fixture.vault.saveMemory(
            .init(
                idempotencyKey: "school-lynbrook",
                kind: .personalContext,
                title: "School",
                statement: "Vishay attends Lynbrook High School.",
                topics: ["school", "education"],
                entities: ["Lynbrook High School", "Vishay"],
                evidenceMessageIDs: [evidenceID],
                importance: 1,
                confidence: 1
            ),
            supportedBy: identitySnapshot
        )
        await session.appendUser("What school do I attend?")
        await session.appendAssistant("You attend Crestwood University, ranked #23 nationally.")
        let chat = try await fixture.vault.saveConversation(await session.snapshot())
        try await fixture.index.index(memory.document)
        try await fixture.index.index(chat.document)

        let results = try await fixture.index.search(
            query: "What school do I attend?",
            options: .init(evidenceOnly: true)
        )

        XCTAssertTrue(results.contains(where: { $0.excerpt.contains("Lynbrook High School") }))
        XCTAssertFalse(results.contains(where: { $0.excerpt.contains("Crestwood") }))
        XCTAssertTrue(results.allSatisfy(\.storedEvidence))
        XCTAssertFalse(results.contains(where: { $0.sourceRole == .assistant }))
    }

    func testMissingMemoryEvidenceAddsAnExplicitDoNotGuessContract() async {
        let session = NexConversationSession()
        await session.appendUser("What school do I attend?")

        let messages = await session.contextMessages(memoryLookupPerformed: true)

        XCTAssertTrue(messages.contains(where: {
            $0.role == "system" && $0.content.contains("found no relevant user-supported evidence")
        }))
    }

    func testRetrievedEvidenceCannotBeContaminatedByPriorAssistantClaims() async throws {
        let session = NexConversationSession()
        await session.appendUser("What school do I attend?")
        await session.appendAssistant("You attend Crestwood University.")
        await session.appendUser("Are you sure?")

        let messages = await session.contextMessages(
            retrievedContext: "[source_id=profile] You attend Lynbrook High School.",
            memoryLookupPerformed: true
        )
        let evidenceIndex = try XCTUnwrap(messages.firstIndex(where: { $0.content.contains("source_id=profile") }))

        XCTAssertFalse(messages.contains(where: { $0.content.contains("Crestwood") }))
        XCTAssertTrue(messages[..<evidenceIndex].contains(where: { $0.content.contains("What school") }))
        XCTAssertTrue(messages[evidenceIndex].content.contains("overrides any conflicting factual claim"))
        XCTAssertEqual(messages.last?.content, "Are you sure?")
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
