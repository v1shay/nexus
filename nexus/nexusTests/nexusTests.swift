import XCTest
import WebKit
@testable import nexus

final class NexusGeometryTests: XCTestCase {
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

    func testAcknowledgementMatchesThePromptIntent() {
        XCTAssertEqual(PromptAcknowledgement.text(for: "Search Google for Swift"), "Got it. I’ll look into that.")
        XCTAssertEqual(PromptAcknowledgement.text(for: "Build a prototype"), "Understood. I’ll put that together.")
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
