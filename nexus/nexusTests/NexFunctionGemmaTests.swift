import XCTest
@testable import nexus

final class NexFunctionGemmaTests: XCTestCase {
    func testNativeCallParserAcceptsFunctionGemmaWhitespaceVariant() {
        let calls = NexFunctionGemmaRuntime.parseCalls(
            " call: begin_status{status: Checking tomorrow's forecast}"
        )
        XCTAssertEqual(calls.first?.name, "begin_status")
        XCTAssertEqual(calls.first?.arguments["status"], "Checking tomorrow's forecast")
    }

    func testNativeCallParserRecoversTruncatedFinalArguments() {
        let calls = NexFunctionGemmaRuntime.parseCalls(
            " call:propose_memory_write{operation: append,content: Local models"
        )
        XCTAssertEqual(calls.first?.name, "propose_memory_write")
        XCTAssertEqual(calls.first?.arguments["operation"], "append")
        XCTAssertEqual(calls.first?.arguments["content"], "Local models")
    }

    func testSemanticRoutingScoreDiagnostics() {
        let guardrail = NexSemanticRoutingGuard()
        for prompt in [
            "Explain recursion.",
            "What is a linked list?",
            "Make your last answer shorter.",
            "Tell me about my last project.",
            "What architecture did we decide on for Nexus?",
            "Based on my previous robotics project, should I enter this current competition?",
            "Remember that I prefer local models.",
            "From now on, keep my project updates concise.",
            "Actually, Nexus now uses Rust instead of Go.",
            "Forget that I wanted cloud inference.",
            "I am eating lunch right now.",
            "What is the weather in San Francisco tomorrow?",
            "See whether that API works differently now."
        ] {
            let score = guardrail.scores(for: prompt)
            print("SEMANTIC SCORE \(prompt) web=\(score.web) memory=\(score.memory) active=\(score.activeConversation) direct=\(score.direct) write=\(score.memoryWrite) temp=\(score.temporary)")
        }
    }

    func testNoToolRequestsStayOnPrimaryPath() async {
        let router = makeRouter()
        for prompt in [
            "Explain recursion.",
            "Give me five project names.",
            "Rewrite this sentence professionally.",
            "What is a linked list?",
            "Make your last answer shorter.",
            "Write a Python loop."
        ] {
            let route = await router.route(request: prompt, activeConversation: snapshot(), tools: tools())
            XCTAssertTrue(route.output.actions.isEmpty, "\(prompt): \(route.output.actions)")
            XCTAssertFalse(route.output.status.isEmpty)
            XCTAssertLessThanOrEqual(route.output.status.split(separator: " ").count, 6)
        }
    }

    func testActiveConversationRequestsNeverSearchSavedMemory() async {
        let prior = NexConversationTurn(role: .user, text: "My current project is a robotic arm called Atlas.")
        let assistant = NexConversationTurn(role: .assistant, text: "Atlas uses computer vision.")
        let active = snapshot(turns: [prior, assistant], projects: ["Atlas"])
        let router = makeRouter()
        for prompt in [
            "What did I say earlier in this chat?",
            "Use the project I described above.",
            "Continue your last answer.",
            "Make the second paragraph shorter."
        ] {
            let route = await router.route(request: prompt, activeConversation: active, tools: tools())
            XCTAssertFalse(route.output.actions.contains(where: { $0.tool == "memory_search" }), prompt)
        }
    }

    func testSavedMemoryQueriesAreFocusedAndDoNotTriggerWeb() async {
        let router = makeRouter()
        for prompt in [
            "Tell me about my last project.",
            "What architecture did we decide on for Nexus?",
            "Which project did I win the most recent competition with?",
            "Based on my previous research plan, what should I do next?"
        ] {
            let route = await router.route(request: prompt, activeConversation: snapshot(), tools: tools())
            let memory = route.output.actions.first(where: { $0.tool == "memory_search" })
            XCTAssertNotNil(memory, prompt)
            XCTAssertGreaterThanOrEqual(memory?.query.split(separator: " ").count ?? 0, 3)
            XCTAssertFalse(route.output.actions.contains(where: { $0.tool == "web_search" }), prompt)
        }
    }

    func testWebQueriesPreserveIntentEntitiesAndAbsoluteDate() async {
        let router = makeRouter()
        let route = await router.route(
            request: "What is the weather in San Francisco tomorrow?",
            activeConversation: snapshot(),
            tools: tools()
        )
        let query = route.output.actions.first(where: { $0.tool == "web_search" })?.query ?? ""
        XCTAssertTrue(query.localizedCaseInsensitiveContains("San Francisco"), query)
        XCTAssertTrue(query.contains("July 18 2026"), query)
        XCTAssertGreaterThanOrEqual(query.split(separator: " ").count, 5)
        XCTAssertFalse(query.lowercased().contains("what is the"), query)
    }

    func testRejectedOneWordQueryFallsBackToConversationGroundedSearch() async {
        let prior = NexConversationTurn(
            role: .user,
            text: "We were discussing the Swift 6.2 structured concurrency API."
        )
        let assistant = NexConversationTurn(role: .assistant, text: "Its isolation rules changed.")
        let current = NexConversationTurn(role: .user, text: "See whether that API works differently now.")
        let router = NexFunctionGemmaRouter(
            runtime: OneWordFunctionGemmaRuntime(),
            now: { Date(timeIntervalSince1970: 1_784_355_600) }
        )
        let route = await router.route(
            request: current.text,
            activeConversation: snapshot(
                turns: [prior, assistant, current],
                projects: ["Swift concurrency"]
            ),
            tools: tools()
        )
        let query = route.output.actions.first(where: { $0.tool == "web_search" })?.query.lowercased() ?? ""
        XCTAssertGreaterThanOrEqual(query.split(separator: " ").count, 5)
        XCTAssertTrue(query.contains("swift"), query)
        XCTAssertTrue(query.contains("concurrency") || query.contains("api"), query)
        XCTAssertFalse(query.split(separator: " ") == ["you"])
    }

    func testMultiSourcePromptRunsMemoryAndWebInParallelShape() async {
        let router = makeRouter()
        let route = await router.route(
            request: "Based on my previous robotics project, should I enter this current competition?",
            activeConversation: snapshot(),
            tools: tools()
        )
        XCTAssertEqual(Set(route.output.actions.map(\.tool)), ["memory_search", "web_search"])
        XCTAssertTrue(route.output.actions.allSatisfy { $0.query.split(separator: " ").count >= 3 })
    }

    func testMemoryWriteProposalsAreConservative() async {
        let router = makeRouter()
        let cases: [(String, FunctionGemmaOutput.MemoryWrite.Operation?)] = [
            ("Remember that I prefer local models.", .append),
            ("From now on, keep my project updates concise.", .append),
            ("Actually, Nexus now uses Rust instead of Go.", .update),
            ("Forget that I wanted cloud inference.", .forget),
            ("I am eating lunch right now.", nil)
        ]
        for (prompt, operation) in cases {
            let route = await router.route(request: prompt, activeConversation: snapshot(), tools: tools())
            XCTAssertEqual(route.output.memoryWrite?.operation, operation, prompt)
        }
    }

    func testInvalidFunctionGemmaOutputFallsBackWithoutBlocking() async {
        let router = NexFunctionGemmaRouter(
            runtime: FailingFunctionGemmaRuntime(),
            now: { Date(timeIntervalSince1970: 1_784_355_600) }
        )
        let route = await router.route(request: "Explain recursion.", activeConversation: snapshot(), tools: tools())
        XCTAssertEqual(route.output, .neutral)
        XCTAssertEqual(route.metrics.runtime, .semanticFallback)
        XCTAssertTrue(route.metrics.invalidModelOutput)
    }

    func testInvalidFunctionGemmaMemoryWriteUsesConservativeSemanticFallback() async {
        let router = NexFunctionGemmaRouter(runtime: FailingFunctionGemmaRuntime())
        let cases: [(String, FunctionGemmaOutput.MemoryWrite.Operation)] = [
            ("Remember that I prefer local models.", .append),
            ("Actually, Nexus now uses Rust instead of Go.", .update),
            ("Forget that I wanted cloud inference.", .forget)
        ]
        for (prompt, expected) in cases {
            let route = await router.route(
                request: prompt,
                activeConversation: snapshot(),
                tools: tools()
            )
            XCTAssertEqual(route.output.memoryWrite?.operation, expected, prompt)
            XCTAssertEqual(route.output.memoryWrite?.content, prompt, prompt)
        }
    }

    func testSpeculativePrimaryBufferFlushesOnlyAfterNoToolActivation() async {
        let buffer = NexSpeculativePrimaryBuffer()
        let recorder = StringRecorder()
        await buffer.append(delta: "Hel", accumulated: "Hel")
        await buffer.append(delta: "lo", accumulated: "Hello")
        let valueBeforeActivation = await recorder.value
        XCTAssertEqual(valueBeforeActivation, "")
        await buffer.activate { delta, _ in await recorder.append(delta) }
        let valueAfterActivation = await recorder.value
        XCTAssertEqual(valueAfterActivation, "Hello")

        let discarded = NexSpeculativePrimaryBuffer()
        let discardedRecorder = StringRecorder()
        await discarded.append(delta: "private", accumulated: "private")
        await discarded.discard()
        await discarded.activate { delta, _ in await discardedRecorder.append(delta) }
        let discardedValue = await discardedRecorder.value
        XCTAssertEqual(discardedValue, "")
    }

    func testToolOrchestratorRunsIndependentRegistryActionsConcurrently() async throws {
        let registry = NexToolRegistry()
        let gate = ParallelToolGate()
        for name in ["alpha_search", "beta_search"] {
            try await registry.register(.init(
                name: name,
                description: "Test concurrent query tool.",
                statusLabel: "Working…",
                spokenStatus: "Working.",
                iconSystemName: "bolt",
                permission: .network,
                schema: .init(fields: ["query": .init(.string, required: true)]),
                handler: { arguments, _ in
                    await gate.arriveAndWait()
                    return .object(["query": arguments["query"] ?? .null])
                }
            ))
        }
        let orchestrator = NexToolOrchestrator(registry: registry)
        let execution = Task {
            await orchestrator.execute([
                .init(tool: "alpha_search", query: "first independent query"),
                .init(tool: "beta_search", query: "second independent query")
            ])
        }

        let bothStarted = await gate.waitForArrivals(2, timeout: .seconds(1))
        XCTAssertTrue(bothStarted, "A sequential orchestrator cannot reach both handlers before release.")
        await gate.release()
        let result = await execution.value
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(result.context?.contains("first independent query") == true)
        XCTAssertTrue(result.context?.contains("second independent query") == true)
    }

    func testLiveFunctionGemmaRoutingDiagnosticsWhenEnabled() async throws {
        try XCTSkipUnless(
            liveFunctionGemmaTestsEnabled,
            "Live FunctionGemma diagnostics are opt-in"
        )
        let router = NexFunctionGemmaRouter(now: { Date(timeIntervalSince1970: 1_784_355_600) })
        await router.warmUp()
        let cases: [(String, Set<String>, FunctionGemmaOutput.MemoryWrite.Operation?)] = [
            ("Explain recursion.", [], nil),
            ("What is the weather in San Francisco tomorrow?", ["web_search"], nil),
            ("Tell me about my last project.", ["memory_search"], nil),
            ("Remember that I prefer local models.", [], .append),
            ("Find a robotics competition open to high-school students.", ["web_search"], nil),
            ("Based on my previous robotics project, should I enter this current competition?", ["memory_search", "web_search"], nil)
        ]
        for (prompt, expected, expectedWrite) in cases {
            let route = await router.route(request: prompt, activeConversation: snapshot(), tools: tools())
            let actionSummary = route.output.actions
                .map { "\($0.tool)=\($0.query)" }
                .joined(separator: " | ")
            print("LIVE FUNCTIONGEMMA PROMPT: \(prompt)")
            print("LIVE FUNCTIONGEMMA STATUS: \(route.output.status)")
            print("LIVE FUNCTIONGEMMA ACTIONS: \(actionSummary)")
            print("LIVE FUNCTIONGEMMA MEMORY: \(String(describing: route.output.memoryWrite))")
            print("LIVE FUNCTIONGEMMA RUNTIME: \(route.metrics.runtime.rawValue)")
            print("LIVE FUNCTIONGEMMA LATENCY_MS: \(Int(route.metrics.latencyMilliseconds))")
            XCTAssertEqual(Set(route.output.actions.map(\.tool)), expected, prompt)
            XCTAssertEqual(route.output.memoryWrite?.operation, expectedWrite, prompt)
            XCTAssertTrue(route.output.actions.allSatisfy { $0.query.split(separator: " ").count >= 3 }, prompt)
        }
        await router.shutdown()
    }

    func testLiveFunctionGemmaLatencyBenchmarkWhenEnabled() async throws {
        try XCTSkipUnless(
            liveFunctionGemmaTestsEnabled,
            "Live FunctionGemma benchmarks are opt-in"
        )
        let primaryModel = ProcessInfo.processInfo.environment["NEXUS_ROUTER_BENCHMARK_MODEL"] ?? "gemma3:4b"
        let manager = OllamaManager()
        let router = NexFunctionGemmaRouter(now: { Date() })
        await router.warmUp()
        _ = try await manager.streamChat(
            model: primaryModel,
            messages: [.init(role: "user", content: "Reply with only: ready")],
            temperature: 0,
            maximumTokens: 8,
            onDelta: { _, _ in }
        )

        let baselineStart = Date()
        let baselineFirst = DateRecorder()
        _ = try await manager.streamChat(
            model: primaryModel,
            messages: [.init(role: "user", content: "Reply with only: recursion is self-reference")],
            temperature: 0,
            maximumTokens: 12,
            onDelta: { _, _ in await baselineFirst.recordIfNeeded(Date()) }
        )
        let baselineEnd = Date()

        let enabledStart = Date()
        let enabledFirst = DateRecorder()
        async let primaryAnswer = manager.streamChat(
            model: primaryModel,
            messages: [.init(role: "user", content: "Reply with only: recursion is self-reference")],
            temperature: 0,
            maximumTokens: 12,
            onDelta: { _, _ in await enabledFirst.recordIfNeeded(Date()) }
        )
        async let route = router.route(
            request: "Reply with only: recursion is self-reference",
            activeConversation: snapshot(),
            tools: tools()
        )
        let measuredRoute = await route
        _ = try await primaryAnswer
        let enabledEnd = Date()

        let recordedBaselineFirst = await baselineFirst.value()
        let recordedEnabledFirst = await enabledFirst.value()
        let baselineFirstDate = try XCTUnwrap(recordedBaselineFirst)
        let enabledFirstDate = try XCTUnwrap(recordedEnabledFirst)
        let baselineTTFT = baselineFirstDate.timeIntervalSince(baselineStart) * 1_000
        let enabledTTFT = enabledFirstDate.timeIntervalSince(enabledStart) * 1_000
        let baselineTotal = baselineEnd.timeIntervalSince(baselineStart) * 1_000
        let enabledTotal = enabledEnd.timeIntervalSince(enabledStart) * 1_000
        print("FUNCTIONGEMMA BENCHMARK PRIMARY_MODEL: \(primaryModel)")
        print("FUNCTIONGEMMA BENCHMARK BASELINE_TTFT_MS: \(Int(baselineTTFT))")
        print("FUNCTIONGEMMA BENCHMARK ENABLED_TTFT_MS: \(Int(enabledTTFT))")
        print("FUNCTIONGEMMA BENCHMARK ROUTING_MS: \(Int(measuredRoute.metrics.latencyMilliseconds))")
        print("FUNCTIONGEMMA BENCHMARK BASELINE_TOTAL_MS: \(Int(baselineTotal))")
        print("FUNCTIONGEMMA BENCHMARK ENABLED_TOTAL_MS: \(Int(enabledTotal))")
        print("FUNCTIONGEMMA BENCHMARK NO_TOOL_REGRESSION_MS: \(Int(enabledTotal - baselineTotal))")
        XCTAssertTrue(measuredRoute.output.actions.isEmpty)
        XCTAssertLessThan(measuredRoute.metrics.latencyMilliseconds, 2_500)
        XCTAssertLessThan(enabledTTFT, baselineTTFT + 500)
        XCTAssertLessThan(enabledTotal, baselineTotal + 500)
        await router.shutdown()
    }

    private func makeRouter() -> NexFunctionGemmaRouter {
        NexFunctionGemmaRouter(
            runtime: ScriptedFunctionGemmaRuntime(),
            now: { Date(timeIntervalSince1970: 1_784_355_600) }
        )
    }

    private var liveFunctionGemmaTestsEnabled: Bool {
        #if NEXUS_LIVE_ROUTER_TESTS
        true
        #else
        ProcessInfo.processInfo.environment["NEXUS_RUN_LIVE_FUNCTIONGEMMA_TESTS"] == "1"
        #endif
    }

    private func tools() -> [NexRegisteredTool] {
        [
            .init(
                name: "web_search",
                description: "Search current external information.",
                statusLabel: "Searching the web…",
                spokenStatus: "Searching the web.",
                iconSystemName: "globe",
                permission: .network,
                schema: .init(fields: ["query": .init(.string, required: true)]),
                handler: { _, _ in .object([:]) }
            ),
            .init(
                name: "memory_search",
                description: "Search saved durable memory and prior saved chats.",
                statusLabel: "Checking memory…",
                spokenStatus: "Checking memory.",
                iconSystemName: "brain",
                permission: .readMemory,
                schema: .init(fields: ["query": .init(.string, required: true)]),
                handler: { _, _ in .object([:]) }
            )
        ]
    }

    private func snapshot(
        turns: [NexConversationTurn] = [],
        projects: [String] = []
    ) -> NexConversationSnapshot {
        let date = Date(timeIntervalSince1970: 1_784_355_600)
        return .init(
            id: UUID(),
            createdAt: date,
            updatedAt: date,
            title: "New conversation",
            summary: "",
            topics: [],
            projects: projects,
            entities: [],
            decisions: [],
            openThreads: [],
            currentTask: nil,
            isActive: true,
            turns: turns
        )
    }
}

private actor ScriptedFunctionGemmaRuntime: NexFunctionGemmaGenerating {
    func warmUp() async {}

    func generateCalls(
        prompt: String,
        declarations: String,
        maximumTokens: Int
    ) async throws -> [NexFunctionGemmaRuntime.GeneratedCall] {
        if declarations.contains("propose_memory_write") {
            if prompt.contains("Remember that I prefer local models") {
                return [.init(name: "propose_memory_write", arguments: ["operation": "append", "content": "User prefers local models."])]
            }
            if prompt.contains("From now on, keep my project updates concise") {
                return [.init(name: "propose_memory_write", arguments: ["operation": "append", "content": "User prefers concise project updates."])]
            }
            if prompt.contains("Nexus now uses Rust instead of Go") {
                return [.init(name: "propose_memory_write", arguments: ["operation": "update", "content": "Nexus now uses Rust instead of Go."])]
            }
            if prompt.contains("Forget that I wanted cloud inference") {
                return [.init(name: "propose_memory_write", arguments: ["operation": "forget", "content": "User wanted cloud inference."])]
            }
            return []
        }
        return [
            .init(name: "explain_topic", arguments: ["topic": "the request"]),
            .init(name: "memory_search", arguments: ["query": "most relevant saved project decisions and user context"]),
            .init(name: "web_search", arguments: ["query": webQuery(for: prompt)])
        ]
    }

    private func webQuery(for prompt: String) -> String {
        if prompt.contains("San Francisco") { return "San Francisco weather forecast tomorrow" }
        if prompt.contains("robotics") || prompt.contains("competition") {
            return "2026 high school robotics competition eligibility deadline"
        }
        return "current verified information relevant to request 2026"
    }
}

private actor FailingFunctionGemmaRuntime: NexFunctionGemmaGenerating {
    func warmUp() async {}
    func generateCalls(prompt: String, declarations: String, maximumTokens: Int) async throws -> [NexFunctionGemmaRuntime.GeneratedCall] {
        throw URLError(.cannotConnectToHost)
    }
}

private actor OneWordFunctionGemmaRuntime: NexFunctionGemmaGenerating {
    func warmUp() async {}
    func generateCalls(prompt: String, declarations: String, maximumTokens: Int) async throws -> [NexFunctionGemmaRuntime.GeneratedCall] {
        [.init(name: "web_search", arguments: ["query": "you"])]
    }
}

private actor StringRecorder {
    private(set) var value = ""
    func append(_ text: String) { value += text }
}

private actor DateRecorder {
    private var stored: Date?
    func recordIfNeeded(_ date: Date) {
        if stored == nil { stored = date }
    }
    func value() -> Date? { stored }
}

private actor ParallelToolGate {
    private var arrivals = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrivals += 1
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitForArrivals(_ count: Int, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while arrivals < count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return arrivals >= count
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
