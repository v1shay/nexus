import XCTest
@testable import nexus

final class NexWebSearchTests: XCTestCase {
    func testLiveCurrentEventsSearchWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NEXUS_RUN_LIVE_WEB_TESTS"] == "1",
            "Live web tests are opt-in"
        )
        let service = NexWebSearchService()
        let cases = [
            ("What is that new virus spreading right now?", ["virus", "outbreak", "health"]),
            ("What changed in the newest Swift release?", ["swift", "release"]),
            ("What is the biggest AI news today?", ["ai", "artificial intelligence"])
        ]
        for (prompt, topicalTerms) in cases {
            let query = NexWebSearchQueryBuilder.query(for: prompt)
            let response = try await service.search(query: query) { _, _ in }
            let searchable = response.results.map { $0.title + " " + $0.snippet }
                .joined(separator: " ").lowercased()
            print("LIVE WEB QUERY: \(query)")
            print("LIVE WEB TITLES: \(response.results.map(\.title).joined(separator: " | "))")
            XCTAssertFalse(response.results.isEmpty)
            XCTAssertTrue(response.results.allSatisfy { NexWebURLSafety.isSyntacticallyPublic($0.url) })
            XCTAssertTrue(topicalTerms.contains(where: searchable.contains), searchable)
            XCTAssertTrue(response.modelContext().contains("Web source 1"))
        }
    }

    func testPlannerRequestsCurrentInformationAndCreatesCleanQuery() {
        let raw = #"{"use_web":true,"query":"Chikungunya outbreak latest July 2026"}"#
        let plan = NexWebSearchPlanner.parse(raw, originalPrompt: "what's that new virus spreading")

        XCTAssertTrue(plan.shouldSearch)
        XCTAssertTrue(plan.query?.contains("chikungunya outbreak") == true)
        XCTAssertTrue(plan.query?.contains("virus") == true)
        XCTAssertTrue(NexWebSearchPlanner.obviousWebNeed("What changed in the newest version?"))
    }

    func testPlannerDoesNotMisfireOnNormalNonWebAnswer() {
        let plan = NexWebSearchPlanner.parse(
            #"{"use_web":false,"query":null}"#,
            originalPrompt: "Give me an ab workout I can do on my bed"
        )

        XCTAssertFalse(plan.shouldSearch)
        XCTAssertNil(plan.query)
    }

    func testObviousCurrentRequestSearchesEvenIfAWeakPlannerSaysNo() {
        let prompt = "What is that new virus spreading right now?"
        let plan = NexWebSearchPlanner.parse(
            #"{"use_web":false,"query":null}"#,
            originalPrompt: prompt
        )

        XCTAssertTrue(plan.shouldSearch)
        XCTAssertTrue(plan.query?.hasPrefix("virus outbreak health") == true)
        XCTAssertTrue(plan.query?.contains("spreading") == true)
        XCTAssertGreaterThanOrEqual(plan.query?.split(separator: " ").count ?? 0, 5)
    }

    func testOneWordPlannerQueriesAreRebuiltFromTheActualPrompt() {
        let cases = [
            ("What is that new virus spreading right now?", "what", "virus"),
            ("What changed in the newest Swift release?", "changes", "swift"),
            ("What is the biggest AI news today?", "big", "ai")
        ]

        for (prompt, badQuery, requiredTopic) in cases {
            let raw = "{\"use_web\":true,\"query\":\"\(badQuery)\"}"
            let query = NexWebSearchPlanner.parse(raw, originalPrompt: prompt).query ?? ""
            XCTAssertNotEqual(query, badQuery)
            XCTAssertTrue(query.contains(requiredTopic), query)
            XCTAssertGreaterThanOrEqual(query.split(separator: " ").count, 3)
        }
    }

    func testSpeechTranscriptionTyposAreNormalizedInFallbackQueries() {
        let query = NexWebSearchQueryBuilder.query(
            for: "waht changed in the newest siwf trealize",
            now: Date(timeIntervalSince1970: 1_784_236_800)
        )

        XCTAssertTrue(query.contains("swift"))
        XCTAssertTrue(query.contains("release"))
    }

    func testCurrentSearchQueriesPutTheActualTopicBeforeGenericModifiers() {
        let now = Date(timeIntervalSince1970: 1_784_236_800)

        XCTAssertTrue(
            NexWebSearchQueryBuilder.query(
                for: "What changed in the newest Swift release?", now: now
            ).hasPrefix("swift programming language release")
        )
        XCTAssertTrue(
            NexWebSearchQueryBuilder.query(
                for: "What is the biggest AI news today?", now: now
            ).hasPrefix("artificial intelligence ai news")
        )
        XCTAssertTrue(
            NexWebSearchQueryBuilder.query(
                for: "What is that new virus spreading right now?", now: now
            ).hasPrefix("virus outbreak health")
        )
    }

    func testURLSafetyRejectsLocalAndPrivateTargets() async {
        XCTAssertFalse(NexWebURLSafety.isSyntacticallyPublic(URL(string: "http://localhost:11434/api/tags")!))
        XCTAssertFalse(NexWebURLSafety.isSyntacticallyPublic(URL(string: "http://192.168.1.4/private")!))
        XCTAssertFalse(NexWebURLSafety.isSyntacticallyPublic(URL(string: "http://169.254.169.254/latest/meta-data")!))
        XCTAssertFalse(NexWebURLSafety.isSyntacticallyPublic(URL(string: "file:///etc/passwd")!))
        XCTAssertTrue(NexWebURLSafety.isSyntacticallyPublic(URL(string: "https://example.com/article")!))
    }

    func testArticleExtractionDropsNavigationScriptsAndPreservesReadableText() {
        let html = """
        <html><body><nav>Menu Pricing Login</nav><script>alert('bad')</script>
        <article><h1>New research result</h1><p>Researchers reported a useful result.</p>
        <p>The second paragraph contains supporting evidence and enough detail to read.</p></article>
        <footer>Cookies and legal links</footer></body></html>
        """

        let text = NexHTMLText.extractArticle(from: html, maximumCharacters: 2_000)

        XCTAssertTrue(text.contains("New research result"))
        XCTAssertTrue(text.contains("supporting evidence"))
        XCTAssertFalse(text.contains("Pricing Login"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("Cookies and legal"))
    }

    func testServiceRanksDeduplicatesExtractsCachesAndStreamsStages() async throws {
        let counter = NexSearchCallCounter()
        let provider = NexMockSearchProvider(counter: counter)
        let service = NexWebSearchService(
            providers: [provider],
            pageReader: NexMockPageReader(),
            configuration: .init(
                resultLimit: 4,
                pageReadLimit: 2,
                maximumPageBytes: 20_000,
                maximumExtractedCharacters: 2_000,
                cacheLifetime: 600,
                requestTimeout: 1
            )
        )
        let stages = NexSearchStageRecorder()

        let first = try await service.search(query: " newest Swift release ") { message, _ in
            await stages.append(message)
        }
        let second = try await service.search(query: "newest   Swift release") { message, _ in
            await stages.append(message)
        }

        XCTAssertEqual(first.results.count, 2)
        XCTAssertEqual(first.results.first?.title, "Swift release notes")
        XCTAssertEqual(first.results.first?.retrievalStatus, .extracted)
        XCTAssertTrue(first.modelContext().contains("https://1.1.1.1/releases"))
        XCTAssertTrue(second.isCached)
        let callCount = await counter.value
        XCTAssertEqual(callCount, 1)
        let messages = await stages.values
        XCTAssertTrue(messages.contains("Searching the web…"))
        XCTAssertTrue(messages.contains("Reviewing results…"))
        XCTAssertTrue(messages.contains("Reading sources…"))
        XCTAssertTrue(messages.contains("Synthesizing findings…"))
        XCTAssertTrue(messages.contains("Reviewed cached results…"))
    }

    func testWebLifecycleUsesChromeAndBuildsClickableSourceReceipt() {
        let result: NexJSONValue = .object([
            "results": .array([.object([
                "title": .string("Example report"),
                "url": .string("https://example.com/report"),
                "snippet": .string("A verified report."),
                "extracted_text": .null
            ])])
        ])
        let event = NexToolLifecycleEvent(
            executionID: UUID(),
            toolName: "web_search",
            phase: .completed,
            message: "Used search · 1 source",
            progress: 1,
            errorCode: nil,
            occurredAt: Date(),
            result: result
        )

        let activity = ToolActivity.lifecycle(event)

        XCTAssertEqual(activity.toolName, "Web Search")
        XCTAssertEqual(activity.icon, .asset(name: "Chrome", fallbackSystemName: "globe"))
        XCTAssertEqual(activity.sources.first?.sourceID, "https://example.com/report")
    }

    func testSearchToolRegistrationHasOneStrictNetworkArgument() async throws {
        let registry = NexToolRegistry()
        let controller = NexWebSearchController(registry: registry)
        try await controller.registerIfNeeded()

        let definitions = await registry.definitions()
        let tool = try XCTUnwrap(definitions.first(where: { $0.name == "web_search" }))
        XCTAssertEqual(tool.permission, .network)
        XCTAssertEqual(Set(tool.schema.fields.keys), ["query"])
        XCTAssertTrue(tool.schema.rejectUnknownFields)

        do {
            _ = try await registry.execute(
                name: "web_search",
                arguments: ["query": .string("Swift"), "provider": .string("invented")]
            )
            XCTFail("Unknown fields must be rejected before network execution")
        } catch {
            XCTAssertEqual(error as? NexToolError, .unknownField("provider"))
        }
    }

    func testCancellingToolWorkCancelsAnInFlightProvider() async throws {
        let service = NexWebSearchService(
            providers: [NexSlowSearchProvider()],
            pageReader: NexMockPageReader()
        )
        let task = Task {
            try await service.search(query: "cancel this search") { _, _ in }
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled search unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
    }
}

private actor NexSearchCallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor NexSearchStageRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private struct NexMockSearchProvider: NexWebSearchProviding {
    let name = "Mock"
    let counter: NexSearchCallCounter

    func search(query: String, limit: Int) async throws -> [NexWebSearchResult] {
        await counter.increment()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        return [
            .init(title: "Other result", url: URL(string: "https://8.8.8.8/page")!, snippet: "A secondary Swift note.", extractedText: nil, publishedAt: old, provider: name, retrievalStatus: .snippetOnly),
            .init(title: "Swift release notes", url: URL(string: "https://1.1.1.1/releases?utm_source=test")!, snippet: "Newest Swift release details.", extractedText: nil, publishedAt: Date(), provider: name, retrievalStatus: .snippetOnly),
            .init(title: "Duplicate", url: URL(string: "https://1.1.1.1/releases?utm_medium=test")!, snippet: "Duplicate URL.", extractedText: nil, publishedAt: Date(), provider: name, retrievalStatus: .snippetOnly)
        ]
    }
}

private struct NexMockPageReader: NexWebPageReading {
    func readableText(from url: URL, maximumBytes: Int, maximumCharacters: Int) async throws -> String {
        "Extracted article evidence from \(url.host ?? "source") with enough readable detail for the model."
    }
}

private struct NexSlowSearchProvider: NexWebSearchProviding {
    let name = "Slow mock"

    func search(query: String, limit: Int) async throws -> [NexWebSearchResult] {
        try await Task.sleep(for: .seconds(5))
        return []
    }
}
