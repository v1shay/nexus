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

        let templateStatus = parse("""
        {"status":"natural work-starting status","actions":[],"memory_write":null}
        """)
        XCTAssertEqual(templateStatus.status, NexPrimaryToolPlan.fallback.status)
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
}
