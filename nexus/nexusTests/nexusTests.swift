import XCTest
import WebKit
@testable import nexus

final class NexusGeometryTests: XCTestCase {
    func testManagedCloudConfigurationOrderIsInceptionThenNVIDIA() throws {
        let store = NexusManagedCloudInferenceStore(secrets: NexusMemorySecretStore())
        XCTAssertTrue(try store.configurations().isEmpty)

        let secrets = NexusMemorySecretStore()
        try secrets.set(Data("inception-test".utf8), for: NexusManagedCloudProvider.inception.keyAccount)
        try secrets.set(Data("nvidia-test".utf8), for: NexusManagedCloudProvider.nvidiaNIM.keyAccount)
        let configured = try NexusManagedCloudInferenceStore(secrets: secrets).configurations()

        XCTAssertEqual(configured.map(\.provider), [.inception, .nvidiaNIM])
        XCTAssertEqual(configured.map { $0.configuration.model }, ["mercury-2", "openai/gpt-oss-120b"])
    }

    func testLiveManagedCloudChainFallsBackToInceptionWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["NEXUS_LIVE_CLOUD_TEST"] == "1" else {
            throw XCTSkip("Set NEXUS_LIVE_CLOUD_TEST=1 to make this opt-in provider integration test.")
        }
        let attempts = try NexusManagedCloudInferenceStore().configurations()
        guard attempts.count == 2 else {
            throw XCTSkip("Both managed cloud credentials are required for this live fallback test.")
        }

        let result = try await NexusManagedCloudInferenceClient.streamChat(
            attempts: attempts,
            messages: [.init(role: "user", content: "Reply with exactly: cloud fallback verified")],
            temperature: 0,
            maximumTokens: 128,
            onDelta: { _, _ in }
        )

        XCTAssertEqual(result.provider, .inception)
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testChromeMediaClassificationBuildsStableYouTubeThumbnail() throws {
        let url = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abc123&feature=share"))
        let tab = BrowserTab(
            id: "chrome:1:2:abc",
            windowIndex: 1,
            tabIndex: 2,
            title: "A video",
            url: url,
            isActive: true
        )

        let media = try XCTUnwrap(MediaTab(tab: tab))
        XCTAssertEqual(media.platform, .youtube)
        XCTAssertEqual(media.mediaID, "abc123")
        XCTAssertEqual(media.thumbnailURL?.absoluteString, "https://img.youtube.com/vi/abc123/mqdefault.jpg")
        XCTAssertEqual(media.priority, 130)
    }

    func testYouTubeOverlayUsesTheExistingWatchURLRatherThanEmbed() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abc123&feature=share"))
        let tab = BrowserTab(
            id: "chrome:1:2:abc",
            windowIndex: 1,
            tabIndex: 2,
            title: "A video",
            url: sourceURL,
            isActive: true
        )
        let media = try XCTUnwrap(MediaTab(tab: tab))

        let playbackURL = try XCTUnwrap(YouTubePlaybackURL.make(for: media))
        let components = try XCTUnwrap(URLComponents(url: playbackURL, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "www.youtube.com")
        XCTAssertEqual(components.path, "/watch")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "v" })?.value, "abc123")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "autoplay" })?.value, "1")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "mute" })?.value, "1")
        XCTAssertFalse(playbackURL.absoluteString.contains("/embed/"))
    }

    func testCompactMediaClickReservesOnlyArtworkForSourceNavigation() {
        XCTAssertEqual(NotchGeometry.mediaClickTarget(for: NSPoint(x: 12, y: 16)), .source)
        XCTAssertEqual(NotchGeometry.mediaClickTarget(for: NSPoint(x: 52, y: 16)), .source)
        XCTAssertEqual(NotchGeometry.mediaClickTarget(for: NSPoint(x: 53, y: 16)), .overlay)
        XCTAssertEqual(NotchGeometry.mediaClickTarget(for: NSPoint(x: 176, y: 16)), .overlay)
    }

    func testMediaOverlayReplacesTransientToolPresentation() {
        var state = NotchInteractionState()
        state.beginToolActivity(ToolActivity(
            toolName: "YouTube",
            status: "Opening YouTube…",
            spokenStatus: "Opening YouTube.",
            icon: .systemSymbol("play.rectangle.fill")
        ))

        state.showMediaOverlay()

        XCTAssertEqual(state.presentation, .overlay)
        XCTAssertNil(state.toolActivity)
    }

    func testYouTubeSearchParserKeepsDistinctStableVideoIDs() {
        let page = #"""
        {"videoId":"abcDEF_1234"}{"videoId":"abcDEF_1234"}
        {"videoId":"ZyxWVUT-987"}{"notVideoId":"ignore"}
        """#
        XCTAssertEqual(NexYouTubeSearchService.videoIDs(in: page), ["abcDEF_1234", "ZyxWVUT-987"])
        XCTAssertTrue(NexYouTubeToolController.isValidVideoID("abcDEF_1234"))
        XCTAssertFalse(NexYouTubeToolController.isValidVideoID("not a video"))
    }

    func testMediaFullscreenVoiceCommandIsNarrowAndDeterministic() {
        XCTAssertTrue(NexMediaVoiceCommand.requestsFullscreen("enlarge"))
        XCTAssertTrue(NexMediaVoiceCommand.requestsFullscreen("full screen please"))
        XCTAssertTrue(NexMediaVoiceCommand.requestsFullscreen("full scren"))
        XCTAssertTrue(NexMediaVoiceCommand.requestsFullscreen("make it bigger"))
        XCTAssertTrue(NexMediaVoiceCommand.requestsFullscreen("Nex, make it full screen please"))
        XCTAssertFalse(NexMediaVoiceCommand.requestsFullscreen("make my answer bigger"))
    }

    func testSystemPromptDescribesYouTubeToolContract() {
        let prompt = NexusResponseInstructions.completeSystemPrompt
        XCTAssertTrue(prompt.contains("youtube_play_current"))
        XCTAssertTrue(prompt.contains("youtube_search"))
        XCTAssertTrue(prompt.contains("youtube_play"))
        XCTAssertTrue(prompt.contains("youtube_fullscreen"))
    }

    func testFullscreenMediaRejectsLateHoverAndToolResizeRequests() {
        let screen = CGSize(width: 1_728, height: 1_117)
        let resolved = NexusMediaFullscreenSizing.resolvedSize(
            requested: CGSize(width: 820, height: 461),
            screenSize: screen,
            mediaIsActive: true,
            isFullscreen: true,
            presentation: .overlay
        )
        XCTAssertEqual(resolved, screen)

        let dictation = NexusMediaFullscreenSizing.resolvedSize(
            requested: CGSize(width: 300, height: 38),
            screenSize: screen,
            mediaIsActive: true,
            isFullscreen: true,
            presentation: .dictating
        )
        XCTAssertEqual(dictation, CGSize(width: 300, height: 38))
    }

    @MainActor
    func testCurrentYouTubeToolUsesOnlyTheActiveChromeVideo() async throws {
        let url = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=abcDEF_1234"))
        let active = BrowserTab(
            id: "chrome:1:1:test",
            windowIndex: 1,
            tabIndex: 1,
            title: "Test video",
            url: url,
            isActive: true
        )
        let provider = YouTubeToolTestTabs(active: active)
        let registry = NexToolRegistry()
        var selected: MediaTab?
        let controller = NexYouTubeToolController(registry: registry, browserTabs: provider) { tab, fullscreen in
            selected = tab
            return !fullscreen && tab?.mediaID == "abcDEF_1234"
        }

        try await controller.registerIfNeeded()
        let result = try await registry.execute(name: "youtube_play_current", arguments: [:], invocation: .modelReadOnly)

        XCTAssertEqual(selected?.tab.id, active.id)
        guard case .object(let object) = result else {
            return XCTFail("Expected a structured YouTube result")
        }
        XCTAssertEqual(object["video_id"], .string("abcDEF_1234"))
    }

    func testChromeMediaClassificationKeepsNonMediaTabsOutOfTheNotch() throws {
        let url = try XCTUnwrap(URL(string: "https://developer.apple.com/documentation"))
        let tab = BrowserTab(
            id: "chrome:1:1:docs",
            windowIndex: 1,
            tabIndex: 1,
            title: "Documentation",
            url: url,
            isActive: true
        )

        XCTAssertNil(MediaTab(tab: tab))
        XCTAssertEqual(MediaPlatform.classify(url: try XCTUnwrap(URL(string: "https://x.com/a/status/42"))), .x)
        XCTAssertEqual(MediaPlatform.classify(url: try XCTUnwrap(URL(string: "https://www.twitch.tv/nexus"))), .twitch)
    }

    func testThinkingDisplayHidesQuotesAndPeriodsWithoutRemovingWords() {
        XCTAssertEqual(
            NotchInteractionState.sanitizedThinkingDisplay("Calling web_search. \"Checking sources.\""),
            "Calling web_search Checking sources"
        )
        XCTAssertEqual(NexusStatusLineGenerator.classify("Build me a Swift menu bar app"), .code)
        XCTAssertEqual(NexusStatusLineGenerator.classify("What is tomorrow's weather?"), .tool)
        XCTAssertEqual(NexusStatusLineGenerator.classify("Explain recursion"), .question)
        XCTAssertEqual(
            NexusStatusLineGenerator.status(for: "Explain recursion"),
            NexusStatusLineGenerator.status(for: "Explain recursion")
        )
    }

    func testWebSearchQueryGetsItsOwnCompactRevealLine() {
        let activity = ToolActivity(
            toolName: "Web Search",
            status: "Searching",
            spokenStatus: "Searching the web.",
            icon: .systemSymbol("globe"),
            query: "Swift 6.2 release notes"
        )
        XCTAssertTrue(activity.requiresCompactTextReveal)
    }

    @MainActor
    func testManagedNexCLIWorkspacePersistsAcrossBuildsAndLaunches() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-cli-workspace-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = NexCLIWorkspaceManager(fileManager: .default, vaultURLProvider: { root })

        let first = try manager.prepareForNexusLaunch()
        XCTAssertEqual(first.url.lastPathComponent, "Folder 1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(try manager.currentWorkspace(), first)

        let completed = try manager.completeBuild(title: "Snake Game", filesChanged: ["index.html", "game.js"])
        XCTAssertEqual(completed, first)
        XCTAssertEqual(try manager.currentWorkspace(), first)

        let second = try manager.prepareForNexusLaunch()
        XCTAssertEqual(second, first)
    }

    func testSystemPromptUsesRegisteredRoutingToolNames() {
        let prompt = NexusResponseInstructions.completeSystemPrompt
        for tool in [
            "memory_search",
            "memory_get",
            "conversation_recall",
            "memory_propose",
            "memory_forget",
            "web_search",
            "nex_cli_task",
            "nex_cli_set_workspace",
            "youtube_play_current",
            "youtube_search",
            "youtube_play",
            "youtube_fullscreen"
        ] {
            XCTAssertTrue(prompt.contains(tool), "Missing \(tool)")
        }
        XCTAssertTrue(prompt.contains("Do not call either directly"))
        XCTAssertTrue(prompt.contains("memory_write"))
    }

    @MainActor
    func testManagedNexCLIWorkspaceChangesOnlyWhenExplicitlySet() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexus-cli-workspace-switch-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = NexCLIWorkspaceManager(fileManager: .default, vaultURLProvider: { root })

        let initial = try manager.prepareForNexusLaunch()
        FileManager.default.createFile(atPath: initial.url.appendingPathComponent("index.html").path, contents: Data())
        XCTAssertEqual(try manager.prepareForNexusLaunch(), initial)

        let switched = try manager.setWorkspace(named: "Portfolio Dashboard")
        XCTAssertEqual(switched.displayName, "Portfolio Dashboard")
        XCTAssertEqual(try manager.currentWorkspace(), switched)
        XCTAssertNotEqual(switched.url, initial.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: initial.url.appendingPathComponent("index.html").path))
    }

    @MainActor
    func testWakePhraseListenerMatchesOnlyIntentionalMultiWordPhrases() {
        XCTAssertEqual(WakePhraseListener.match(in: "Hey, next!"), .heyNext)
        XCTAssertEqual(WakePhraseListener.match(in: "Wake up next"), .wakeUpNext)
        XCTAssertNil(WakePhraseListener.match(in: "What should I do next?"))
        XCTAssertNil(WakePhraseListener.match(in: "Nex, open the overlay"))
    }

    @MainActor
    func testAPIProviderKeepsKeyOutOfDefaultsAndBuildsGeminiConfiguration() throws {
        let suite = "nexus-api-provider-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = NexusMemorySecretStore()
        let store = NexusAPIProviderStore(defaults: defaults, secretStore: secrets, managedSecretStore: secrets)
        store.kind = .gemini
        store.baseURL = NexusAPIProviderKind.gemini.defaultBaseURL
        store.model = "gemini-2.5-flash"
        store.apiKeyInput = "test-key"
        store.enabled = true

        try store.save()
        let configuration = try store.configuration()

        XCTAssertEqual(configuration.kind, .gemini)
        XCTAssertEqual(configuration.model, "gemini-2.5-flash")
        XCTAssertEqual(configuration.apiKey, "test-key")
        XCTAssertFalse(String(describing: defaults.dictionary(forKey: "nexus.api-provider.settings.v1")).contains("test-key"))
    }

    @MainActor
    func testSwitchingToGeminiReplacesTheOpenAIDefaultEndpoint() {
        let suite = "nexus-api-provider-kind-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = NexusMemorySecretStore()
        let store = NexusAPIProviderStore(defaults: defaults, secretStore: secrets, managedSecretStore: secrets)

        store.baseURL = NexusAPIProviderKind.openAICompatible.defaultBaseURL
        store.selectKind(.gemini, replacing: .openAICompatible)

        XCTAssertEqual(store.baseURL, NexusAPIProviderKind.gemini.defaultBaseURL)
        XCTAssertEqual(store.model, "gemini-2.5-flash")
    }

    func testManagedCloudInferenceUsesInceptionThenNVIDIAWithKeysOutsideDefaults() throws {
        let secrets = NexusMemorySecretStore()
        let store = NexusManagedCloudInferenceStore(secrets: secrets)
        try secrets.set(Data("inception-key".utf8), for: NexusManagedCloudProvider.inception.keyAccount)
        try secrets.set(Data("nvidia-key".utf8), for: NexusManagedCloudProvider.nvidiaNIM.keyAccount)

        let attempts = try store.configurations()
        XCTAssertEqual(attempts.map(\.provider), [.inception, .nvidiaNIM])
        XCTAssertEqual(attempts.map { $0.configuration.model }, ["mercury-2", "openai/gpt-oss-120b"])
        XCTAssertEqual(attempts.map { $0.configuration.baseURL.absoluteString }, [
            "https://api.inceptionlabs.ai/v1",
            "https://integrate.api.nvidia.com/v1"
        ])
        XCTAssertEqual(attempts[0].configuration.apiKey, "inception-key")
        XCTAssertEqual(attempts[1].configuration.apiKey, "nvidia-key")
    }

    @MainActor
    func testNVIDIAPresetUsesDedicatedKeychainAccountAndVerifiedDefaults() throws {
        let suite = "nexus-nvidia-provider-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let standardSecrets = NexusMemorySecretStore()
        let managedSecrets = NexusMemorySecretStore()
        let store = NexusAPIProviderStore(
            defaults: defaults,
            secretStore: standardSecrets,
            managedSecretStore: managedSecrets
        )
        store.selectKind(.nvidiaNIM, replacing: .gemini)
        store.apiKeyInput = "nvidia-test-key"
        store.enabled = true

        try store.save()
        let configuration = try store.configuration()

        XCTAssertEqual(configuration.kind, .nvidiaNIM)
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://integrate.api.nvidia.com/v1")
        XCTAssertEqual(configuration.model, "openai/gpt-oss-120b")
        XCTAssertEqual(try managedSecrets.data(for: "nvidia.nim.v1"), Data("nvidia-test-key".utf8))
        XCTAssertNil(try standardSecrets.data(for: "nvidia.nim.v1"))
    }

    @MainActor
    func testSelectingPresetWithSavedCredentialImmediatelyActivatesIt() throws {
        let suite = "nexus-api-provider-autoselect-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let normalSecrets = NexusMemorySecretStore()
        let nvidiaSecrets = NexusMemorySecretStore()
        try nvidiaSecrets.set(Data("saved-nvidia-key".utf8), for: "nvidia.nim.v1")
        let store = NexusAPIProviderStore(
            defaults: defaults,
            secretStore: normalSecrets,
            managedSecretStore: nvidiaSecrets
        )

        store.selectKind(.nvidiaNIM, replacing: .gemini)

        XCTAssertTrue(store.savedKey)
        XCTAssertTrue(store.enabled)
        XCTAssertEqual(try store.configuration().kind, .nvidiaNIM)
    }

    func testRequestedModelAndConnectCameraSizing() {
        XCTAssertEqual(Nexus3DLayout.computerCameraDistance, 2.55)
        XCTAssertEqual(Nexus3DLayout.globeCameraDistance, 2.70)
        XCTAssertEqual(Nexus3DLayout.connectDeviceCameraDistance, 4.15)
        XCTAssertLessThan(Nexus3DLayout.computerCameraDistance, 2.72)
        XCTAssertLessThan(Nexus3DLayout.globeCameraDistance, 2.88)
        XCTAssertGreaterThan(Nexus3DLayout.connectDeviceCameraDistance, 3.70)
    }

    func testNexCLIHostLaunchAgentContainsNoWorkerCredential() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = NexCLIHostManager(
            homeDirectory: home,
            executableURL: URL(fileURLWithPath: "/Applications/Nexus.app/Contents/MacOS/nexus")
        )

        let data = manager.launchAgentPropertyList()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])

        XCTAssertEqual(plist["Label"] as? String, NexCLIHostManager.label)
        XCTAssertEqual(arguments, ["/Applications/Nexus.app/Contents/MacOS/nexus", NexCLIHostProcess.argument])
        XCTAssertEqual((plist["EnvironmentVariables"] as? [String: String])?[NexCLIHostProcess.environmentKey], "1")
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("OPENCODE_SERVER_PASSWORD"))
    }
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
        XCTAssertEqual(listening.height, physicalNotch.height)
        XCTAssertEqual(regions.leftWing.width, 62)
        XCTAssertEqual(regions.notchGap.width, physicalNotch.width)
        XCTAssertEqual(regions.rightWing.width, 62)
        XCTAssertEqual(regions.leftWing.maxX, regions.notchGap.minX)
        XCTAssertEqual(regions.notchGap.maxX, regions.rightWing.minX)
        XCTAssertEqual(regions.rightWing.maxX, listening.width)
    }

    func testCompactTextOnlyGetsAShallowRevealBelowTheMenuBar() {
        let physicalNotch = CGSize(width: 190, height: 32)
        XCTAssertEqual(NotchGeometry.compactHeight(for: physicalNotch), 32)
        XCTAssertEqual(NotchGeometry.compactTextHeight(for: physicalNotch), 56)
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

    func testStreamedThinkingSentenceUsesCompactThinkingUntilAnswerBegins() {
        var state = NotchInteractionState()
        state.beginDictation()
        state.updateTranscript("Work out 17 times 24")
        state.finishDictation()

        var chunker = SpeechSentenceChunker()
        XCTAssertEqual(chunker.append("I will multiply 17 by 24"), [])
        XCTAssertEqual(chunker.append(" first."), ["I will multiply 17 by 24 first."])

        state.updateThinkingSentence("I will multiply 17 by 24 first.")
        state.beginThinking()
        XCTAssertEqual(state.presentation, .thinking)
        XCTAssertEqual(state.thinkingSentence, "I will multiply 17 by 24 first")

        state.receivePartialAnswer("17 times 24 is 408.")
        XCTAssertEqual(state.presentation, .overlay)
        XCTAssertNil(state.thinkingSentence)
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

    func testDefaultModelInstructionsDescribeDirectAndToolRoutedResponses() {
        let instructions = NexusResponseInstructions.conciseSystemPrompt

        XCTAssertTrue(instructions.contains("Vishay Agarwal’s personal AI assistant"))
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("address him as Sir"))
        XCTAssertTrue(instructions.contains("memory_search"))
        XCTAssertTrue(instructions.contains("web_search"))
        XCTAssertTrue(instructions.contains("nex_cli_task"))
        XCTAssertTrue(instructions.contains("nex_cli_set_workspace"))
        XCTAssertTrue(instructions.contains("Never invent"))
        XCTAssertLessThan(instructions.split(whereSeparator: \.isWhitespace).count, 600)
    }

    func testStatusFallbackHasNoKeywordRoutingAndSanitizesModelSubjects() {
        XCTAssertEqual(NexusStatusLineGenerator.fallback, "Working on that now, Sir…")
        XCTAssertEqual(
            NexusStatusLineGenerator.sanitize(#"{"status":"swift_release_changes"}"#),
            "Reviewing swift release changes…"
        )
        XCTAssertEqual(NexusStatusLineGenerator.sanitize("Exploring the Atlas project"), "Exploring the Atlas project…")
        XCTAssertNil(NexusStatusLineGenerator.sanitize("natural status describing work"))
    }

    func testToolPlanAcceptsModelsThatOmitPresentationStatus() {
        let tools = [NexRegisteredTool(
            name: "web_search",
            description: "Search the live web.",
            statusLabel: "Searching the web…",
            completionLabel: "Used search",
            spokenStatus: "Searching the web.",
            iconSystemName: "globe",
            permission: .network,
            schema: .init(fields: ["query": .init(.string, required: true)]),
            handler: { _, _ in .null }
        )]
        let plan = NexPrimaryToolPlanner.parse(
            #"{"actions":[{"tool":"web_search","arguments":{"query":"latest Swift programming language release changes"}}],"memory_write":null}"#,
            registeredTools: tools
        )
        XCTAssertEqual(plan.actions.count, 1)
        XCTAssertEqual(plan.actions.first?.tool, "web_search")
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

    func testWebSpeechDropsCitationLabelsAndSourceSectionsEntirely() {
        var filter = StreamingSpeechMarkdownFilter(speakLinkLabels: false)
        var spoken = filter.append("Swift 6.3 adds Android support. [Apple")
        spoken += filter.append("](https://apple.com/swift) **Sources:** [Macworld](https://example.com)")
        spoken += filter.finish()

        XCTAssertTrue(spoken.contains("Swift 6.3 adds Android support"))
        XCTAssertFalse(spoken.contains("Apple"))
        XCTAssertFalse(spoken.contains("Macworld"))
        XCTAssertFalse(spoken.contains("https"))
        XCTAssertEqual(
            SpeechSanitizer.forSpeech("Sources: Apple and Macworld", suppressCitations: true),
            ""
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

    func testCodexProgressMapsCommentaryCommandsPatchesAndGit() throws {
        let commentary = #"{"type":"event_msg","payload":{"type":"agent_message","phase":"commentary","message":"I’m tracing the streaming path."}}"#
        let git = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"git status --short\",\"workdir\":\"/repo\"});"}}"#
        let patch = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: /repo/nexus/ContentView.swift\n*** End Patch"}}"#
        let complete = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#

        XCTAssertEqual(CodexProgressParser.parse(line: commentary), .init(
            kind: .thinking,
            detail: "I’m tracing the streaming path.",
            phase: .progress
        ))
        XCTAssertEqual(CodexProgressParser.parse(line: git), .init(
            kind: .git,
            detail: "git status --short",
            phase: .progress
        ))
        XCTAssertEqual(CodexProgressParser.parse(line: patch), .init(
            kind: .writing,
            detail: "Updating /repo/nexus/ContentView.swift",
            phase: .progress
        ))
        XCTAssertEqual(CodexProgressParser.parse(line: complete)?.phase, .completed)
    }

    func testCodexActivityPreservesTheExactLiveLineForTheNotch() {
        let progress = CodexProgressUpdate(
            kind: .terminal,
            detail: "xcodebuild -project nexus/nexus.xcodeproj test",
            phase: .progress
        )
        let activity = ToolActivity.codex(progress)

        XCTAssertEqual(activity.toolName, "Codex")
        XCTAssertEqual(activity.status, "Running command")
        XCTAssertEqual(activity.detail, "xcodebuild -project nexus/nexus.xcodeproj test")
        XCTAssertEqual(activity.phase, .progress)
    }

    func testCodexProgressMapsFileReadsAndImageViewingToDistinctActivities() {
        let read = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"sed -n '1,160p' nexus/ContentView.swift\",\"workdir\":\"/repo\"});"}}"#
        let image = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"view_image","input":"{\"path\":\"/tmp/reference.png\"}"}}"#

        XCTAssertEqual(CodexProgressParser.parse(line: read)?.kind, .reading)
        XCTAssertEqual(CodexProgressParser.parse(line: image)?.kind, .image)
    }

    func testCodexUsageLimitUsesThePrimaryWeeklyLimitAndResetDate() {
        let tokenCount = #"{"type":"event_msg","payload":{"type":"token_count","info":{"rate_limits":{"primary":{"used_percent":32.0,"window_minutes":10080,"resets_at":1785000000}}}}}"#

        let usage = CodexUsageLimit.parse(line: tokenCount)
        XCTAssertEqual(usage?.usedPercent, 32)
        XCTAssertEqual(usage?.resetsAt.timeIntervalSince1970, 1_785_000_000)
        XCTAssertTrue(usage?.compactLabel.contains("32% ·") == true)
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

    func testBundledPetsAndDownloadedLinuxGIFRemainSeparateRenderPaths() throws {
        let atlasPets = NexusPetCatalog.all.filter {
            if case .atlas = $0.artwork { return true }
            return false
        }
        XCTAssertEqual(atlasPets.map(\.id), [
            "tiko", "kabi", "macintosh", "lil-finder", "crt-pal", "pan-chan-laptop"
        ])

        for pet in atlasPets {
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

        let linux = try XCTUnwrap(NexusPetCatalog.all.first { $0.id == "linux" })
        guard case .animatedGIF(let url) = linux.artwork else {
            return XCTFail("Linux should keep its user-supplied animated GIF artwork")
        }
        XCTAssertEqual(url.lastPathComponent, "icons8-linux.gif")
    }

    func testModelBrandArtworkClassifiesKnownFamiliesAndUsesLinuxFallback() {
        func model(_ identifier: String) -> LocalModel {
            LocalModel(customIdentifier: identifier, backend: .lmStudio)
        }

        XCTAssertEqual(ModelBrandArtwork.assetURL(for: model("Qwen3-8B")).lastPathComponent, "qwen-color.svg")
        XCTAssertEqual(ModelBrandArtwork.assetURL(for: model("Mistral-Small")).lastPathComponent, "mistral-color.svg")
        XCTAssertEqual(ModelBrandArtwork.assetURL(for: model("DeepSeek-R1")).lastPathComponent, "icons8-deepseek-94.png")
        XCTAssertEqual(ModelBrandArtwork.assetURL(for: model("gemma-3-12b")).lastPathComponent, "gemma-color.svg")
        XCTAssertEqual(ModelBrandArtwork.assetURL(for: model("openai/gpt-oss-20b")).lastPathComponent, "openai.webp")
        XCTAssertEqual(ModelBrandArtwork.assetURL(for: LocalModel(customIdentifier: "gpt-oss:latest", backend: .ollama)).lastPathComponent, "openai.webp")
        XCTAssertEqual(ModelBrandArtwork.assetURL(for: LocalModel(customIdentifier: "llama3.2:3b", backend: .ollama)).lastPathComponent, "ollama-dark.svg")
        XCTAssertEqual(ModelBrandArtwork.assetURL(for: model("phi-4")).lastPathComponent, "icons8-linux-48.png")
    }

    func testProviderIconResolverPrefersProviderMetadataAndCoversAPIModels() throws {
        let openAIModel = LocalModel(
            name: "Reasoning model",
            identifier: "custom-id",
            family: "OpenAI",
            backend: .lmStudio,
            minimumRAMGB: 8
        )
        XCTAssertEqual(ModelProviderResolver.identity(for: openAIModel), .openAI)
        XCTAssertEqual(
            ModelProviderResolver.identity(
                for: .openAICompatible,
                modelID: "custom-deployment",
                baseURL: "https://api.openai.com/v1"
            ),
            .openAI
        )
        XCTAssertEqual(
            ModelProviderResolver.identity(
                for: .gemini,
                modelID: "gemini-2.5-flash",
                baseURL: NexusAPIProviderKind.gemini.defaultBaseURL
            ),
            .gemini
        )

        let data = try XCTUnwrap(ModelBrandArtwork.embeddedChatGPTPNGData)
        let image = try XCTUnwrap(NSImage(data: data))
        XCTAssertEqual(data.count, 1_696)
        XCTAssertEqual(image.size, CGSize(width: 48, height: 48))
        XCTAssertEqual(ModelBrandArtwork.fallbackSystemName, "cpu")

        let geminiIcon = try XCTUnwrap(ModelBrandArtwork.icon(for: .gemini, size: 14))
        XCTAssertEqual(geminiIcon.size, NSSize(width: 14, height: 14))
        let representation = try XCTUnwrap(geminiIcon.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(representation.pixelsWide, 42)
        XCTAssertEqual(representation.pixelsHigh, 42)
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

@MainActor
private final class YouTubeToolTestTabs: BrowserTabProviding {
    let active: BrowserTab

    init(active: BrowserTab) {
        self.active = active
    }

    func listTabs() async throws -> [BrowserTab] { [active] }
    func activate(tabID: String) async throws {}
    func activeTab() async throws -> BrowserTab? { active }
}
