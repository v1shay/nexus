import XCTest
import WebKit
@testable import nexus

final class NexusGeometryTests: XCTestCase {
    func testOneWordFollowUpKeepsRecentVerbatimConversationContext() async {
        let session = NexConversationSession()
        await session.appendUser("Use a neural network for the image classifier")
        await session.appendAssistant("A compact convolutional network fits that task.")
        await session.appendUser("Why?")

        let messages = await session.contextMessages()

        XCTAssertEqual(
            messages.filter { $0.role != "system" }.suffix(3).map(\.role),
            ["user", "assistant", "user"]
        )
        XCTAssertEqual(messages.last?.content, "Why?")
        XCTAssertTrue(messages.contains(where: { $0.content.contains("convolutional network") }))
    }

    func testLongConversationKeepsRollingSummaryCurrentTaskAndRecentTurns() async {
        let session = NexConversationSession()
        for index in 0..<20 {
            await session.appendUser("Project Atlas step \(index): should we continue?")
            await session.appendAssistant("Completed Atlas step \(index).")
        }

        let snapshot = await session.snapshot()
        let messages = await session.contextMessages()

        XCTAssertTrue(snapshot.summary.contains("Atlas"))
        XCTAssertEqual(snapshot.currentTask, "Project Atlas step 19: should we continue?")
        XCTAssertTrue(snapshot.entities.contains(where: { $0.contains("Project Atlas") }))
        XCTAssertLessThanOrEqual(messages.filter { $0.role != "system" }.count, NexConversationSession.recentTurnLimit)
        XCTAssertTrue(messages.first?.content.contains("Rolling summary") == true)
    }

    func testDictationWingsPreserveThePhysicalNotchGap() {
        let physicalNotch = CGSize(width: 190, height: 32)
        let listening = NotchGeometry.listeningSize(for: physicalNotch)
        let regions = NotchGeometry.horizontalRegions(in: listening)

        XCTAssertEqual(listening.width, 314)
        XCTAssertEqual(regions.leftWing.width, 62)
        XCTAssertEqual(regions.notchGap.width, physicalNotch.width)
        XCTAssertEqual(regions.rightWing.width, 62)
        XCTAssertEqual(regions.leftWing.maxX, regions.notchGap.minX)
        XCTAssertEqual(regions.notchGap.maxX, regions.rightWing.minX)
        XCTAssertEqual(regions.rightWing.maxX, listening.width)
    }

    func testDictationReleaseSavesTextAndOpensOverlay() {
        var state = NotchInteractionState()
        state.beginDictation()
        state.updateTranscript("Send the project update")
        state.finishDictation()

        XCTAssertEqual(state.presentation, .overlay)
        XCTAssertEqual(state.transcript, "Send the project update")
    }

    func testEveryNotchFrameRemainsCenteredDuringExpansion() {
        let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let closed = NotchGeometry.centeredTopFrame(
            for: CGSize(width: 190, height: 32),
            on: screen
        )
        let expanded = NotchGeometry.centeredTopFrame(
            for: CGSize(width: 680, height: 245),
            on: screen
        )

        XCTAssertEqual(closed.midX, screen.midX)
        XCTAssertEqual(expanded.midX, screen.midX)
        XCTAssertEqual(closed.maxY, screen.maxY)
        XCTAssertEqual(expanded.maxY, screen.maxY)
    }

    func testOllamaRegistryParserExtractsOfficialLibraryModels() {
        let html = #"<a href="/library/llama3.2"></a><a href="/library/qwen3"></a><a href="/download"></a>"#
        let identifiers = ModelCatalogService.matches(
            pattern: ##"href="/library/([^"#?]+)""##,
            in: html
        )

        XCTAssertEqual(identifiers, ["llama3.2", "qwen3"])
    }

    func testRAMRecommendationEstimateUnderstandsParameterTags() {
        XCTAssertEqual(ModelCatalog.estimatedMinimumRAM(for: "gemma3:12b"), 11)
        XCTAssertEqual(ModelCatalog.estimatedMinimumRAM(for: "model-without-size"), 0)
    }

    func testBatteryPercentageUsesCapacityAndStaysWithinDisplayBounds() {
        XCTAssertEqual(BatteryStatusReader.percentage(current: 81, maximum: 100), 81)
        XCTAssertEqual(BatteryStatusReader.percentage(current: 1, maximum: 3), 33)
        XCTAssertEqual(BatteryStatusReader.percentage(current: 120, maximum: 100), 100)
        XCTAssertEqual(BatteryStatusReader.percentage(current: -5, maximum: 100), 0)
        XCTAssertNil(BatteryStatusReader.percentage(current: 50, maximum: 0))
    }

    func testOnlyPreparationAndDownloadsAreActiveStates() {
        XCTAssertTrue(ModelDownloadState.preparing("Starting").isActive)
        XCTAssertTrue(ModelDownloadState.downloading(progress: 0.5, completedBytes: 50, totalBytes: 100, status: "pulling").isActive)
        XCTAssertFalse(ModelDownloadState.installed.isActive)
        XCTAssertFalse(ModelDownloadState.failed("failed").isActive)
    }

    func testPromptThinkingAndAnswerPresentationFlow() {
        var state = NotchInteractionState()
        state.beginDictation()
        state.updateTranscript("What is a local model?")
        state.finishDictation()
        XCTAssertEqual(state.presentation, .overlay)

        state.beginThinking()
        XCTAssertEqual(state.presentation, .thinking)

        state.receivePartialAnswer("A model running")
        XCTAssertEqual(state.presentation, .overlay)
        XCTAssertEqual(state.answer, "A model running")

        state.receiveAnswer("A model running on your own computer.")
        XCTAssertEqual(state.presentation, .overlay)
        XCTAssertEqual(state.transcript, "What is a local model?")
        XCTAssertEqual(state.answer, "A model running on your own computer.")
    }

    func testAnswerCanContinueStreamingWhileTheOverlayStaysCollapsed() {
        var state = NotchInteractionState()
        state.beginDictation()
        state.updateTranscript("Keep working after I dismiss you")
        state.finishDictation()
        state.receivePartialAnswer("Still working", reveal: false)

        XCTAssertEqual(state.presentation, .idle)
        XCTAssertEqual(state.answer, "Still working")

        state.showOverlay()
        XCTAssertEqual(state.presentation, .overlay)
        XCTAssertEqual(state.answer, "Still working")
    }

    func testPhysicalNotchAndPanelShareOneHoverSession() {
        var session = NotchHoverSession()

        XCTAssertEqual(session.update(isInside: true), true)
        XCTAssertNil(session.update(isInside: true), "Mouse moves inside the notch must not relaunch the animation")
        XCTAssertNil(session.update(isInside: true), "Crossing from the cutout into the panel remains the same visit")
        XCTAssertEqual(session.update(isInside: false), false)
        XCTAssertNil(session.update(isInside: false))
        XCTAssertEqual(session.update(isInside: true), true, "A new visit may launch after a complete exit")
    }

    func testManualCloseDoesNotDisableAReopenOrLaterDictation() {
        var state = NotchInteractionState()
        state.beginDictation()
        state.updateTranscript("First request")
        state.finishDictation()
        state.dismiss()

        XCTAssertEqual(state.presentation, .idle)
        state.showOverlay()
        XCTAssertEqual(state.presentation, .overlay, "Hover can reopen after a manual close")

        state.dismiss()
        state.beginDictation()
        XCTAssertEqual(state.presentation, .dictating, "The global hotkey can start a new session after close")
    }

    func testStreamedSpeechWaitsForNaturalSentenceBoundaries() {
        var chunker = SpeechSentenceChunker()

        XCTAssertEqual(chunker.append("Hello from Nex"), [])
        XCTAssertEqual(chunker.append("us. How can I help"), ["Hello from Nexus."])
        XCTAssertEqual(chunker.append("?"), ["How can I help?"])
        XCTAssertNil(chunker.flush())
    }

    func testStreamedSpeechFlushesShortPartialOutputWithoutWaitingForCompletion() {
        var chunker = SpeechSentenceChunker()

        XCTAssertEqual(chunker.append("The first streamed phrase"), [])
        XCTAssertEqual(chunker.flush(), "The first streamed phrase")
    }

    func testIdleSpeechFlushNeverCutsAStreamedWordInHalf() {
        var chunker = SpeechSentenceChunker()

        XCTAssertEqual(chunker.append("Streaming can become confu"), [])
        XCTAssertEqual(chunker.flushReadyPrefix(), "Streaming can become")
        XCTAssertEqual(
            chunker.append("sed when token delivery pauses."),
            ["confused when token delivery pauses."]
        )
    }

    func testSpeechCursorDropsDuplicateAndStaleStreamingEvents() {
        var cursor = StreamedSpeechCursor()

        XCTAssertEqual(cursor.consume(delta: "Hel", accumulated: "Hel"), "Hel")
        XCTAssertEqual(cursor.consume(delta: "Hel", accumulated: "Hel"), "")
        XCTAssertEqual(cursor.consume(delta: "lo", accumulated: "Hello"), "lo")
        XCTAssertEqual(cursor.consume(delta: "l", accumulated: "Hel"), "")
        XCTAssertEqual(cursor.text, "Hello")
        XCTAssertEqual(cursor.consume(delta: "!", accumulated: "Hello!"), "!")
    }

    func testPCMChunksAreRestoredToArrivalOrderBeforePlayback() {
        var buffer = OrderedDataChunkBuffer()
        let first = Data([1])
        let second = Data([2])
        let third = Data([3])

        XCTAssertEqual(buffer.insert(second, sequence: 1), [])
        XCTAssertEqual(buffer.insert(first, sequence: 0), [first, second])
        XCTAssertEqual(buffer.insert(third, sequence: 2), [third])
        XCTAssertEqual(buffer.insert(second, sequence: 1), [], "Played PCM must not be replayed")
    }

    func testDefaultModelInstructionsStayCompactAndDefaultToProse() {
        let instructions = NexusResponseInstructions.conciseSystemPrompt

        XCTAssertTrue(instructions.contains("You are Nex, Vishay's personal assistant"))
        XCTAssertTrue(instructions.contains("natural language by default"))
        XCTAssertTrue(instructions.contains("prior assistant claims are not evidence"))
        XCTAssertTrue(instructions.contains("Never turn advice, recommendations, workouts"))
        XCTAssertTrue(instructions.contains("never expose citations, source IDs"))
        XCTAssertLessThan(instructions.split(whereSeparator: \.isWhitespace).count, 180)
    }

    func testResponseModePreventsCodeLeakageIntoOrdinaryRequests() {
        let ordinaryPrompts = [
            "Give me an ab workout I can do on my bed",
            "Should I do open source contributions for college?",
            "What is the best demo for my AI agent?",
            "Is this a bad idea?",
            "Roast my project idea"
        ]
        for prompt in ordinaryPrompts {
            XCTAssertEqual(
                NexResponseMode.infer(from: [.init(role: .user, text: prompt)]),
                .prose,
                prompt
            )
        }

        XCTAssertEqual(
            NexResponseMode.infer(from: [.init(role: .user, text: "Write a Swift function that sorts this array")]),
            .code
        )
        XCTAssertEqual(
            NexResponseMode.infer(from: [
                .init(role: .user, text: "Implement this parser in Python"),
                .init(role: .assistant, text: "I started the parser."),
                .init(role: .user, text: "Continue")
            ]),
            .code
        )
        XCTAssertEqual(
            NexResponseMode.infer(from: [
                .init(role: .user, text: "Implement this parser in Python"),
                .init(role: .assistant, text: "I started the parser."),
                .init(role: .user, text: "Should I do open source contributions for college?")
            ]),
            .prose
        )
    }

    func testConversationContextPlacesResponseModeImmediatelyBeforeCurrentTurn() async {
        let session = NexConversationSession()
        await session.appendUser("Write a Python function")
        await session.appendAssistant("Here is the implementation.")
        await session.appendUser("Give me an ab workout on my bed")

        let messages = await session.contextMessages()

        XCTAssertEqual(messages.last?.role, "user")
        XCTAssertEqual(messages.last?.content, "Give me an ab workout on my bed")
        XCTAssertEqual(messages.dropLast().last?.role, "system")
        XCTAssertTrue(messages.dropLast().last?.content.contains("PROSE") == true)
    }

    func testAssistantIdentityIsHandledExactlyAndNeverConfusedWithUserIdentity() {
        XCTAssertEqual(
            NexAssistantIdentityIntent.answer(for: "Who are you?"),
            NexAssistantIdentityIntent.answer
        )
        XCTAssertEqual(
            NexAssistantIdentityIntent.answer(for: "What's your name?"),
            NexAssistantIdentityIntent.answer
        )
        XCTAssertNil(NexAssistantIdentityIntent.answer(for: "What's my name?"))
        XCTAssertNil(NexAssistantIdentityIntent.answer(for: "Write a Python function"))
        XCTAssertNil(NexAssistantIdentityIntent.answer(for: "What is a neural network?"))
    }

    func testStreamingSpeechSkipsFencedCodeSplitAcrossTokens() {
        var filter = StreamingSpeechMarkdownFilter()
        var spoken = filter.append("I built the parser in Python.\n``")
        spoken += filter.append("`python\nprint('do not speak me')\n``")
        spoken += filter.append("`\nIt is ready.")
        spoken += filter.finish()

        XCTAssertTrue(spoken.contains("I built the parser in Python."))
        XCTAssertTrue(spoken.contains("Here is the Python code."))
        XCTAssertTrue(spoken.contains("It is ready."))
        XCTAssertFalse(spoken.contains("print"))
        XCTAssertFalse(spoken.contains("do not speak me"))
    }

    func testStreamingSpeechAnnouncesAnUnlabelledCodeBlockOnce() {
        var filter = StreamingSpeechMarkdownFilter()
        let spoken = filter.append("```\nlet secret = 1\n```") + filter.finish()

        XCTAssertEqual(spoken.components(separatedBy: "Here is the code.").count - 1, 1)
        XCTAssertFalse(spoken.contains("secret"))
    }

    func testStreamingSpeechReadsLinkLabelsButNeverCitationURLs() {
        var filter = StreamingSpeechMarkdownFilter()
        var spoken = filter.append("According to [Swift release")
        spoken += filter.append(" notes](https://swift.org/blog/release-(latest)), it changed.")
        spoken += filter.finish()

        XCTAssertTrue(spoken.contains("Swift release notes"))
        XCTAssertTrue(spoken.contains("it changed"))
        XCTAssertFalse(spoken.contains("https"))
        XCTAssertFalse(spoken.contains("swift.org"))
        XCTAssertEqual(
            SpeechSanitizer.forSpeech("Source https://example.com/news?id=1"),
            "Source"
        )
    }

    func testThinkingBeginsOnlyAfterAcknowledgementStateIsFinished() {
        var state = NotchInteractionState()
        state.beginDictation()
        state.updateTranscript("Explain streaming")
        state.finishDictation()
        state.acknowledge("Got it. Let me work through that.")

        XCTAssertEqual(state.presentation, .overlay)
        state.beginThinking()
        XCTAssertEqual(state.presentation, .thinking)
    }

    func testAcknowledgementMatchesThePromptIntent() {
        XCTAssertEqual(PromptAcknowledgement.text(for: "What is photosynthesis?", choosing: 0), "Looking into it…")
        XCTAssertEqual(PromptAcknowledgement.text(for: "Find the missing document", choosing: 0), "Tracking it down…")
        XCTAssertEqual(PromptAcknowledgement.text(for: "Generate a logo", choosing: 0), "Building it out…")
        XCTAssertEqual(PromptAcknowledgement.text(for: "Explain photosynthesis", choosing: 0), "Breaking it apart…")
        XCTAssertEqual(PromptAcknowledgement.text(for: "Solve this equation", choosing: 0), "Running the numbers…")
        XCTAssertEqual(PromptAcknowledgement.text(for: "Debug this Swift code", choosing: 0), "Tracing the issue…")
        XCTAssertEqual(Set(PromptAcknowledgement.candidates(for: "Find this")).count, 8)
        XCTAssertNotEqual(
            PromptAcknowledgement.text(for: "Find this", avoiding: "Tracking it down…", choosing: 0),
            "Tracking it down…"
        )
    }

    func testLegacyDownloadedOllamaModelBecomesRestorableDefault() {
        let model = LocalModel.restoring(legacyID: "ollama:gemma3:4b:default")

        XCTAssertEqual(model?.backend, .ollama)
        XCTAssertEqual(model?.identifier, "gemma3:4b")
        XCTAssertEqual(model?.id, "ollama:gemma3:4b:default")
    }

    func testMarkdownSeparatesProseCodeAndDisplayMath() {
        let markdown = """
        **Result:** use this function.

        ```swift
        print("hello")
        ```

        $$E = mc^2$$
        """

        XCTAssertEqual(MarkdownBlockParser.parse(markdown), [
            .prose("**Result:** use this function."),
            .code(language: "swift", content: "print(\"hello\")"),
            .math("E = mc^2")
        ])
    }

    func testFutureGoogleToolActivityCarriesUIAndVoiceStatus() {
        let activity = ToolActivity.googleSearch(query: "Swift concurrency")
        var state = NotchInteractionState()
        state.beginDictation()
        state.updateTranscript("Research Swift concurrency")
        state.finishDictation()
        state.beginToolActivity(activity)

        XCTAssertEqual(state.presentation, .tool)
        XCTAssertEqual(state.toolActivity?.status, "Researching Swift concurrency with Google")
        XCTAssertEqual(state.toolActivity?.spokenStatus, "Searching Google for Swift concurrency.")
        if case .svg(let data, _) = activity.icon {
            XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("<svg") == true)
        } else {
            XCTFail("Google Search should carry its SVG icon")
        }
    }

    func testCompletedToolReceiptSurvivesThinkingAndStreamingUntilNewDictation() {
        let executionID = UUID()
        let started = NexToolLifecycleEvent(
            executionID: executionID,
            toolName: "memory_search",
            phase: .started,
            message: "Checking memory…",
            progress: nil,
            errorCode: nil,
            occurredAt: Date()
        )
        let completed = NexToolLifecycleEvent(
            executionID: executionID,
            toolName: "memory_search",
            phase: .completed,
            message: "Used memory · 3 sources",
            progress: 1,
            errorCode: nil,
            occurredAt: Date(),
            result: .object([
                "results": .array([
                    .object([
                        "source_id": .string("profile-id"),
                        "chunk_id": .string("profile-id:memory:0"),
                        "title": .string("Identity and background"),
                        "excerpt": .string("Vishay attends Lynbrook High School.")
                    ])
                ])
            ])
        )
        var state = NotchInteractionState()
        state.beginDictation()
        state.updateTranscript("What is my name?")
        state.finishDictation()

        state.beginToolActivity(.lifecycle(started))
        XCTAssertEqual(state.presentation, .tool)
        XCTAssertEqual(state.toolActivity?.status, "Checking memory…")

        state.completeToolActivity(.lifecycle(completed))
        XCTAssertEqual(state.presentation, .tool)
        XCTAssertEqual(state.toolReceipt?.status, "Used memory · 3 sources")
        XCTAssertEqual(state.toolReceipt?.sources.first?.title, "Identity and background")
        if case .asset(let name, _) = state.toolReceipt?.icon {
            XCTAssertEqual(name, "Obsidian")
        } else {
            XCTFail("Memory activity should use the bundled Obsidian SVG asset")
        }

        state.beginThinking()
        XCTAssertEqual(state.presentation, .thinking)
        XCTAssertNil(state.toolActivity)
        XCTAssertEqual(state.toolReceipt?.status, "Used memory · 3 sources")

        state.receivePartialAnswer("Your name is Vishay.")
        XCTAssertEqual(state.presentation, .overlay)
        XCTAssertEqual(state.toolReceipt?.status, "Used memory · 3 sources")

        state.beginDictation()
        XCTAssertNil(state.toolReceipt)
    }

    func testInlineLatexIsSeparatedFromMarkdownProse() {
        XCTAssertEqual(
            InlineMathParser.parse("Energy is $E=mc^2$ in this example."),
            [.text("Energy is "), .math("E=mc^2"), .text(" in this example.")]
        )
        XCTAssertEqual(
            InlineMathParser.parse(#"Use \(x + y\) next."#),
            [.text("Use "), .math("x + y"), .text(" next.")]
        )
    }

    func testMarkdownProsePreservesLineBreaksAndVisibleIndentation() {
        let rendered = MarkdownProseFormatter.render("First line\n\tIndented line")

        XCTAssertEqual(rendered, "First line\n\u{00a0}\u{00a0}\u{00a0}\u{00a0}Indented line")
    }

    func testInlineLatexBecomesReadableWithoutAnUnwrappableSubviewRow() {
        XCTAssertEqual(
            MarkdownProseFormatter.render(#"Energy is $E=mc^2$ and $\alpha \leq \beta$."#),
            "Energy is E=mc² and α ≤ β."
        )
    }

    func testDisplayLatexUsesOnlyBundledKaTeXAssets() {
        let document = KaTeXHTML.document(for: #"\frac{x}{y}"#)

        XCTAssertTrue(document.contains("katex.min.css"))
        XCTAssertTrue(document.contains("katex.min.js"))
        XCTAssertFalse(document.contains("https://"))
        XCTAssertTrue(document.contains(#"\\frac{x}{y}"#))
    }

    @MainActor
    func testBundledKaTeXRendersAnEquationInsideWebKit() async throws {
        let resourceDirectory = try XCTUnwrap(
            Bundle.main.resourceURL?.appendingPathComponent("KaTeX", isDirectory: true)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: resourceDirectory.appendingPathComponent("katex.min.js").path))

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 520, height: 120))
        webView.loadHTMLString(
            KaTeXHTML.document(for: #"\frac{x^2 + y^2}{\sqrt{z}}"#),
            baseURL: resourceDirectory
        )

        var didRender = false
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            if let value = try? await webView.evaluateJavaScript("Boolean(document.querySelector('.katex'))"),
               value as? Bool == true {
                didRender = true
                break
            }
        }
        XCTAssertTrue(didRender, "The bundled KaTeX script should replace raw LaTeX with rendered math")
    }

    func testAllSixBundledPetsHaveValidAnimationAtlases() throws {
        XCTAssertEqual(NexusPetCatalog.all.map(\.id), [
            "tiko", "kabi", "macintosh", "lil-finder", "crt-pal", "pan-chan-laptop"
        ])

        for pet in NexusPetCatalog.all {
            let url = try XCTUnwrap(
                Bundle.main.url(
                    forResource: "spritesheet",
                    withExtension: "webp",
                    subdirectory: "Pets/\(pet.id)"
                ),
                "Missing bundled atlas for \(pet.id)"
            )
            let image = try XCTUnwrap(NSImage(contentsOf: url))
            XCTAssertEqual(image.size, CGSize(width: 1_536, height: 1_872), pet.id)
        }
    }

    func testPetActivitiesUseTheSuppliedTaskSpecificRows() {
        XCTAssertEqual(NexusPetActivity.idle.atlasRow, 0)
        XCTAssertEqual(NexusPetActivity.dictating.atlasRow, 6)
        XCTAssertEqual(NexusPetActivity.thinking.atlasRow, 7)
        XCTAssertEqual(NexusPetActivity.tool.atlasRow, 7)
        XCTAssertEqual(NexusPetActivity.overlay.atlasRow, 8)
    }

    func testHoldingCommandAloneStartsAndReleaseEndsDictation() {
        var gesture = CommandHoldGestureState()

        XCTAssertNil(gesture.update(commandIsDown: true, hasDisqualifyingInput: false, now: 10))
        XCTAssertNil(gesture.update(commandIsDown: true, hasDisqualifyingInput: false, now: 10.64))
        XCTAssertEqual(
            gesture.update(commandIsDown: true, hasDisqualifyingInput: false, now: 10.65),
            .began
        )
        XCTAssertEqual(
            gesture.update(commandIsDown: false, hasDisqualifyingInput: false, now: 10.75),
            .ended
        )
    }

    func testDoubleCommandTapRequestsAQuickDismiss() {
        var gesture = CommandHoldGestureState()

        XCTAssertNil(gesture.update(commandIsDown: true, hasDisqualifyingInput: false, now: 15.00))
        XCTAssertNil(gesture.update(commandIsDown: false, hasDisqualifyingInput: false, now: 15.08))
        XCTAssertNil(gesture.update(commandIsDown: true, hasDisqualifyingInput: false, now: 15.22))
        XCTAssertEqual(
            gesture.update(commandIsDown: false, hasDisqualifyingInput: false, now: 15.30),
            .doubleTapped
        )
    }

    func testCommandShortcutsCannotBecomeDoubleCommandTaps() {
        var gesture = CommandHoldGestureState()

        XCTAssertNil(gesture.update(commandIsDown: true, hasDisqualifyingInput: false, now: 16.00))
        XCTAssertNil(gesture.update(commandIsDown: true, hasDisqualifyingInput: true, now: 16.04))
        XCTAssertNil(gesture.update(commandIsDown: false, hasDisqualifyingInput: true, now: 16.10))
        XCTAssertNil(gesture.update(commandIsDown: true, hasDisqualifyingInput: false, now: 16.20))
        XCTAssertNil(gesture.update(commandIsDown: false, hasDisqualifyingInput: false, now: 16.28))
    }

    func testQuickCommandTapAndCommandShortcutDoNotStartDictation() {
        var quickTap = CommandHoldGestureState()
        XCTAssertNil(quickTap.update(commandIsDown: true, hasDisqualifyingInput: false, now: 20))
        XCTAssertNil(quickTap.update(commandIsDown: false, hasDisqualifyingInput: false, now: 20.10))

        var shortcut = CommandHoldGestureState()
        XCTAssertNil(shortcut.update(commandIsDown: true, hasDisqualifyingInput: false, now: 30))
        XCTAssertNil(shortcut.update(commandIsDown: true, hasDisqualifyingInput: true, now: 30.05))
        XCTAssertNil(shortcut.update(commandIsDown: true, hasDisqualifyingInput: false, now: 30.40))
        XCTAssertNil(shortcut.update(commandIsDown: false, hasDisqualifyingInput: false, now: 30.50))
    }

    func testCommandClickCancellationEndsAnActiveHoldWithoutRestartingIt() {
        var gesture = CommandHoldGestureState()
        XCTAssertNil(gesture.update(commandIsDown: true, hasDisqualifyingInput: false, now: 40))
        XCTAssertEqual(
            gesture.update(commandIsDown: true, hasDisqualifyingInput: false, now: 40.65),
            .began
        )
        XCTAssertEqual(
            gesture.update(commandIsDown: true, hasDisqualifyingInput: true, now: 40.20),
            .ended
        )
        XCTAssertNil(gesture.update(commandIsDown: true, hasDisqualifyingInput: false, now: 40.50))
        XCTAssertNil(gesture.update(commandIsDown: false, hasDisqualifyingInput: false, now: 40.60))
    }

}
