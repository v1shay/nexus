import XCTest
@testable import nexus

/// Contract tests for the single-primary-model planning pass. The file keeps
/// its legacy project entry so existing Xcode project references remain valid.
final class NexPrimaryToolPlannerTests: XCTestCase {
    func testPlannerPromptIncludesCompleteActiveContextAndRegisteredTools() {
        let context: [NexusChatMessage] = [
            .init(role: "user", content: "My robotics project is Atlas."),
            .init(role: "assistant", content: "Atlas uses a vision-guided arm."),
            .init(role: "user", content: "Find a competition that fits it.")
        ]
        let messages = NexPrimaryToolPlanner.planningMessages(context: context, tools: tools())
        let instructions = try! XCTUnwrap(messages.first?.content)

        XCTAssertTrue(instructions.contains("Infer tool use from meaning"))
        XCTAssertTrue(instructions.contains("never from a keyword checklist"))
        XCTAssertTrue(instructions.contains("TOOL web_search"))
        XCTAssertTrue(instructions.contains("TOOL memory_search"))
        XCTAssertTrue(instructions.contains("memory_get only with an exact source_id"))
        XCTAssertTrue(instructions.contains("conversation_recall for something visible above"))
        XCTAssertTrue(instructions.contains("memory_propose or memory_forget directly"))
        XCTAssertEqual(Array(messages.dropFirst()), context)
    }

    func testNoToolAndActiveConversationPlansStayToolFree() {
        let noTool = parse("""
        {"status":"Breaking that down…","actions":[],"memory_write":null}
        """)
        XCTAssertEqual(noTool.status, "Breaking that down…")
        XCTAssertTrue(noTool.actions.isEmpty)
        XCTAssertNil(noTool.memoryWrite)

        let followUp = parse("""
        {"status":"Continuing that…","actions":[],"memory_write":null}
        """)
        XCTAssertTrue(followUp.actions.isEmpty)
    }

    func testPlannerMakesNexCLITheOnlyImplementationPath() {
        let instructions = NexPrimaryToolPlanner.planningMessages(
            context: [.init(role: "user", content: "Build me a playable Snake game in a browser.")],
            tools: tools() + [cliTool()]
        ).first?.content ?? ""
        XCTAssertTrue(instructions.contains("Every request whose desired outcome is code or a file-based artifact must use nex_cli_task"))
        XCTAssertTrue(instructions.contains("standalone implementation brief"))

        let plan = NexPrimaryToolPlanner.parse(
            """
            {"actions":[{"tool":"nex_cli_task","arguments":{"title":"Snake Game","prompt":"Build a playable browser Snake game in the current Nexus workspace. Use HTML, CSS, and JavaScript, include keyboard controls and score handling, then validate that index.html opens locally."}}],"memory_write":null}
            """,
            registeredTools: tools() + [cliTool()]
        )
        XCTAssertEqual(plan.actions.map(\.tool), ["nex_cli_task"])
        XCTAssertGreaterThan(plan.actions[0].arguments["prompt"]?.string?.split(separator: " ").count ?? 0, 12)
    }

    func testPlannerExplainsPersistentWorkspaceAndExplicitSwitchTool() {
        let instructions = NexPrimaryToolPlanner.planningMessages(
            context: [.init(role: "user", content: "Continue the website from yesterday.")],
            tools: tools() + [cliTool(), workspaceTool()]
        ).first?.content ?? ""

        XCTAssertTrue(instructions.contains("completed task stays in that same workspace"))
        XCTAssertTrue(instructions.contains("Only call nex_cli_set_workspace when the user explicitly asks"))
        XCTAssertTrue(instructions.contains("never a path"))
    }

    func testNexCLIRegistersTaskAndExplicitWorkspaceSwitchTools() async throws {
        let registry = NexToolRegistry()
        let service = NexCLITaskService()
        try await service.register(in: registry)

        let definitions = await registry.definitions()
        let task = try XCTUnwrap(definitions.first { $0.name == "nex_cli_task" })
        let workspace = try XCTUnwrap(definitions.first { $0.name == "nex_cli_set_workspace" })
        XCTAssertTrue(task.schema.fields["prompt"]?.required == true)
        XCTAssertTrue(workspace.schema.fields["name"]?.required == true)
        XCTAssertFalse(workspace.schema.fields.keys.contains("path"))
    }

    func testStressParsesVagueStandaloneWebQueriesWithoutOneWordFragments() {
        let cases = [
            ("Look up that new model everyone is talking about.", "latest notable open-weight AI model releases July 2026"),
            ("What changed in the Swift release?", "Swift latest release changes July 2026"),
            ("What is the Conrad Challenge deadline this year?", "2026 Conrad Challenge application deadline"),
            ("Is that API different now?", "Swift structured concurrency API changes 2026")
        ]
        for (prompt, query) in cases {
            let plan = parse("""
            {"status":"Checking that…","actions":[{"tool":"web_search","arguments":{"query":"\(query)"}}],"memory_write":null}
            """)
            let actual = plan.actions.first?.arguments["query"]?.string ?? ""
            XCTAssertGreaterThanOrEqual(actual.split(separator: " ").count, 4, prompt)
            XCTAssertNotEqual(actual.lowercased(), prompt.split(separator: " ").first?.lowercased(), prompt)
            XCTAssertEqual(plan.actions.first?.tool, "web_search")
        }
    }

    func testLiveCloudPlannerProducesWebSearchForCurrentComparisonWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["NEXUS_LIVE_CLOUD_TEST"] == "1" else {
            throw XCTSkip("Set NEXUS_LIVE_CLOUD_TEST=1 to run the provider-backed routing test.")
        }
        let attempts = try NexusManagedCloudInferenceStore().configurations()
        guard attempts.count == 2 else {
            throw XCTSkip("Both managed cloud credentials are required for this live routing test.")
        }
        let prompt = "Compare the free tiers of NVIDIA, IMAPI, and Google AI Studio API"
        let messages = NexPrimaryToolPlanner.planningMessages(
            context: [.init(role: "user", content: prompt)],
            tools: tools()
        )
        let response = try await NexusManagedCloudInferenceClient.streamChat(
            attempts: attempts,
            messages: messages,
            temperature: 0,
            maximumTokens: 360,
            onDelta: { _, _ in }
        )
        let plan = try XCTUnwrap(NexPrimaryToolPlanner.parseStrict(response.text, registeredTools: tools()))
        let query = try XCTUnwrap(plan.actions.first(where: { $0.tool == "web_search" })?.arguments["query"]?.string)

        XCTAssertGreaterThanOrEqual(query.split(separator: " ").count, 4)
        XCTAssertFalse(query.localizedCaseInsensitiveContains("let's search"))
    }

    func testLiveNVIDIANIMProducesFocusedMultiToolPlanWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NEXUS_LIVE_CLOUD_TEST"] == "1",
            "Set NEXUS_LIVE_CLOUD_TEST=1 to run the live NVIDIA NIM routing test."
        )
        let attempt = try XCTUnwrap(
            NexusManagedCloudInferenceStore().configurations().first(where: { $0.provider == .nvidiaNIM })
        )
        // Exercise the public NVIDIA preset path, not just the internal
        // managed fallback representation.
        let configuration = NexusAPIProviderConfiguration(
            kind: .nvidiaNIM,
            baseURL: attempt.configuration.baseURL,
            model: NexusAPIProviderKind.nvidiaNIM.defaultModel,
            apiKey: attempt.configuration.apiKey
        )
        let plan = try await livePlan(using: configuration)
        XCTAssertEqual(Set(plan.actions.map(\.tool)), ["memory_search", "web_search"])
        XCTAssertGreaterThanOrEqual(plan.actions.first(where: { $0.tool == "web_search" })?.arguments["query"]?.string?.split(separator: " ").count ?? 0, 4)
    }

    func testLiveGeminiProducesFocusedMultiToolPlanWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NEXUS_LIVE_CLOUD_TEST"] == "1",
            "Set NEXUS_LIVE_CLOUD_TEST=1 to run the live Gemini routing test."
        )
        let secrets = NexusKeychainSecretStore(service: "na.nexus.model-provider")
        let keyData = try XCTUnwrap(
            try secrets.data(for: NexusAPIProviderKind.gemini.keyAccount)
                ?? secrets.data(for: "primary-model-api-key.v1")
        )
        let key = try XCTUnwrap(String(data: keyData, encoding: .utf8))
        let configuration = NexusAPIProviderConfiguration(
            kind: .gemini,
            baseURL: URL(string: NexusAPIProviderKind.gemini.defaultBaseURL)!,
            model: NexusAPIProviderKind.gemini.defaultModel,
            apiKey: key
        )
        let plan = try await livePlan(using: configuration)
        XCTAssertEqual(Set(plan.actions.map(\.tool)), ["memory_search", "web_search"])
        XCTAssertGreaterThanOrEqual(plan.actions.first(where: { $0.tool == "memory_search" })?.arguments["query"]?.string?.split(separator: " ").count ?? 0, 4)
    }

    func testLiveLocalOllamaProducesFocusedMultiToolPlanWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NEXUS_LIVE_LOCAL_TEST"] == "1",
            "Set NEXUS_LIVE_LOCAL_TEST=1 to run the live Ollama routing test."
        )
        let manager = OllamaManager()
        let names = try await manager.installedModelNames()
        let model = ProcessInfo.processInfo.environment["NEXUS_LIVE_LOCAL_MODEL"] ?? "gpt-oss:latest"
        try XCTSkipUnless(names.contains(model), "Install \(model) to run the local routing integration test.")
        let firstPlan = try await manager.planTools(
            model: model,
            messages: NexPrimaryToolPlanner.planningMessages(
                context: [.init(role: "user", content: "Based on my previous robotics project, should I apply to the current Conrad Challenge?")],
                tools: tools()
            ),
            registeredTools: tools()
        )
        var executed = firstPlan.actions
        if !executed.contains(where: { $0.tool == "web_search" }) {
            let nextPlan = try await manager.planTools(
                model: model,
                messages: NexPrimaryToolPlanner.planningMessages(
                    context: [
                        .init(role: "user", content: "Based on my previous robotics project, should I apply to the current Conrad Challenge?"),
                        .init(role: "system", content: "Tool result from memory_search: The user's robotics project was a vision-guided robotic arm. The current public Conrad Challenge details are still required before answering.")
                    ],
                    tools: tools()
                ),
                registeredTools: tools()
            )
            executed += nextPlan.actions
        }
        XCTAssertEqual(Set(executed.map(\.tool)), ["memory_search", "web_search"])
    }

    func testStressParsesVagueMemoryAndWebPlansWithSeparateEvidenceQueries() {
        let plan = parse("""
        {"status":"Checking your project fit…","actions":[
          {"tool":"memory_search","arguments":{"query":"user robotics project Atlas capabilities awards and prior results"}},
          {"tool":"web_search","arguments":{"query":"2026 Conrad Challenge eligibility judging criteria robotics deadline"}}
        ],"memory_write":null}
        """)
        XCTAssertEqual(Set(plan.actions.map(\.tool)), ["memory_search", "web_search"])
        let memory = plan.actions.first { $0.tool == "memory_search" }?.arguments["query"]?.string ?? ""
        let web = plan.actions.first { $0.tool == "web_search" }?.arguments["query"]?.string ?? ""
        XCTAssertTrue(memory.contains("Atlas"))
        XCTAssertTrue(web.contains("Conrad Challenge"))
        XCTAssertNotEqual(memory, web)
    }

    func testParsesConservativeMemoryAdvisories() {
        let append = parse("""
        {"status":"Saving that preference…","actions":[],"memory_write":{"operation":"append","content":"User prefers local models."}}
        """)
        XCTAssertEqual(append.memoryWrite?.operation, .append)

        let update = parse("""
        {"status":"Updating your project…","actions":[],"memory_write":{"operation":"update","content":"Nexus now uses Rust instead of Go."}}
        """)
        XCTAssertEqual(update.memoryWrite?.operation, .update)

        let forget = parse("""
        {"status":"Removing that preference…","actions":[],"memory_write":{"operation":"forget","content":"User wanted cloud inference."}}
        """)
        XCTAssertEqual(forget.memoryWrite?.operation, .forget)
    }

    func testRejectsUnknownToolsInvalidArgumentsAndMalformedPlans() {
        let unknown = parse("""
        {"status":"Searching…","actions":[{"tool":"shell_exec","arguments":{"command":"rm -rf /"}}],"memory_write":null}
        """)
        XCTAssertTrue(unknown.actions.isEmpty)

        let invalid = parse("""
        {"status":"Searching…","actions":[{"tool":"web_search","arguments":{"query":"news","surprise":"no"}}],"memory_write":null}
        """)
        XCTAssertTrue(invalid.actions.isEmpty)

        let malformed = parse("not JSON")
        XCTAssertEqual(malformed, .fallback)
        XCTAssertNil(NexPrimaryToolPlanner.parseStrict("not JSON", registeredTools: tools()))

        let templateStatus = parse("""
        {"status":"natural work-starting status","actions":[],"memory_write":null}
        """)
        XCTAssertEqual(templateStatus.status, NexPrimaryToolPlan.fallback.status)
    }

    func testMalformedPlannerOutputFallsBackWithoutBlockingTheConversation() {
        // The planner is advisory. A model that answers in prose cannot be
        // allowed to turn a simple greeting into a hard failure before the
        // regular conversational generation even begins.
        let plan = NexPrimaryToolPlanner.parse(
            "Hello Sir — what would you like me to do?",
            registeredTools: tools()
        )
        XCTAssertEqual(plan, .fallback)
        XCTAssertTrue(plan.actions.isEmpty)
    }

    func testRepairsProviderOmittedToolWrapperBeforeStrictValidation() {
        let plan = parse("""
        {"actions":[
          {"tool":"memory_search","arguments":{"query":"Vishay robotics project details"}},
          "web_search","arguments":{"query":"2026 Conrad Challenge eligibility deadline"}}
        ],"memory_write":null}
        """)
        XCTAssertEqual(Set(plan.actions.map(\.tool)), ["memory_search", "web_search"])
    }

    func testDeduplicatesRepeatedActionsWhileKeepingModelQueryUntouched() {
        let plan = parse("""
        {"status":"Checking current rules…","actions":[
          {"tool":"web_search","arguments":{"query":"2026 California student robotics competition rules"}},
          {"tool":"web_search","arguments":{"query":"2026 California student robotics competition rules"}}
        ],"memory_write":null}
        """)
        XCTAssertEqual(plan.actions.count, 1)
        XCTAssertEqual(plan.actions.first?.arguments["query"]?.string, "2026 California student robotics competition rules")
    }

    func testNormalizesPrimaryModelsNativeToolCalls() {
        let native = NexPrimaryToolPlanner.nativeCallPlan([
            .init(
                tool: "web_search",
                arguments: ["query": .string("2026 Conrad Challenge application deadline")]
            )
        ])
        let encoded = try! JSONEncoder().encode(native)
        let parsed = parse(String(decoding: encoded, as: UTF8.self))
        XCTAssertEqual(parsed.status, "Thinking…")
        XCTAssertEqual(parsed.actions.first?.tool, "web_search")
        XCTAssertEqual(parsed.actions.first?.arguments["query"]?.string, "2026 Conrad Challenge application deadline")
    }

    private func parse(_ response: String) -> NexPrimaryToolPlan {
        NexPrimaryToolPlanner.parse(response, registeredTools: tools())
    }

    private func livePlan(using configuration: NexusAPIProviderConfiguration) async throws -> NexPrimaryToolPlan {
        let messages = NexPrimaryToolPlanner.planningMessages(
            context: [.init(role: "user", content: "Based on my previous robotics project, should I apply to the current Conrad Challenge?")],
            tools: tools()
        )
        let raw = try await NexusAPIProviderClient.streamChat(
            configuration: configuration,
            messages: messages,
            temperature: 0,
            maximumTokens: 512,
            onDelta: { _, _ in }
        )
        return try XCTUnwrap(NexPrimaryToolPlanner.parseStrict(raw, registeredTools: tools()), "Provider returned non-plan text: \(raw.prefix(300))")
    }

    private func tools() -> [NexRegisteredTool] {
        [
            .init(
                name: "web_search",
                description: "Search the current public web.",
                statusLabel: "Searching the web…",
                spokenStatus: "Searching the web.",
                iconSystemName: "globe",
                permission: .network,
                schema: .init(fields: ["query": .init(.string, required: true)])
            ) { _, _ in .null },
            .init(
                name: "memory_search",
                description: "Search saved Nex memories and saved chats.",
                statusLabel: "Checking memory…",
                spokenStatus: "Checking memory.",
                iconSystemName: "magnifyingglass",
                permission: .readMemory,
                schema: .init(fields: ["query": .init(.string, required: true)])
            ) { _, _ in .null }
        ]
    }

    private func cliTool() -> NexRegisteredTool {
        .init(
            name: "nex_cli_task",
            description: "Build a code artifact in Nexus's managed workspace.",
            statusLabel: "Starting Nex CLI…",
            spokenStatus: "Starting the coding task.",
            iconSystemName: "terminal",
            permission: .codeExecution,
            schema: .init(fields: [
                "prompt": .init(.string, required: true),
                "title": .init(.string)
            ])
        ) { _, _ in .null }
    }

    private func workspaceTool() -> NexRegisteredTool {
        .init(
            name: "nex_cli_set_workspace",
            description: "Switch Nexus's managed coding workspace.",
            statusLabel: "Switching coding workspace…",
            spokenStatus: "Switching coding workspace.",
            iconSystemName: "folder",
            permission: .codeExecution,
            schema: .init(fields: ["name": .init(.string, required: true)])
        ) { _, _ in .null }
    }
}
