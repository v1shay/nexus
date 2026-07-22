import SwiftUI
import AppKit
import Combine
import Darwin

@main
struct NexusApp: App {
    @NSApplicationDelegateAdaptor(NexusAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Nexus owns an AppKit panel rather than an ordinary app window.
        // This prevents a normal, draggable SwiftUI window ever appearing.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class NexusAppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchController?
    private var connectHost: NexusConnectHostDaemon?
    private var nexCLIHost: NexCLIHostDaemon?
    private var launchTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests inject XCTest into the app process. They construct every
        // controller explicitly and must not initialize the real Keychain,
        // global hotkey, notch panel, or LaunchAgent as a side effect.
        if NSClassFromString("XCTestCase") != nil { return }
        if NexusConnectHostProcess.isCurrentProcess {
            NSApp.setActivationPolicy(.prohibited)
            let host = NexusConnectHostDaemon()
            connectHost = host
            launchTask = Task { @MainActor in await host.start() }
            return
        }
        if NexCLIHostProcess.isCurrentProcess {
            NSApp.setActivationPolicy(.prohibited)
            let host = NexCLIHostDaemon()
            nexCLIHost = host
            launchTask = Task { @MainActor in await host.start() }
            return
        }
        NSApp.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--nexus-ui-testing") {
            let notch = NotchController()
            self.notch = notch
            notch.install(startServices: false)
            return
        }
        launchTask = Task { @MainActor [weak self] in
            await Self.retireOlderInstances()
            guard !Task.isCancelled else { return }
            _ = try? NexCLIWorkspaceManager.shared.prepareForNexusLaunch()
            try? NexCLIHostManager.shared.installAndStart()
            let notch = NotchController()
            self?.notch = notch
            notch.install()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchTask?.cancel()
        notch?.shutdown()
        connectHost?.stop()
        nexCLIHost?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        notch?.confirmDiscardBeforeQuit() == false ? .terminateCancel : .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notch?.openModelAggregator()
        return true
    }

    /// Xcode can launch a new debug build while the previous accessory app is
    /// still alive. Retire the older process before creating any panel so two
    /// independent notch windows can never be visible together.
    private static func retireOlderInstances() async {
        // XCTest injects into the app executable. Killing another injected test
        // host here can terminate a parallel test run before XCTest boots.
        guard NSClassFromString("XCTestCase") == nil,
              !CommandLine.arguments.contains(where: { $0.localizedCaseInsensitiveContains("xctest") }) else {
            return
        }
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let hostPID = NexusConnectHostManager().currentStatus()?.processID
        let olderInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != currentPID && $0.processIdentifier != hostPID }

        guard !olderInstances.isEmpty else { return }
        NSLog(
            "Nexus %d is retiring older process(es): %@",
            currentPID,
            olderInstances.map { String($0.processIdentifier) }.joined(separator: ", ")
        )
        let olderDebugServers = olderInstances.compactMap {
            debugServerParent(for: $0.processIdentifier)
        }
        olderDebugServers.forEach {
            _ = Darwin.kill($0, SIGTERM)
        }
        olderInstances.forEach {
            _ = Darwin.kill($0.processIdentifier, SIGTERM)
        }
        for _ in 0..<12 where olderInstances.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        olderInstances.filter { !$0.isTerminated }.forEach {
            _ = Darwin.kill($0.processIdentifier, SIGKILL)
        }
    }

    /// LLDB holds signals sent to a traced app. Retiring that app's dedicated
    /// debugserver first lets a new Xcode run replace the old notch cleanly.
    private static func debugServerParent(for processID: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, Int32(infoSize)) == infoSize else {
            return nil
        }
        let parentID = pid_t(info.pbi_ppid)
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(parentID, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { return nil }
        return String(cString: pathBuffer).hasSuffix("/debugserver") ? parentID : nil
    }
}

@MainActor
final class NotchController: ObservableObject {
    @Published private var interaction = NotchInteractionState()
    @Published private(set) var currentSize = CGSize(width: 190, height: 32)
    @Published private(set) var isVoiceMuted = false
    @Published private(set) var selectedPet = NexusPetCatalog.pet(
        withID: UserDefaults.standard.string(forKey: "nexus.selectedPetID")
    )
    @Published private(set) var codexSessions: [CodexSessionProgress] = []
    @Published private(set) var codexUsageLimit: CodexUsageLimit?
    @Published private(set) var isShowingThinkingModelMark = false

    var presentation: NotchPresentation { interaction.presentation }
    var isExpanded: Bool { interaction.presentation == .overlay }
    var isListening: Bool { interaction.presentation == .dictating }
    var isThinking: Bool { interaction.presentation == .thinking }
    var isUsingTool: Bool { interaction.presentation == .tool }
    var toolActivity: ToolActivity? { interaction.toolActivity }
    var toolReceipt: ToolActivity? { interaction.toolReceipt }
    var transcript: String { interaction.transcript }
    var answer: String { interaction.answer }
    var workingStatus: String? { interaction.workingStatus }
    var thinkingSentence: String? { interaction.thinkingSentence }
    var activeModel: LocalModel? { modelDownloadViewModel.activeModel }
    var activeModelSupportsThinking: Bool { modelDownloadViewModel.activeModelSupportsThinking }
    var thinkingModeEnabled: Bool { modelDownloadViewModel.thinkingModeEnabled }
    var isShowingMusic: Bool { interaction.presentation == .idle && music.isPlaying }
    var musicTrack: NexusAudioReactiveMusic.SpotifyTrack? { music.track }
    var musicBrowserSource: NexusAudioReactiveMusic.BrowserSource? { music.track == nil ? music.browserSource : nil }
    var musicArtwork: NSImage? { music.activeArtwork }
    var musicPalette: NexusAudioReactiveMusic.Palette { music.activePalette }
    var musicEnergy: CGFloat { music.energy }
    @Published private(set) var mediaOverlayTab: MediaTab?
    @Published private(set) var isMediaFullscreen = false
    @Published private(set) var mediaPlaybackWidth: CGFloat?

    var currentMediaPlaybackWidth: CGFloat { mediaPlaybackWidth ?? currentSize.width }

    /// The media mark is an explicit source control. Hovering the surrounding
    /// compact notch does not consume it.
    func activateCurrentMediaSource() {
        Task { @MainActor [weak self] in
            await self?.music.activateCurrentMediaSource()
        }
    }

    /// Media cards use click-to-open so the source mark can always win the
    /// interaction. YouTube carries its active tab into the expanded panel;
    /// other platforms retain the normal transcript overlay.
    func openMediaOverlay() {
        guard interaction.presentation == .idle, let screen else { return }
        // A pointer can enter the newly enlarged fullscreen panel immediately
        // after the player opens. Never let that incidental interaction turn a
        // live fullscreen video back into the ordinary media card.
        guard !(mediaOverlayTab != nil && isMediaFullscreen) else { return }
        isMediaFullscreen = false
        mediaPlaybackWidth = nil
        mediaOverlayTab = music.activeYouTubeTab
        interaction.showMediaOverlay()
        resize(to: mediaOverlayTab == nil ? expandedSize(for: screen) : mediaPlaybackSize(for: screen), animated: true)
    }

    /// The player stays 16:9 but can be widened or narrowed for the current
    /// media session. This intentionally does not persist between videos.
    func resizeMediaPlayback(startingAt startWidth: CGFloat, translation: CGFloat) {
        guard mediaOverlayTab != nil, !isMediaFullscreen, let screen else { return }
        let limits = mediaPlaybackWidthLimits(for: screen)
        mediaPlaybackWidth = min(max(startWidth + translation, limits.min), limits.max)
        resize(to: mediaPlaybackSize(for: screen), animated: false)
    }

    /// A validated YouTube tool request lands here after it has selected an
    /// existing Chrome video or a stable video ID. `tab == nil` means only
    /// expand the already-playing surface.
    private func requestYouTubePlayback(_ tab: MediaTab?, fullscreen: Bool) -> Bool {
        guard screen != nil else { return false }
        if let tab, mediaOverlayTab?.tab.id != tab.tab.id {
            mediaPlaybackWidth = nil
            mediaOverlayTab = tab
        }
        guard mediaOverlayTab != nil else { return false }
        isMediaFullscreen = fullscreen || isMediaFullscreen
        return true
    }

    private func presentRequestedYouTubePlayback() -> Bool {
        guard let tab = pendingYouTubePlayback ?? mediaOverlayTab, let screen else { return false }
        mediaOverlayTab = tab
        isMediaFullscreen = pendingYouTubeFullscreen || isMediaFullscreen
        pendingYouTubePlayback = nil
        pendingYouTubeFullscreen = false
        interaction.showMediaOverlay()
        resize(to: currentMediaOverlaySize(for: screen), animated: true)
        return true
    }

    private var panel: NexusNotchPanel?
    private var screen: NSScreen?
    private var closeTask: Task<Void, Never>?
    private var commandHoldMonitor: NexusCommandHoldMonitor?
    private var pointerMonitor: PointerProximityMonitor?
    private var modelPanel: NSPanel?
    private var savedChatsPanel: NSPanel?
    private let speechTranscriber = SpeechTranscriber()
    private let wakePhraseListener = WakePhraseListener()
    private let connectController: NexusConnectController
    private let modelDownloadViewModel: ModelDownloadViewModel
    private var automaticRevealIsWaitingForNotchVisit = false
    private let responseSpeaker = ResponseSpeaker()
    private var responseTask: Task<Void, Never>?
    private var memoryWriterTask: Task<Void, Never>?
    private var responseGeneration = UUID()
    private var responseSpeechCursor = StreamedSpeechCursor()
    private var thinkingSentenceChunker = SpeechSentenceChunker()
    private var thinkingModelMarkTask: Task<Void, Never>?
    private let conversationSession: NexConversationSession
    let memory: NexMemoryController
    let settings: NexusAppSettings
    private lazy var webSearch = NexWebSearchController(registry: memory.registry)
    private lazy var youtubeTools = NexYouTubeToolController(registry: memory.registry) { [weak self] tab, fullscreen in
        self?.requestYouTubePlayback(tab, fullscreen: fullscreen) ?? false
    }
    private lazy var toolOrchestrator = NexToolOrchestrator(registry: memory.registry)
    private var memoryObservation: AnyCancellable?
    private var toolEventTask: Task<Void, Never>?
    private var codexProgressMonitor: CodexProgressMonitor?
    private var codexProgressDismissTask: Task<Void, Never>?
    private var selectedCodexSessionID: String?
    private var responseIsStreaming = false
    private var hoverSession = NotchHoverSession()
    private var suppressAutomaticResponseReveal = false
    private let music = NexusAudioReactiveMusic()
    private var musicObservation: AnyCancellable?
    private var wasShowingMusic = false
    private var pendingYouTubePlayback: MediaTab?
    private var pendingYouTubeFullscreen = false

    init(connectController: NexusConnectController? = nil) {
        let resolvedConnectController = connectController ?? .shared
        let conversationSession = NexConversationSession()
        self.connectController = resolvedConnectController
        self.conversationSession = conversationSession
        settings = NexusAppSettings()
        modelDownloadViewModel = ModelDownloadViewModel(connect: resolvedConnectController)
        memory = NexMemoryController(conversation: conversationSession)
        memoryObservation = memory.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        musicObservation = music.objectWillChange.sink { [weak self] _ in
            // The energy changes animate the orb; only playback transitions
            // resize the panel so the 30fps meter never causes layout churn.
            Task { @MainActor in self?.refreshMusicPresentation() }
        }
    }

    static let preview: NotchController = {
        let controller = NotchController()
        controller.interaction.beginDictation()
        return controller
    }()

    func install(startServices: Bool = true) {
        guard panel == nil else { return }
        if startServices { connectController.start() }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        self.screen = screen
        currentSize = closedSize(for: screen)

        let panel = NexusNotchPanel(
            contentRect: frame(for: currentSize, on: screen),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: ContentView().environmentObject(self))
        // The NSPanel is the sole owner of notch geometry. Without this,
        // NSHostingView advertises the transcript's ideal size and AppKit can
        // grow the window to nearly the entire screen for a long sentence.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        // A non-activating panel is deliberately unusual in macOS: SwiftUI
        // controls backed by transparent Color views can miss clicks before
        // becoming first responder. Route media-card clicks at the panel so
        // the physical-notch area is consistently actionable.
        panel.onMouseDown = { [weak self] location in
            guard let self, self.isShowingMusic else { return false }
            switch NotchGeometry.mediaClickTarget(for: location) {
            case .source:
                self.activateCurrentMediaSource()
            case .overlay:
                self.openMediaOverlay()
            }
            return true
        }
        self.panel = panel
        if startServices {
            startToolEventListener()
            startCodexProgressMonitor()
            memory.start()
            Task { [weak self] in
                guard let self else { return }
                await memory.prepareToolRegistry()
                try? await webSearch.registerIfNeeded()
                try? await youtubeTools.registerIfNeeded()
            }
            installCommandHoldMonitor()
            installPointerMonitor()
            armWakePhraseListener()
            music.start()
        }
        panel.orderFrontRegardless()
        NSLog("Nexus installed its panel, pointer monitor, and global hotkey")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Watches a generous virtual region over the physical notch.  This means
    /// the cursor is considered inside Nexus even in the camera cutout itself,
    /// where a transparent AppKit view cannot reliably receive hover events.
    private func installPointerMonitor() {
        pointerMonitor = PointerProximityMonitor { [weak self] location in
            Task { @MainActor in self?.updatePointerLocation(location) }
        }
    }

    private func updatePointerLocation(_ location: NSPoint) {
        guard let screen else { return }
        let closed = closedSize(for: screen)
        let isOverNotchZone = abs(location.x - screen.frame.midX) <= max(150, closed.width / 2 + 72)
            && location.y >= screen.frame.maxY - 66
        let isOverPanel = panel?.frame.contains(location) ?? false
        let isInsideNexus = isOverNotchZone || isOverPanel
        guard let didEnter = hoverSession.update(isInside: isInsideNexus) else { return }
        NSLog("Nexus pointer session %@", didEnter ? "entered" : "exited")
        updateHover(didEnter)
    }

    /// Polling the combined session modifier state keeps a modifier-only
    /// gesture global without requiring a focused window or a Carbon key chord.
    private func installCommandHoldMonitor() {
        let monitor = NexusCommandHoldMonitor(
            onPress: { [weak self] in
                Task { @MainActor in await self?.startGlobalDictation() }
            },
            onRelease: { [weak self] in
                Task { @MainActor in await self?.finishGlobalDictation() }
            },
            onDoubleTap: { [weak self] in
                Task { @MainActor in self?.quickDismiss() }
            }
        )
        commandHoldMonitor = monitor
        monitor.install()
    }

    private func startGlobalDictation(automaticallySubmitAfterSilence: Bool = false) async {
        wakePhraseListener.stop()
        closeTask?.cancel()
        // Foreground speech always wins model capacity. If a prior background
        // classification is cancelled, the next pass still sees recent turns.
        memoryWriterTask?.cancel()
        if responseIsStreaming, !responseSpeechCursor.text.isEmpty {
            await conversationSession.appendAssistant(responseSpeechCursor.text, interrupted: true)
            await memory.conversationDidChange()
        }
        responseIsStreaming = false
        responseTask?.cancel()
        responseGeneration = UUID()
        responseSpeechCursor = StreamedSpeechCursor()
        thinkingSentenceChunker = SpeechSentenceChunker()
        responseSpeaker.stop()
        hideThinkingModelMark()
        suppressAutomaticResponseReveal = false
        interaction.beginDictation()
        if let screen {
            resize(to: listeningSize(for: screen), animated: true)
        }
        speechTranscriber.start(
            engine: settings.speechEngine,
            automaticallySubmitAfterSilence: automaticallySubmitAfterSilence ? 0.7 : nil,
            onAutomaticSubmit: { [weak self] in
                Task { @MainActor in await self?.finishGlobalDictation() }
            }
        ) { [weak self] text in
            Task { @MainActor in self?.interaction.updateTranscript(text) }
        }
    }

    private func finishGlobalDictation() async {
        // FluidAudio's current Parakeet API is batch transcription. Move out
        // of the listening screen while the local model finalizes audio so it
        // never looks as though the response model is buffering.
        if settings.speechEngine == .parakeetLocal {
            interaction.finishDictation()
            interaction.acknowledge("Transcribing locally…")
            if let screen { resize(to: expandedSize(for: screen), animated: true) }
        }
        if let endpointTranscript = await speechTranscriber.stopAndTranscribe() {
            interaction.updateTranscript(endpointTranscript)
        }
        interaction.finishDictation()
        let finalizedPrompt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalizedPrompt.isEmpty, await conversationSession.appendUser(finalizedPrompt) != nil {
            await memory.conversationDidChange()
        }
        automaticRevealIsWaitingForNotchVisit = true
        if let screen {
            resize(to: expandedSize(for: screen), animated: true)
        }
        startResponseIfPossible()
    }

    private func armWakePhraseListener() {
        guard !isListening, !responseIsStreaming else { return }
        wakePhraseListener.start { [weak self] phrase in
            guard let self else { return }
            NSLog("Nex heard wake phrase: %@", phrase.rawValue)
            Task { @MainActor in await self.startGlobalDictation(automaticallySubmitAfterSilence: true) }
        }
    }

    private func startResponseIfPossible() {
        let prompt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, modelDownloadViewModel.activeModel != nil else {
            armWakePhraseListener()
            return
        }

        // Media control is the single intentionally deterministic voice path:
        // while a Nex YouTube player exists, short fullscreen commands should
        // feel like player controls, not a request that waits on inference.
        if mediaOverlayTab != nil, NexMediaVoiceCommand.requestsFullscreen(prompt) {
            presentFullscreenYouTubeImmediately()
            return
        }

        responseTask?.cancel()
        let generation = UUID()
        responseGeneration = generation
        responseSpeechCursor = StreamedSpeechCursor()
        thinkingSentenceChunker = SpeechSentenceChunker()
        // This immediate presentation classifier is deliberately independent
        // from tool routing. It gives the user a useful line without delaying
        // generation; NexPrimaryToolPlanner remains the only authority that
        // decides whether a tool actually runs.
        let immediateStatus = settings.statusMode == .deterministic
            ? NexusStatusLineGenerator.status(for: prompt)
            : NexusStatusLineGenerator.fallback
        interaction.acknowledge(immediateStatus)
        if let screen { resize(to: expandedSize(for: screen), animated: true) }
        responseSpeaker.speakImmediately(immediateStatus)
        responseTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, responseGeneration == generation else { return }
            responseSpeaker.beginStreaming()
            responseIsStreaming = true
            do {
                let baseMessages = await conversationSession.contextMessages()
                requestAsyncStatusIfNeeded(prompt: prompt, generation: generation)
                let presentationTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard let self, !Task.isCancelled, self.responseGeneration == generation else { return }
                    guard !self.isThinking, !self.isUsingTool else { return }
                    self.beginThinkingPresentation()
                    if let screen = self.screen { self.resize(to: self.listeningSize(for: screen), animated: true) }
                }
                defer { presentationTask.cancel() }
                let speculativeBuffer = NexSpeculativePrimaryBuffer()
                let speculativeTask = Task {
                    try await self.modelDownloadViewModel.response(
                        messages: baseMessages,
                        onThinkingDelta: { delta, _ in
                            await self.receiveThinkingDelta(delta, generation: generation)
                        }
                    ) { delta, accumulated in
                        await speculativeBuffer.append(delta: delta, accumulated: accumulated)
                    }
                }

                await memory.prepareToolRegistry()
                try? await webSearch.registerIfNeeded()
                try? await youtubeTools.registerIfNeeded()
                let definitions = await memory.registry.definitions()
                let planningMessages = NexPrimaryToolPlanner.planningMessages(
                    context: baseMessages,
                    tools: definitions
                )
                let plan = try await modelDownloadViewModel.toolPlan(
                    messages: planningMessages,
                    registeredTools: definitions
                )
                guard !Task.isCancelled, responseGeneration == generation else { return }
                NSLog(
                    "Primary model tool plan: %@",
                    plan.actions.map { "\($0.tool)" }.joined(separator: " | ")
                )
                var plannerAdvisory = plan.memoryWrite
                let toolResult: NexToolOrchestrationResult?
                // Keep the acknowledgement readable, then deliberately enter the
                // compact working state.  The primary request is already running
                // in `speculativeTask`; this only controls the presentation.  Do
                // not flush buffered answer tokens directly from the status view,
                // otherwise the pet/thinking transition is never visible.
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled, responseGeneration == generation else { return }
                if !isThinking && !isUsingTool {
                    beginThinkingPresentation()
                    if let screen { resize(to: listeningSize(for: screen), animated: true) }
                }

                if plan.actions.isEmpty {
                    // Make the compact pet-thinking animation perceptible even
                    // when the primary model has already produced speculative
                    // tokens while the acknowledgement was on screen.
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, responseGeneration == generation else { return }
                    await speculativeBuffer.activate { delta, accumulated in
                        await self.receiveResponseDelta(delta, accumulated: accumulated, generation: generation)
                    }
                    let answer = try await speculativeTask.value
                    let finalDelta = responseSpeechCursor.consume(delta: "", accumulated: answer)
                    if !finalDelta.isEmpty { responseSpeaker.append(finalDelta) }
                    toolResult = nil
                } else {
                    await speculativeBuffer.discard()
                    speculativeTask.cancel()
                    var result = NexToolOrchestrationResult(context: nil, webResponses: [], failures: [])
                    var pendingPlan = plan
                    var executedActions: [NexPrimaryToolPlan.Action] = []
                    var memoryLookupPerformed = false

                    // Tool-capable primary models may ask for one dependency at
                    // a time. Give the same model completed evidence and let it
                    // infer only the next missing action, with a small bound to
                    // prevent an unhealthy runtime from looping forever.
                    for _ in 0..<3 {
                        let actions = pendingPlan.actions.filter { !executedActions.contains($0) }
                        guard !actions.isEmpty else { break }
                        executedActions += actions
                        memoryLookupPerformed = memoryLookupPerformed || actions.contains { $0.tool == "memory_search" }
                        result = result.merging(await toolOrchestrator.execute(actions))
                        guard !Task.isCancelled, responseGeneration == generation else { return }
                        let startedPlayback = actions.contains {
                            ["youtube_play_current", "youtube_play", "youtube_fullscreen"].contains($0.tool)
                        } && mediaOverlayTab != nil
                        if startedPlayback { break }

                        let planningContext = await conversationSession.contextMessages(
                            memoryLookupPerformed: memoryLookupPerformed,
                            webContext: result.context
                        )
                        pendingPlan = try await modelDownloadViewModel.toolPlan(
                            messages: NexPrimaryToolPlanner.planningMessages(
                                context: planningContext,
                                tools: definitions
                            ),
                            registeredTools: definitions
                        )
                        if plannerAdvisory == nil { plannerAdvisory = pendingPlan.memoryWrite }
                    }
                    guard !Task.isCancelled, responseGeneration == generation else { return }
                    let requestedPlayback = executedActions.contains {
                        ["youtube_play_current", "youtube_play", "youtube_fullscreen"].contains($0.tool)
                    }
                    if requestedPlayback, presentRequestedYouTubePlayback() {
                        responseIsStreaming = false
                        responseSpeaker.finishStreaming()
                        armWakePhraseListener()
                        return
                    }
                    responseSpeaker.setWebEvidenceActive(!result.webResponses.isEmpty)
                    interaction.beginThinking()
                    if let screen { resize(to: listeningSize(for: screen), animated: true) }
                    let messages = await conversationSession.contextMessages(
                        memoryLookupPerformed: memoryLookupPerformed,
                        webContext: result.context
                    )
                    let answer = try await streamModelResponse(messages: messages, generation: generation)
                    let finalSpeechDelta = responseSpeechCursor.consume(delta: "", accumulated: answer)
                    if !finalSpeechDelta.isEmpty { responseSpeaker.append(finalSpeechDelta) }
                    toolResult = result
                }
                guard !Task.isCancelled, responseGeneration == generation else { return }
                let reveal = !suppressAutomaticResponseReveal
                let completedAnswer = toolResult?.appendingWebSources(to: responseSpeechCursor.text)
                    ?? responseSpeechCursor.text
                interaction.receiveAnswer(completedAnswer, reveal: reveal)
                let assistantTurn = await conversationSession.appendAssistant(completedAnswer)
                await memory.conversationDidChange()
                responseIsStreaming = false
                automaticRevealIsWaitingForNotchVisit = reveal
                if reveal, let screen { resize(to: expandedSize(for: screen), animated: true) }
                responseSpeaker.finishStreaming()
                armWakePhraseListener()
                if let assistantTurn {
                    scheduleAutomaticMemoryInference(
                        after: assistantTurn.id,
                        plannerAdvisory: plannerAdvisory
                    )
                }
            } catch {
                guard !Task.isCancelled, responseGeneration == generation else { return }
                responseSpeaker.stop()
                responseIsStreaming = false
                let reveal = !suppressAutomaticResponseReveal
                interaction.failResponse(
                    "Nexus couldn’t get a response. \(error.localizedDescription)",
                    reveal: reveal
                )
                automaticRevealIsWaitingForNotchVisit = reveal
                if reveal, let screen { resize(to: expandedSize(for: screen), animated: true) }
                armWakePhraseListener()
            }
        }
    }

    private func presentFullscreenYouTubeImmediately() {
        guard mediaOverlayTab != nil, let screen else {
            armWakePhraseListener()
            return
        }
        responseTask?.cancel()
        responseIsStreaming = false
        responseSpeaker.stop()
        pendingYouTubePlayback = nil
        pendingYouTubeFullscreen = false
        isMediaFullscreen = true
        interaction.showMediaOverlay()
        resize(to: screen.frame.size, animated: true)
        armWakePhraseListener()
    }

    private func requestAsyncStatusIfNeeded(prompt: String, generation: UUID) {
        guard settings.statusMode != .deterministic else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let messages = NexusStatusLineGenerator.prompt(for: prompt)
                let raw: String
                switch settings.statusMode {
                case .primaryModel:
                    raw = try await modelDownloadViewModel.response(
                        messages: messages,
                        temperature: 0.45,
                        maximumTokens: 32,
                        onDelta: { _, _ in }
                    )
                case .secondaryModel:
                    guard let model = modelDownloadViewModel.installedModels.first(where: {
                        $0.id == self.settings.secondaryStatusModelID
                    }) else { return }
                    raw = try await modelDownloadViewModel.response(
                        using: model,
                        messages: messages,
                        temperature: 0.45,
                        maximumTokens: 32,
                        onDelta: { _, _ in }
                    )
                case .deterministic:
                    return
                }
                guard responseGeneration == generation,
                      let status = NexusStatusLineGenerator.sanitize(raw) else { return }
                if presentation == .overlay {
                    interaction.acknowledge(status)
                } else if isThinking {
                    // Small models are often slower than the visual hand-off.
                    // Keep a valid late status visible in the compact notch
                    // instead of silently discarding it after 800 ms.
                    interaction.updateWorkingStatus(status)
                }
            } catch {
                // A status model is optional and never allowed to delay Nex.
            }
        }
    }

    private func scheduleAutomaticMemoryInference(
        after assistantMessageID: UUID,
        plannerAdvisory: NexPrimaryToolPlan.MemoryWrite? = nil
    ) {
        memoryWriterTask?.cancel()
        memoryWriterTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let plannerAdvisory, plannerAdvisory.operation == .forget {
                    let forgotten = try await memory.persistPlannerForget(
                        plannerAdvisory,
                        after: assistantMessageID
                    )
                    if forgotten { NSLog("Nex background memory writer applied one validated forget proposal") }
                    return
                }
                guard let request = try await memory.automaticMemoryInferenceRequest(
                    after: assistantMessageID,
                    plannerAdvisory: plannerAdvisory
                ) else { return }
                try Task.checkCancellation()
                let raw = try await modelDownloadViewModel.response(
                    messages: request.messages,
                    temperature: 0,
                    maximumTokens: 750,
                    onDelta: { _, _ in }
                )
                try Task.checkCancellation()
                let stored = try await memory.persistAutomaticMemoryInference(raw, request: request)
                if stored > 0 {
                    NSLog("Nex background memory writer stored %d validated proposal(s)", stored)
                }
            } catch is CancellationError {
                // A new dictation intentionally preempts nonessential writing.
            } catch {
                // Memory writing is best-effort and must never affect the
                // response, streaming, TTS, or the next dictation session.
                NSLog("Nex background memory writer skipped: %@", error.localizedDescription)
            }
        }
    }

    private func streamModelResponse(
        messages: [NexusChatMessage],
        generation: UUID
    ) async throws -> String {
        try await modelDownloadViewModel.response(
            messages: messages,
            onThinkingDelta: { [weak self] delta, _ in
                await self?.receiveThinkingDelta(delta, generation: generation)
            }
        ) { [weak self] delta, accumulated in
            guard let self else { return }
            await self.receiveResponseDelta(delta, accumulated: accumulated, generation: generation)
        }
    }

    private func receiveResponseDelta(_ delta: String, accumulated: String, generation: UUID) {
        guard !Task.isCancelled, responseGeneration == generation else { return }
        let speechDelta = responseSpeechCursor.consume(delta: delta, accumulated: accumulated)
        guard !responseSpeechCursor.text.isEmpty else { return }
        let reveal = !suppressAutomaticResponseReveal
        interaction.receivePartialAnswer(responseSpeechCursor.text, reveal: reveal)
        automaticRevealIsWaitingForNotchVisit = reveal
        if reveal, let screen { resize(to: expandedSize(for: screen), animated: true) }
        if !speechDelta.isEmpty { responseSpeaker.append(speechDelta) }
    }

    private func receiveThinkingDelta(_ delta: String, generation: UUID) {
        guard !Task.isCancelled,
              responseGeneration == generation,
              modelDownloadViewModel.thinkingModeEnabled,
              modelDownloadViewModel.activeModelSupportsThinking else { return }
        let sentences = thinkingSentenceChunker.append(delta)
        guard let latest = sentences.last else { return }
        interaction.updateThinkingSentence(latest)
        interaction.beginThinking()
        if let screen { resize(to: thinkingActivitySize(for: screen), animated: true) }
    }

    func toggleThinkingMode() {
        guard activeModelSupportsThinking else { return }
        modelDownloadViewModel.thinkingModeEnabled.toggle()
    }

    func toggleVoiceMute() {
        isVoiceMuted.toggle()
        responseSpeaker.setMuted(isVoiceMuted)
    }

    func cyclePet() {
        commandHoldMonitor?.cancelCurrentHold()
        let currentIndex = NexusPetCatalog.all.firstIndex(of: selectedPet) ?? 0
        selectedPet = NexusPetCatalog.all[(currentIndex + 1) % NexusPetCatalog.all.count]
        UserDefaults.standard.set(selectedPet.id, forKey: "nexus.selectedPetID")
        NSSound(named: "Tink")?.play()
    }

    func dismissOverlay() {
        // Media playback is intentionally sticky. A hover-out must not pause
        // or destroy it; the global double-Command quick-dismiss owns exit.
        guard mediaOverlayTab == nil else { return }
        if responseIsStreaming, !responseSpeechCursor.text.isEmpty {
            let interrupted = responseSpeechCursor.text
            Task {
                await conversationSession.appendAssistant(interrupted, interrupted: true)
                await memory.conversationDidChange()
            }
        }
        responseIsStreaming = false
        responseTask?.cancel()
        responseGeneration = UUID()
        responseSpeaker.stop()
        hideThinkingModelMark()
        automaticRevealIsWaitingForNotchVisit = false
        suppressAutomaticResponseReveal = false
        interaction.dismiss()
        if let screen { resize(to: idleSize(for: screen), animated: true) }
        armWakePhraseListener()
    }

    private func quickDismiss() {
        guard isListening || isExpanded || isThinking || isUsingTool else { return }
        closeTask?.cancel()
        automaticRevealIsWaitingForNotchVisit = false
        suppressAutomaticResponseReveal = true
        hideThinkingModelMark()

        if isListening {
            speechTranscriber.stop()
            interaction.dismiss()
            if let screen { resize(to: idleSize(for: screen), animated: true) }
            armWakePhraseListener()
        } else if isExpanded {
            collapse()
        } else {
            interaction.dismiss()
            if let screen { resize(to: idleSize(for: screen), animated: true) }
            armWakePhraseListener()
        }
    }

    /// Entry point for the future tool router. It is intentionally not called
    /// by ordinary prompts yet; when tool execution is added, this keeps UI and
    /// voice status synchronized through the same activity object.
    func beginToolActivity(_ activity: ToolActivity) {
        hideThinkingModelMark()
        interaction.beginToolActivity(activity)
        if let screen { resize(to: toolActivitySize(for: screen), animated: true) }
        responseSpeaker.speakImmediately(activity.spokenStatus)
    }

    func finishToolActivity() {
        interaction.beginThinking()
        if let screen { resize(to: listeningSize(for: screen), animated: true) }
    }

    /// The selected model appears for a beat at the exact compact-orb location,
    /// then contracts away as the established thinking orb takes over.  It gives
    /// each request an honest visual handoff without increasing notch height.
    private func beginThinkingPresentation() {
        interaction.beginThinking()
        guard modelDownloadViewModel.activeModel != nil else { return }
        thinkingModelMarkTask?.cancel()
        isShowingThinkingModelMark = true
        thinkingModelMarkTask = Task { [weak self] in
            // Presentation-only: inference and tool planning started before
            // this handoff task. Holding the mark never delays the model.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.isShowingThinkingModelMark = false
        }
    }

    private func hideThinkingModelMark() {
        thinkingModelMarkTask?.cancel()
        thinkingModelMarkTask = nil
        isShowingThinkingModelMark = false
    }

    func saveConversation() {
        Task { await memory.save() }
    }

    func openSavedChats() {
        if let savedChatsPanel {
            savedChatsPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Nex Memory"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: NexSavedChatsView(memory: memory) { [weak self] id in
            Task { @MainActor in await self?.resumeSavedConversation(id: id) }
        })
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        savedChatsPanel = panel
    }

    func openModelAggregator() {
        if let modelPanel {
            modelPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Nexus"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 900, height: 620)
        panel.contentView = NSHostingView(rootView: ModelAggregatorView(
            viewModel: modelDownloadViewModel,
            connect: connectController,
            memory: memory,
            settings: settings,
            cli: .shared,
            cliSettings: .shared
        )
        // The app window is a separate NSHostingView from the notch panel.
        // Keep its terminal masthead on the same selected-pet state instead
        // of allowing the @EnvironmentObject lookup to trap on tab selection.
        .environmentObject(self))
        panel.collectionBehavior.insert(.fullScreenPrimary)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrame(screen.visibleFrame, display: true)
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        modelPanel = panel
    }

    func shutdown() {
        speechTranscriber.stop()
        wakePhraseListener.stop()
        responseTask?.cancel()
        memoryWriterTask?.cancel()
        responseSpeaker.stop()
        toolEventTask?.cancel()
        codexProgressDismissTask?.cancel()
        codexProgressMonitor?.stop()
        codexProgressMonitor = nil
        music.stop()
        memory.stop()
        commandHoldMonitor = nil
        modelDownloadViewModel.shutdown()
        connectController.shutdown()
    }

    func confirmDiscardBeforeQuit() -> Bool {
        guard memory.hasValuableUnsavedConversation else { return true }
        let alert = NSAlert()
        alert.messageText = "This conversation is not saved"
        alert.informativeText = "Quit and discard it, or cancel and use Save to Obsidian first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Without Saving")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func startToolEventListener() {
        guard toolEventTask == nil else { return }
        toolEventTask = Task { [weak self] in
            guard let self else { return }
            let bus = memory.registry.events
            let stream = await bus.events()
            for await event in stream {
                guard !Task.isCancelled else { return }
                handleToolEvent(event)
            }
        }
    }

    /// Codex Desktop writes a local append-only JSONL session stream. This is
    /// intentionally a passive observer: Nexus displays progress but cannot
    /// submit, cancel, or alter a Codex task.
    private func startCodexProgressMonitor() {
        guard codexProgressMonitor == nil else { return }
        let monitor = CodexProgressMonitor()
        monitor.start(
            onUpdate: { [weak self] update, sessions in
                self?.handleCodexProgress(update, sessions: sessions)
            },
            onUsage: { [weak self] usage in
                self?.codexUsageLimit = usage
            }
        )
        codexProgressMonitor = monitor
    }

    private func handleCodexProgress(_ update: CodexProgressUpdate, sessions: [CodexSessionProgress]) {
        codexSessions = sessions
        let selectedSessionIsComplete = sessions.first(where: { $0.id == selectedCodexSessionID })?.isComplete ?? false
        if selectedCodexSessionID == nil
            || !sessions.contains(where: { $0.id == selectedCodexSessionID })
            || (selectedSessionIsComplete && update.phase != .completed && update.phase != .failed) {
            selectedCodexSessionID = update.sessionID
        }
        guard selectedCodexSessionID == update.sessionID else { return }

        // Never let an external developer task obscure live dictation, a Nex
        // response, or a user-opened answer. Codex resumes appearing as soon
        // as Nexus returns to its idle notch.
        let codexAlreadyVisible = interaction.toolActivity?.codexSessionID == update.sessionID
        guard codexAlreadyVisible || (!isListening && !isThinking && !responseIsStreaming && !isExpanded) else {
            return
        }

        let activity = ToolActivity.codex(update)
        switch update.phase {
        case .completed, .failed:
            guard codexAlreadyVisible else { return }
            interaction.completeToolActivity(activity)
            if let screen { resize(to: toolActivitySize(for: screen), animated: true) }
            codexProgressDismissTask?.cancel()
            codexProgressDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(update.phase == .failed ? 2.4 : 1.3))
                guard let self, self.interaction.toolActivity?.toolName == "Codex" else { return }
                if let nextLiveSession = self.codexSessions.first(where: { !$0.isComplete }) {
                    self.selectCodexSession(nextLiveSession.id)
                } else {
                    self.interaction.dismiss()
                    if let screen = self.screen { self.resize(to: self.idleSize(for: screen), animated: true) }
                }
            }
        case .started, .progress:
            codexProgressDismissTask?.cancel()
            interaction.beginToolActivity(activity)
            if let screen { resize(to: toolActivitySize(for: screen), animated: true) }
        }
    }

    func selectCodexSession(_ id: String) {
        guard let session = codexSessions.first(where: { $0.id == id }) else { return }
        selectedCodexSessionID = id
        codexProgressDismissTask?.cancel()
        interaction.beginToolActivity(.codex(session.latestUpdate))
        if let screen { resize(to: toolActivitySize(for: screen), animated: true) }
    }

    private func handleToolEvent(_ event: NexToolLifecycleEvent) {
        // Tool events are emitted asynchronously. A completion event can land
        // after playback has already claimed the panel; never let it replace a
        // live player with the compact tool card or its normal overlay frame.
        let playbackTools: Set<String> = ["youtube_play_current", "youtube_play", "youtube_fullscreen"]
        if mediaOverlayTab != nil, playbackTools.contains(event.toolName) {
            interaction.showMediaOverlay()
            if let screen { resize(to: currentMediaOverlaySize(for: screen), animated: false) }
            return
        }
        switch event.phase {
        case .started, .progress:
            interaction.beginToolActivity(.lifecycle(event))
            if let screen { resize(to: toolActivitySize(for: screen), animated: true) }
        case .completed:
            interaction.completeToolActivity(.lifecycle(event))
            if let screen { resize(to: toolActivitySize(for: screen), animated: true) }
        case .failed:
            interaction.completeToolActivity(.lifecycle(event))
            if let screen { resize(to: toolActivitySize(for: screen), animated: true) }
        }
    }

    private func resumeSavedConversation(id: UUID) async {
        if memory.hasValuableUnsavedConversation {
            let alert = NSAlert()
            alert.messageText = "Replace this unsaved conversation?"
            alert.informativeText = "Save it to Obsidian first, or explicitly discard it before resuming another chat."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard and Resume")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do {
            let snapshot = try await memory.resume(id: id)
            let latestUser = snapshot.turns.last(where: { $0.role == .user })?.text ?? snapshot.title
            let latestAnswer = snapshot.turns.last(where: { $0.role == .assistant })?.text ?? snapshot.summary
            interaction.restoreConversation(transcript: latestUser, answer: latestAnswer)
            savedChatsPanel?.orderOut(nil)
            automaticRevealIsWaitingForNotchVisit = true
            if let screen { resize(to: expandedSize(for: screen), animated: true) }
        } catch {
            interaction.failResponse("Nex couldn’t resume that conversation. \(error.localizedDescription)")
            if let screen { resize(to: expandedSize(for: screen), animated: true) }
        }
    }

    private func updateHover(_ hovering: Bool) {
        closeTask?.cancel()
        if hovering {
            suppressAutomaticResponseReveal = false
            guard !isListening && !isThinking && !isUsingTool else { return }
            automaticRevealIsWaitingForNotchVisit = false
            // The pointer becomes "inside" as soon as a fullscreen player
            // grows underneath it. A hover enter must never resize an active
            // player back to the ordinary overlay—media owns its geometry
            // until the user explicitly quick-dismisses it.
            if mediaOverlayTab != nil || isShowingMusic { return }
            expand()
        } else {
            if mediaOverlayTab != nil { return }
            guard !isListening && !isThinking && !isUsingTool else { return }
            guard !automaticRevealIsWaitingForNotchVisit else { return }
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.collapse()
            }
        }
    }

    private func expand() {
        expand(to: expandedSize)
    }

    private func expand(to size: (NSScreen) -> CGSize) {
        guard let screen else { return }
        interaction.showOverlay()
        resize(to: size(screen), animated: true)
    }

    private func collapse() {
        guard isExpanded, let screen else { return }
        mediaOverlayTab = nil
        isMediaFullscreen = false
        mediaPlaybackWidth = nil
        pendingYouTubePlayback = nil
        pendingYouTubeFullscreen = false
        interaction.hideOverlay()
        resize(to: idleSize(for: screen), animated: true)
    }

    private func resize(to size: CGSize, animated: Bool) {
        music.setNotchExpanded(interaction.presentation == .overlay)
        guard let panel, let screen else { return }
        // Tool events, hover callbacks, and delayed SwiftUI layout can all
        // arrive after a fullscreen request. While the media player is the
        // active overlay, its fullscreen frame is the only valid target.
        let resolvedSize = NexusMediaFullscreenSizing.resolvedSize(
            requested: size,
            screenSize: screen.frame.size,
            mediaIsActive: mediaOverlayTab != nil,
            isFullscreen: isMediaFullscreen,
            presentation: interaction.presentation
        )
        let requestedSizeChanged = abs(currentSize.width - resolvedSize.width) > 0.5
            || abs(currentSize.height - resolvedSize.height) > 0.5
        let targetFrame = frame(for: resolvedSize, on: screen)
        let frameChanged = abs(panel.frame.minX - targetFrame.minX) > 0.5
            || abs(panel.frame.minY - targetFrame.minY) > 0.5
            || abs(panel.frame.width - targetFrame.width) > 0.5
            || abs(panel.frame.height - targetFrame.height) > 0.5
        currentSize = resolvedSize
        // Streaming tokens can arrive faster than the expansion animation.
        // Once the target size is requested, do not restart that animation for
        // every token just because the presentation layer is mid-flight.
        guard animated ? requestedSizeChanged : frameChanged else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.30
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func closedSize(for screen: NSScreen) -> CGSize {
        let left = screen.auxiliaryTopLeftArea?.width
        let right = screen.auxiliaryTopRightArea?.width
        let width: CGFloat
        if let left, let right {
            width = screen.frame.width - left - right + 2
        } else {
            width = 190
        }
        let height = max(28, screen.safeAreaInsets.top)
        return CGSize(width: width, height: height)
    }

    private func musicSize(for screen: NSScreen) -> CGSize {
        // Music has no status or transcript text, so it stays within the
        // menu-bar/notch height. It may grow sideways, never downward.
        let physical = closedSize(for: screen)
        return CGSize(
            width: min(350, physical.width + NotchGeometry.wingWidth * 2 + 18),
            height: NotchGeometry.compactHeight(for: physical)
        )
    }

    private func idleSize(for screen: NSScreen) -> CGSize {
        isShowingMusic ? musicSize(for: screen) : closedSize(for: screen)
    }

    private func refreshMusicPresentation() {
        let isShowing = isShowingMusic
        let changed = wasShowingMusic != isShowing
        wasShowingMusic = isShowing
        objectWillChange.send()
        // Audio polling continues while a browser video is open. That refresh
        // must never reclaim the panel from the player or overwrite its size.
        guard changed, mediaOverlayTab == nil, let screen else { return }
        resize(to: idleSize(for: screen), animated: true)
    }

    private func expandedSize(for screen: NSScreen) -> CGSize {
        CGSize(width: min(680, screen.frame.width * 0.5), height: 245)
    }

    /// Media gets a temporary wider 16:9 canvas. It is derived solely from
    /// the present screen and resets on dismissal, never a persisted setting.
    private func mediaPlaybackSize(for screen: NSScreen) -> CGSize {
        let defaultWidth = min(820, screen.frame.width * 0.62)
        let limits = mediaPlaybackWidthLimits(for: screen)
        let width = min(max(mediaPlaybackWidth ?? defaultWidth, limits.min), limits.max)
        return CGSize(width: width, height: width * 9 / 16)
    }

    private func currentMediaOverlaySize(for screen: NSScreen) -> CGSize {
        isMediaFullscreen ? screen.frame.size : mediaPlaybackSize(for: screen)
    }

    private func mediaPlaybackWidthLimits(for screen: NSScreen) -> (min: CGFloat, max: CGFloat) {
        let minimum = min(480, screen.frame.width * 0.42)
        let maximum = min(1_100, screen.frame.width * 0.92)
        return (minimum, max(minimum, maximum))
    }

    private func listeningSize(for screen: NSScreen) -> CGSize {
        NotchGeometry.listeningSize(for: closedSize(for: screen))
    }

    private func toolActivitySize(for screen: NSScreen) -> CGSize {
        let physical = closedSize(for: screen)
        let streamsText = interaction.toolActivity?.requiresCompactTextReveal ?? false
        return CGSize(
            width: min(500, screen.frame.width * 0.42),
            height: streamsText
                ? NotchGeometry.compactTextHeight(for: physical)
                : NotchGeometry.compactHeight(for: physical)
        )
    }

    private func thinkingActivitySize(for screen: NSScreen) -> CGSize {
        let physical = closedSize(for: screen)
        return CGSize(
            width: min(500, screen.frame.width * 0.42),
            height: NotchGeometry.compactTextHeight(for: physical)
        )
    }

    private func frame(for size: CGSize, on screen: NSScreen) -> NSRect {
        NotchGeometry.centeredTopFrame(for: size, on: screen.frame)
    }

    @objc private func displayConfigurationChanged() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        self.screen = screen
        let size: CGSize = switch interaction.presentation {
        case .idle: idleSize(for: screen)
        case .dictating: listeningSize(for: screen)
        case .thinking: interaction.thinkingSentence == nil ? listeningSize(for: screen) : thinkingActivitySize(for: screen)
        case .tool: toolActivitySize(for: screen)
        case .overlay:
            if mediaOverlayTab != nil {
                currentMediaOverlaySize(for: screen)
            } else {
                expandedSize(for: screen)
            }
        }
        resize(to: size, animated: false)
    }
}

/// Keeps transient hover and tool callbacks from shrinking an already-open
/// fullscreen media player. The explicit presentation check lets a new
/// dictation session intentionally take over the panel instead.
enum NexusMediaFullscreenSizing {
    static func resolvedSize(
        requested: CGSize,
        screenSize: CGSize,
        mediaIsActive: Bool,
        isFullscreen: Bool,
        presentation: NotchPresentation
    ) -> CGSize {
        guard mediaIsActive, isFullscreen, presentation == .overlay else { return requested }
        return screenSize
    }
}

enum CommandHoldTransition: Equatable {
    case began
    case ended
    case doubleTapped
}

struct CommandHoldGestureState {
    static let defaultHoldDuration: TimeInterval = 0.65
    static let defaultDoubleTapInterval: TimeInterval = 0.36
    static let defaultMaximumTapDuration: TimeInterval = 0.24

    private enum Phase: Equatable {
        case idle
        case tracking(startedAt: TimeInterval)
        case active
        case cancelledUntilRelease
    }

    let holdDuration: TimeInterval
    let doubleTapInterval: TimeInterval
    let maximumTapDuration: TimeInterval
    private var phase: Phase = .idle
    private var lastTapEndedAt: TimeInterval?

    init(
        holdDuration: TimeInterval = CommandHoldGestureState.defaultHoldDuration,
        doubleTapInterval: TimeInterval = CommandHoldGestureState.defaultDoubleTapInterval,
        maximumTapDuration: TimeInterval = CommandHoldGestureState.defaultMaximumTapDuration
    ) {
        self.holdDuration = holdDuration
        self.doubleTapInterval = doubleTapInterval
        self.maximumTapDuration = maximumTapDuration
    }

    mutating func update(
        commandIsDown: Bool,
        hasDisqualifyingInput: Bool,
        now: TimeInterval
    ) -> CommandHoldTransition? {
        switch phase {
        case .idle:
            guard commandIsDown else {
                expirePendingTap(at: now)
                return nil
            }
            if hasDisqualifyingInput {
                lastTapEndedAt = nil
                phase = .cancelledUntilRelease
            } else {
                phase = .tracking(startedAt: now)
            }
            return nil

        case .tracking(let startedAt):
            guard commandIsDown else {
                phase = .idle
                guard !hasDisqualifyingInput, now - startedAt <= maximumTapDuration else {
                    lastTapEndedAt = nil
                    return nil
                }
                if let lastTapEndedAt, now - lastTapEndedAt <= doubleTapInterval {
                    self.lastTapEndedAt = nil
                    return .doubleTapped
                }
                lastTapEndedAt = now
                return nil
            }
            guard !hasDisqualifyingInput else {
                lastTapEndedAt = nil
                phase = .cancelledUntilRelease
                return nil
            }
            guard now - startedAt >= holdDuration - 0.000_001 else { return nil }
            lastTapEndedAt = nil
            phase = .active
            return .began

        case .active:
            if !commandIsDown {
                phase = .idle
                return .ended
            }
            if hasDisqualifyingInput {
                phase = .cancelledUntilRelease
                return .ended
            }
            return nil

        case .cancelledUntilRelease:
            lastTapEndedAt = nil
            if !commandIsDown { phase = .idle }
            return nil
        }
    }

    private mutating func expirePendingTap(at now: TimeInterval) {
        guard let lastTapEndedAt, now - lastTapEndedAt > doubleTapInterval else { return }
        self.lastTapEndedAt = nil
    }
}

private final class NexusCommandHoldMonitor {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let onDoubleTap: () -> Void
    private var gesture = CommandHoldGestureState()
    private var timer: DispatchSourceTimer?
    private var globalInputMonitor: Any?
    private var localInputMonitor: Any?
    private var disqualifiedByInput = false

    private static let modifierKeyCodes: Set<CGKeyCode> = [
        54, 55, // right and left Command
        56, 60, // Shift
        57,     // Caps Lock
        58, 61, // Option
        59, 62, // Control
        63      // Function
    ]

    init(
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onDoubleTap: @escaping () -> Void
    ) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onDoubleTap = onDoubleTap
    }

    func install() {
        guard timer == nil else { return }
        let cancellationEvents: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
        ]
        globalInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: cancellationEvents) { [weak self] _ in
            self?.disqualifiedByInput = true
        }
        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: cancellationEvents) { [weak self] event in
            self?.disqualifiedByInput = true
            return event
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
        NSLog(
            "Nexus registered hold-Command dictation with a %d ms threshold",
            Int(gesture.holdDuration * 1_000)
        )
    }

    func cancelCurrentHold() {
        disqualifiedByInput = true
        poll()
    }

    private func poll() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let commandIsDown = flags.contains(.maskCommand)
        let otherModifiersAreDown = flags.contains(.maskShift)
            || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
        let otherKeyIsDown = (CGKeyCode(0)..<CGKeyCode(128)).contains { keyCode in
            !Self.modifierKeyCodes.contains(keyCode)
                && CGEventSource.keyState(.combinedSessionState, key: keyCode)
        }
        let transition = gesture.update(
            commandIsDown: commandIsDown,
            hasDisqualifyingInput: disqualifiedByInput || otherModifiersAreDown || otherKeyIsDown,
            now: ProcessInfo.processInfo.systemUptime
        )
        if !commandIsDown { disqualifiedByInput = false }
        switch transition {
        case .began: onPress()
        case .ended: onRelease()
        case .doubleTapped: onDoubleTap()
        case nil: break
        }
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
        if let globalInputMonitor { NSEvent.removeMonitor(globalInputMonitor) }
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }
    }
}

private final class PointerProximityMonitor {
    private var timer: DispatchSourceTimer?

    init(onMove: @escaping (NSPoint) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler {
            onMove(NSEvent.mouseLocation)
        }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
    }
}

private final class NexusNotchPanel: NSPanel {
    var onMouseDown: ((NSPoint) -> Bool)?

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        acceptsMouseMovedEvents = true
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, onMouseDown?(event.locationInWindow) == true {
            return
        }
        super.sendEvent(event)
    }
}
