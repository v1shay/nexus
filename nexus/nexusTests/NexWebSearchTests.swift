import XCTest
@testable import nexus

final class NexWebSearchTests: XCTestCase {
    func testLiveModelSearchPlanningDiagnosticsWhenEnabled() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NEXUS_RUN_LIVE_PLANNER_TESTS"] == "1",
            "Live planner diagnostics are opt-in"
        )
        let model = ProcessInfo.processInfo.environment["NEXUS_LIVE_PLANNER_MODEL"] ?? "gemma3:4b"
        let manager = OllamaManager()
        let service = NexWebSearchService()
        let cases: [(prompt: String, shouldSearch: Bool, requiredTerms: [String])] = [
            ("Should I bring an umbrella to San Francisco tomorrow afternoon?", true, ["san", "francisco"]),
            ("Compare Nvidia's stock price with AMD's today.", true, ["nvidia", "amd"]),
            ("Has Apple released a newer MacBook Air since the M4 model?", true, ["apple", "macbook"]),
            ("Who won the most recent Formula 1 race and what happened?", true, ["formula", "race"]),
            ("Look up whether Python 3.14 is stable and summarize the headline changes.", true, ["python", "3.14"]),
            ("Is there an active measles outbreak in California this week?", true, ["measles", "california"]),
            ("Write a sarcastic name for my alarm clock.", false, []),
            ("Explain why neural networks need activation functions.", false, [])
        ]

        for testCase in cases {
            let prompt = testCase.prompt
            let raw = try await manager.streamChat(
                model: model,
                messages: NexWebSearchPlanner.planningMessages(for: prompt),
                temperature: 0,
                maximumTokens: 220,
                onDelta: { _, _ in }
            )
            let initialPlan = NexWebSearchPlanner.parse(raw, originalPrompt: prompt)
            var finalPlan = initialPlan
            var repairedRaw: String?
            if initialPlan.queryOrigin == .fallback || initialPlan.queryOrigin == .rejected {
                let repair = try await manager.streamChat(
                    model: model,
                    messages: NexWebSearchPlanner.repairMessages(
                        for: prompt,
                        rejectedOutput: raw
                    ),
                    temperature: 0,
                    maximumTokens: 220,
                    onDelta: { _, _ in }
                )
                repairedRaw = repair
                let repairedPlan = NexWebSearchPlanner.parse(repair, originalPrompt: prompt)
                if repairedPlan.queryOrigin == .modelExtraction || repairedPlan.queryOrigin == .none {
                    finalPlan = repairedPlan
                } else if initialPlan.queryOrigin == .rejected {
                    finalPlan = .init(shouldSearch: false, query: nil)
                }
            }

            print("LIVE PLANNER PROMPT: \(prompt)")
            print("LIVE PLANNER RAW: \(raw)")
            print("LIVE PLANNER INITIAL ORIGIN: \(initialPlan.queryOrigin)")
            print("LIVE PLANNER REPAIR USED: \(repairedRaw != nil)")
            if let repairedRaw { print("LIVE PLANNER REPAIR RAW: \(repairedRaw)") }
            print("LIVE PLANNER FINAL ORIGIN: \(finalPlan.queryOrigin)")
            print("LIVE PLANNER FINAL QUERY: \(finalPlan.query ?? "<none>")")
            XCTAssertEqual(finalPlan.shouldSearch, testCase.shouldSearch, prompt)

            if finalPlan.shouldSearch, let query = finalPlan.query {
                XCTAssertGreaterThanOrEqual(query.split(separator: " ").count, 5, query)
                for term in testCase.requiredTerms {
                    XCTAssertTrue(query.contains(term), "\(prompt): missing \(term) in \(query)")
                }
                let response = try await service.search(query: query) { _, _ in }
                print("LIVE PLANNER RESULT: \(response.results.first?.title ?? "<none>")")
                print("LIVE PLANNER RESULT URL: \(response.results.first?.url.absoluteString ?? "<none>")")
                XCTAssertFalse(response.results.isEmpty, query)
            } else {
                print("LIVE PLANNER RESULT: <search not requested>")
            }
            print("LIVE PLANNER END")
        }
    }

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
        let raw = #"{"use_web":true,"topic":"cyclosporiasis outbreak","topic_basis":"cypolcersa virus","information_need":"current US spread and public health guidance","time_scope":"July 2026","query":"cyclosporiasis outbreak current US spread public health guidance July 2026"}"#
        let plan = NexWebSearchPlanner.parse(raw, originalPrompt: "what's that new cypolcersa virus spreading")

        XCTAssertTrue(plan.shouldSearch)
        XCTAssertEqual(plan.queryOrigin, .modelExtraction)
        XCTAssertTrue(plan.query?.contains("cyclosporiasis outbreak") == true)
        XCTAssertTrue(plan.query?.contains("public health guidance") == true)
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

    func testPlannerAcceptsModelJSONWithTypographicDoubleQuotes() {
        let prompt = "Should I bring an umbrella to San Francisco tomorrow afternoon?"
        let plan = NexWebSearchPlanner.parse(
            #"{"use_web":true,"topic":"weather in San Francisco","topic_basis":"tomorrow afternoon","information_need":"forecast for rain in San Francisco tomorrow afternoon","time_scope":"tomorrow afternoon”, “query”:“San Francisco weather forecast tomorrow afternoon”}"#,
            originalPrompt: prompt
        )

        XCTAssertEqual(plan.queryOrigin, .modelExtraction)
        XCTAssertEqual(plan.query, "san francisco weather forecast tomorrow afternoon")
    }

    func testPlannerRejectsUnnecessarySearchForStableExplanation() {
        let prompt = "Explain why neural networks need activation functions."
        let plan = NexWebSearchPlanner.parse(
            #"{"use_web":true,"topic":"neural network activation functions","topic_basis":"why neural networks need activation functions","information_need":"explain the purpose of activation functions in neural networks","time_scope":"none","query":"purpose of activation functions in neural networks"}"#,
            originalPrompt: prompt
        )

        XCTAssertFalse(plan.shouldSearch)
        XCTAssertEqual(plan.queryOrigin, .rejected)
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

    func testStructuredModelExtractionCreatesTheSearchQuery() {
        let prompt = "What changed in the newest Swift release?"
        let plan = NexWebSearchPlanner.parse(
            #"{"use_web":true,"topic":"Apple Swift programming language","topic_basis":"newest Swift release","information_need":"changes introduced in the newest stable release","time_scope":"current","query":"Apple Swift programming language newest stable release changes current"}"#,
            originalPrompt: prompt
        )

        XCTAssertTrue(plan.shouldSearch)
        XCTAssertEqual(plan.queryOrigin, .modelExtraction)
        XCTAssertEqual(
            plan.query,
            "apple swift programming language newest stable release changes current"
        )
    }

    func testStructuredFieldsRepairAOneWordModelQuery() {
        let plan = NexWebSearchPlanner.parse(
            #"{"use_web":true,"topic":"Apple Swift programming language","topic_basis":"newest Swift release","information_need":"changes in the newest stable release","time_scope":"current","query":"you"}"#,
            originalPrompt: "Can you tell me what changed in the newest Swift release?"
        )

        XCTAssertEqual(plan.queryOrigin, .modelExtraction)
        XCTAssertTrue(plan.query?.contains("swift programming language") == true)
        XCTAssertTrue(plan.query?.contains("newest stable release") == true)
        XCTAssertFalse(plan.query?.split(separator: " ").contains("you") == true)
        XCTAssertGreaterThanOrEqual(plan.query?.split(separator: " ").count ?? 0, 5)
    }

    func testPronounOnlyExtractionIsRejectedForWholePromptFallback() {
        let plan = NexWebSearchPlanner.parse(
            #"{"use_web":true,"topic":"you","topic_basis":"you","information_need":"what changed","time_scope":"today","query":"you"}"#,
            originalPrompt: "Can you find the newest Apple Swift release changes today?"
        )

        XCTAssertEqual(plan.queryOrigin, .fallback)
        XCTAssertTrue(plan.query?.contains("apple") == true)
        XCTAssertTrue(plan.query?.contains("swift") == true)
        XCTAssertFalse(plan.query?.split(separator: " ") == ["you"])
    }

    func testCurrentExtractionRejectsAStaleYearFromTheModel() {
        let now = Date(timeIntervalSince1970: 1_784_236_800)
        let query = NexWebSearchQueryBuilder.query(
            fromTopic: "Apple WWDC",
            topicBasis: "Apple announced at WWDC",
            informationNeed: "announcements made at this year's conference",
            timeScope: "current",
            proposedQuery: "Apple WWDC conference announcements from 2024",
            originalPrompt: "What has Apple announced at WWDC this year?",
            now: now
        )

        XCTAssertFalse(query?.contains("2024") == true)
        XCTAssertTrue(query?.contains("2026") == true)
        XCTAssertTrue(query?.contains("apple") == true)
        XCTAssertTrue(query?.contains("announcements") == true)
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
        XCTAssertTrue(messages.contains("Searching “newest Swift release”…"))
        XCTAssertTrue(messages.contains("Reviewing results…"))
        XCTAssertTrue(messages.contains("Reading sources…"))
        XCTAssertTrue(messages.contains("Synthesizing findings…"))
        XCTAssertTrue(messages.contains("Reviewed cached results…"))
    }

    func testSearchQueriesEveryProviderBeforeRanking() async throws {
        let firstCounter = NexSearchCallCounter()
        let secondCounter = NexSearchCallCounter()
        let first = NexProviderSpy(
            name: "first",
            title: "Broad result",
            url: URL(string: "https://8.8.8.8/broad")!,
            counter: firstCounter
        )
        let second = NexProviderSpy(
            name: "second",
            title: "Specific target result",
            url: URL(string: "https://1.1.1.1/specific")!,
            counter: secondCounter
        )
        let service = NexWebSearchService(
            providers: [first, second],
            pageReader: NexMockPageReader(),
            configuration: .init(
                resultLimit: 1,
                pageReadLimit: 0,
                maximumPageBytes: 1_000,
                maximumExtractedCharacters: 1_000,
                cacheLifetime: 60,
                requestTimeout: 2
            )
        )

        let response = try await service.search(query: "specific target") { _, _ in }

        let firstCalls = await firstCounter.value
        let secondCalls = await secondCounter.value
        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(secondCalls, 1)
        XCTAssertEqual(response.providers, ["first", "second"])
        XCTAssertEqual(response.results.first?.title, "Specific target result")
    }

    func testRankingPrefersCompleteNamedPhraseOverSharedWord() {
        let results = [
            NexWebSearchResult(
                title: "San Diego weather forecast",
                url: URL(string: "https://example.com/san-diego")!,
                snippet: "Weather forecast for Southern California.",
                extractedText: nil,
                publishedAt: Date(),
                provider: "test",
                retrievalStatus: .snippetOnly
            ),
            NexWebSearchResult(
                title: "San Francisco weather forecast",
                url: URL(string: "https://example.com/san-francisco")!,
                snippet: "Tomorrow afternoon forecast for San Francisco.",
                extractedText: nil,
                publishedAt: nil,
                provider: "test",
                retrievalStatus: .snippetOnly
            )
        ]

        let ranked = NexWebResultRanker.rankAndDeduplicate(
            results,
            query: "san francisco weather forecast tomorrow afternoon",
            limit: 2
        )

        XCTAssertEqual(ranked.first?.title, "San Francisco weather forecast")
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

private struct NexProviderSpy: NexWebSearchProviding {
    let name: String
    let title: String
    let url: URL
    let counter: NexSearchCallCounter

    func search(query: String, limit: Int) async throws -> [NexWebSearchResult] {
        await counter.increment()
        return [.init(
            title: title,
            url: url,
            snippet: title,
            extractedText: nil,
            publishedAt: Date(),
            provider: name,
            retrievalStatus: .snippetOnly
        )]
    }
}

private struct NexSlowSearchProvider: NexWebSearchProviding {
    let name = "Slow mock"

    func search(query: String, limit: Int) async throws -> [NexWebSearchResult] {
        try await Task.sleep(for: .seconds(5))
        return []
    }
}
