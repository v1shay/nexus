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
    private var menuBarItem: NSStatusItem?
    private var menuBarOrbView: NSHostingView<NexusMenuBarOrb>?
    private var automationWindow: NSWindow?
    private var connectHost: NexusConnectHostDaemon?
    private var nexCLIHost: NexCLIHostDaemon?
    private var launchTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests inject XCTest into the app process. They construct every
        // controller explicitly and must not initialize the real Keychain,
        // global hotkey, notch panel, or LaunchAgent as a side effect.
        // Unit-test bundles are linked into the app process too. The explicit
        // UI-test launch argument must win so the automation overlay can be
        // constructed and exercised.
        if NSClassFromString("XCTestCase") != nil,
           !CommandLine.arguments.contains("--nexus-ui-testing") {
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--nex-computer") {
            NSApp.setActivationPolicy(.prohibited)
            let arguments = Array(CommandLine.arguments.dropFirst(index + 1))
            launchTask = Task {
                let status = await NexComputerCLI.run(arguments: arguments)
                Foundation.exit(status)
            }
            return
        }
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
        if CommandLine.arguments.contains("--nexus-ui-smoke") {
            // This is intentionally a controller-level smoke test, not a
            // hidden production mode. It exercises typed submission through
            // the exact same state pipeline as the overlay while keeping the
            // run hermetic (no microphone, Keychain, connector, or model).
            NSApp.setActivationPolicy(.prohibited)
            launchTask = Task { @MainActor in
                let notch = NotchController()
                await notch.submitTypedPrompt("Validate the typed Nexus request pipeline")
                try? await Task.sleep(for: .milliseconds(650))
                let expected = "Automation response: Validate the typed Nexus request pipeline"
                let passed = notch.transcript == "Validate the typed Nexus request pipeline"
                    && notch.answer == expected
                    && notch.toolReceipt?.actionID == "automation.typed_request"
                FileHandle.standardOutput.write(Data("Nexus typed lifecycle smoke: \(passed ? "passed" : "failed")\n".utf8))
                Foundation.exit(passed ? 0 : 1)
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--nexus-ui-testing") {
            let notch = NotchController()
            self.notch = notch
            notch.openAutomationTypingOverlay()
            // XCUITest cannot reliably synthesize keyboard/mouse events into
            // a system-level notch panel. This normal host window renders the
            // same controller and SwiftUI overlay so the request lifecycle is
            // testable without microphone, hotkey, Keychain, or global-panel
            // focus dependencies. Notch geometry is covered independently.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 360),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Nexus automation"
            window.contentView = NSHostingView(rootView: ContentView().environmentObject(notch))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            automationWindow = window
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
            self?.installMenuBarOrb(for: notch)
            await NexusDuplexVoiceRuntime.shared.reconcile(
                with: notch.settings.duplexVoiceEngine,
                personaPlexEndpoint: notch.settings.personaPlexRemoteEndpoint
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchTask?.cancel()
        notch?.shutdown()
        connectHost?.stop()
        nexCLIHost?.stop()
        NexusDuplexVoiceRuntime.shared.stop()
        if let menuBarItem { NSStatusBar.system.removeStatusItem(menuBarItem) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        notch?.confirmDiscardBeforeQuit() == false ? .terminateCancel : .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notch?.openModelAggregator()
        return true
    }

    private func installMenuBarOrb(for notch: NotchController) {
        guard menuBarItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 28)
        guard let button = item.button else { return }
        button.title = ""
        button.image = nil
        button.target = self
        button.action = #selector(openNexusFromMenuBar)
        button.toolTip = "Nexus — Option-Command dictation"
        let orb = NSHostingView(rootView: NexusMenuBarOrb(notch: notch))
        orb.frame = NSRect(x: 4, y: 2, width: 20, height: 20)
        orb.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        button.addSubview(orb)
        menuBarItem = item
        menuBarOrbView = orb
    }

    @objc private func openNexusFromMenuBar() {
        notch?.openModelAggregator()
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

/// A visual-only menu-bar affordance. It deliberately contains no transcript
/// or status copy: the animation alone communicates listening versus ready.
private struct NexusMenuBarOrb: View {
    @ObservedObject var notch: NotchController

    var body: some View {
        NexusOrbAnimation(
            mode: (notch.isGlobalPasteDictating || notch.isListening) ? .composing : .thinkingCycle,
            size: 18,
            tint: .white
        )
        .frame(width: 20, height: 20)
        .accessibilityLabel(notch.isGlobalPasteDictating ? "Nexus dictating" : "Nexus ready")
    }
}

@MainActor
final class NotchController: ObservableObject {
    @Published private var interaction = NotchInteractionState()
    @Published private(set) var currentSize = CGSize(width: 190, height: 32)
    @Published private(set) var isVoiceMuted = false
    @Published private(set) var isGlobalPasteDictating = false
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
    private var globalPasteDictationMonitor: NexusCommandHoldMonitor?
    private var pointerMonitor: PointerProximityMonitor?
    private var modelPanel: NSPanel?
    private var savedChatsPanel: NSPanel?
    private let speechTranscriber = SpeechTranscriber()
    private var globalPasteSpeculationTask: Task<NexusSpeculativeDictation?, Never>?
    private var globalPasteSpeculationRaw = ""
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
    private lazy var computerRegistry = NexComputerRegistry(toolRegistry: memory.registry)
    private lazy var terminalActions = NexTerminalActionCatalog()
    private lazy var finderActions = NexFinderActionCatalog()
    private lazy var spotifyActions = NexSpotifyActionCatalog()
    private lazy var messagesActions = NexMessagesActionCatalog()
    private lazy var photosActions = NexPhotosActionCatalog()
    private lazy var vscodeActions = NexVSCodeActionCatalog()
    private lazy var codexActions = NexCodexActionCatalog()
    private lazy var obsidianActions = NexObsidianActionCatalog()
    private lazy var githubActions = NexGitHubActionCatalog()
    private lazy var systemActions = NexSystemActionCatalog()
    private lazy var xcodeActions = NexXcodeActionCatalog()
    private lazy var previewActions = NexPreviewActionCatalog()
    private lazy var applicationActions = NexApplicationActionCatalog()
    private lazy var browserActions = NexBrowserActionCatalog()
    private lazy var chromeTabActions = NexChromeTabActionCatalog()
    private let connectorAuth = NexConnectorAuthController.shared
    private lazy var connectorManager = NexConnectorManager()
    private lazy var webSearch = NexWebSearchController(registry: memory.registry)
    private lazy var youtubeTools = NexYouTubeToolController(registry: memory.registry) { [weak self] tab, fullscreen in
        self?.requestYouTubePlayback(tab, fullscreen: fullscreen) ?? false
    }
    private lazy var toolOrchestrator = NexToolOrchestrator(registry: memory.registry)
    private lazy var toolSearch = NexToolSearchService(registry: memory.registry, computerRegistry: computerRegistry)
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
    /// A hands-free session begins with one Command hold and remains armed
    /// across turns until the user double-presses Command.
    private var alwaysOnVoiceSessionActive = false
    /// Kept only for the live request. Screens are never written to the
    /// conversation, memory, or saved-chat stores.
    private var currentRequestScreenAttachment: NexusScreenAttachment?
    private var globalPasteTarget: NexusFocusedTextTarget?

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
            styleMask: [.borderless, .utilityWindow, .hudWindow],
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
                try? await terminalActions.register(on: computerRegistry)
                try? await finderActions.register(on: computerRegistry)
                try? await spotifyActions.register(on: computerRegistry)
                try? await messagesActions.register(on: computerRegistry)
                try? await photosActions.register(on: computerRegistry)
                try? await vscodeActions.register(on: computerRegistry)
                try? await codexActions.register(on: computerRegistry)
                try? await obsidianActions.register(on: computerRegistry)
                try? await githubActions.register(on: computerRegistry)
                try? await systemActions.register(on: computerRegistry)
                try? await xcodeActions.register(on: computerRegistry)
                try? await previewActions.register(on: computerRegistry)
                try? await applicationActions.register(on: computerRegistry)
                try? await browserActions.register(on: computerRegistry)
                try? await chromeTabActions.register(on: computerRegistry)
                try? await connectorManager.reloadStoredConnections(registry: computerRegistry)
                try? await toolSearch.registerIfNeeded()
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

    /// XCUITest needs a visible, keyboard-accessible surface without relying
    /// on a mouse hover, microphone permission, or global hotkey.  This is
    /// only reachable through the explicit automation launch argument.
    func openAutomationTypingOverlay() {
        guard NexusSecretStoreRuntime.usesSyntheticResponse else { return }
        interaction.showOverlay()
        if let screen { resize(to: expandedSize(for: screen), animated: false) }
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
                Task { @MainActor in
                    guard let self else { return }
                    if self.settings.alwaysOnVoiceMode {
                        await self.startAlwaysOnVoiceSession()
                    } else {
                        await self.startGlobalDictation()
                    }
                }
            },
            onRelease: { [weak self] in
                Task { @MainActor in
                    guard let self, !self.alwaysOnVoiceSessionActive else { return }
                    await self.finishGlobalDictation()
                }
            },
            onDoubleTap: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if self.alwaysOnVoiceSessionActive {
                        self.stopAlwaysOnVoiceSession()
                    } else {
                        self.quickDismiss()
                    }
                }
            }
        )
        commandHoldMonitor = monitor
        monitor.install()

        let globalPasteMonitor = NexusCommandHoldMonitor(
            requiresOption: true,
            holdDuration: 0.10,
            onPress: { [weak self] in
                Task { @MainActor in await self?.startGlobalPasteDictation() }
            },
            onRelease: { [weak self] in
                Task { @MainActor in await self?.finishGlobalPasteDictation() }
            },
            onDoubleTap: {}
        )
        globalPasteDictationMonitor = globalPasteMonitor
        globalPasteMonitor.install()
    }

    /// Starts a new request before either speech or typed text is supplied.
    /// Keeping this separate is important: both input modes must interrupt a
    /// prior stream, preserve the same active conversation, and then enter the
    /// exact same finalization/response pipeline.
    private func prepareForUserRequest() async {
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
        currentRequestScreenAttachment = nil
        responseSpeaker.stop()
        hideThinkingModelMark()
        suppressAutomaticResponseReveal = false
        interaction.beginDictation()
        if let screen {
            resize(to: listeningSize(for: screen), animated: true)
        }
    }

    private func startGlobalDictation(automaticallySubmitAfterSilence: Bool = false) async {
        await prepareForUserRequest()
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

    private func startAlwaysOnVoiceSession() async {
        guard !alwaysOnVoiceSessionActive else { return }
        alwaysOnVoiceSessionActive = true
        await prepareForUserRequest()
        beginAlwaysOnListening()
    }

    /// Keeps the microphone alive while Nex is thinking or speaking. The
    /// transcriber owns the 0.7 s silence gate; its completion is also the
    /// barge-in signal that immediately stops the current spoken response.
    private func beginAlwaysOnListening() {
        guard alwaysOnVoiceSessionActive else { return }
        speechTranscriber.start(
            engine: settings.speechEngine,
            automaticallySubmitAfterSilence: 0.7,
            onAutomaticSubmit: { [weak self] in
                Task { @MainActor in await self?.finishAlwaysOnDictation() }
            }
        ) { [weak self] text in
            Task { @MainActor in self?.interaction.updateTranscript(text) }
        }
    }

    private func finishAlwaysOnDictation() async {
        guard alwaysOnVoiceSessionActive else { return }
        await interruptResponseForAlwaysOnVoice()
        await finishGlobalDictation()
    }

    private func interruptResponseForAlwaysOnVoice() async {
        wakePhraseListener.stop()
        closeTask?.cancel()
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
    }

    private func stopAlwaysOnVoiceSession() {
        guard alwaysOnVoiceSessionActive else { return }
        alwaysOnVoiceSessionActive = false
        speechTranscriber.stop()
        responseTask?.cancel()
        responseGeneration = UUID()
        responseIsStreaming = false
        responseSpeaker.stop()
        hideThinkingModelMark()
        interaction.dismiss()
        if let screen { resize(to: idleSize(for: screen), animated: true) }
        armWakePhraseListener()
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
        await submitFinalizedPrompt()
    }

    /// A separate path from Nexus conversation voice. It never opens an
    /// assistant request: the finalized, cleaned utterance is inserted back
    /// into the focused control in the app where the shortcut began.
    private func startGlobalPasteDictation() async {
        guard settings.globalPasteDictationEnabled,
              !isGlobalPasteDictating,
              !isListening,
              !responseIsStreaming else { return }
        guard let target = NexusFocusedTextTarget.requestingAccessIfNeeded() else { return }
        globalPasteTarget = target
        isGlobalPasteDictating = true
        globalPasteSpeculationTask?.cancel()
        globalPasteSpeculationTask = nil
        globalPasteSpeculationRaw = ""
        // Model loading happens while the user is speaking, never after they
        // release the shortcut. It is a separate model from the agent.
        Task { await modelDownloadViewModel.prepareDictationRefiner() }
        speechTranscriber.start(engine: settings.speechEngine) { [weak self] partial in
            Task { @MainActor in self?.speculateGlobalDictation(for: partial) }
        }
    }

    private func finishGlobalPasteDictation() async {
        guard isGlobalPasteDictating else { return }
        isGlobalPasteDictating = false
        defer {
            globalPasteTarget = nil
            globalPasteSpeculationTask?.cancel()
            globalPasteSpeculationTask = nil
            globalPasteSpeculationRaw = ""
        }
        guard let transcript = await speechTranscriber.stopAndTranscribe() else { return }
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
              !raw.isEmpty else { return }
        let endpoint = Date()
        let cleaned: String
        if globalPasteSpeculationRaw.normalizedForDictationMatch == raw.normalizedForDictationMatch,
           let candidate = await globalPasteSpeculationTask?.value,
           candidate.raw.normalizedForDictationMatch == raw.normalizedForDictationMatch {
            cleaned = candidate.cleaned
        } else {
            globalPasteSpeculationTask?.cancel()
            cleaned = await refineGlobalDictation(raw)
        }
        guard !cleaned.isEmpty else { return }
        if globalPasteTarget?.replaceSelectedText(with: cleaned) != true {
            NSSound.beep()
        }
        let elapsedMilliseconds = Date().timeIntervalSince(endpoint) * 1_000
        NSLog("Nexus global dictation cleanup and insertion: %.0f ms", elapsedMilliseconds)
    }

    /// The refiner is a single, short, no-tools completion. It runs only after
    /// endpointing has finalized the utterance, which permits semantic cleanup
    /// (lists and self-corrections) without repeatedly rewriting partial ASR.
    private func refineGlobalDictation(_ raw: String) async -> String {
        do {
            let result = try await modelDownloadViewModel.refineGlobalDictation(raw)
            return NexusDictationRefinementPrompt.sanitize(result, fallback: raw)
        } catch {
            // Dictation must always paste rather than fail because an optional
            // cleaner is unavailable. The raw ASR result is the low-latency,
            // lossless fallback.
            return raw
        }
    }

    /// Apple Speech delivers live chunks. Once a chunk has held still for a
    /// beat, refine it in parallel with the remaining endpoint work. The
    /// result is accepted only when it is the exact final transcript, so an
    /// unfinished sentence can never be pasted as if it were complete.
    private func speculateGlobalDictation(for partial: String) {
        let candidate = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= 18 else { return }
        globalPasteSpeculationTask?.cancel()
        globalPasteSpeculationRaw = candidate
        globalPasteSpeculationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return nil }
            let cleaned = await self.refineGlobalDictation(candidate)
            guard !Task.isCancelled else { return nil }
            return NexusSpeculativeDictation(raw: candidate, cleaned: cleaned)
        }
    }

    /// Typed input is deliberately not a parallel chat implementation.  It
    /// shares the speech path after transcription, so it gets the same active
    /// context, tool registry, preview cards, streaming response, memory
    /// policy, and notch transitions.
    func submitTypedPrompt(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        await prepareForUserRequest()
        interaction.updateTranscript(prompt)
        await submitFinalizedPrompt()
    }

    private func submitFinalizedPrompt() async {
        interaction.finishDictation()
        let finalizedPrompt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalizedPrompt.isEmpty, await conversationSession.appendUser(finalizedPrompt) != nil {
            await memory.conversationDidChange()
        }
        currentRequestScreenAttachment = captureScreenAttachmentIfNeeded()
        automaticRevealIsWaitingForNotchVisit = true
        if let screen {
            resize(to: expandedSize(for: screen), animated: true)
        }
        startResponseIfPossible()
        // `stopAndTranscribe()` releases the microphone before this point.
        // Re-arm it immediately so a user can interrupt the spoken answer.
        beginAlwaysOnListening()
    }

    private func armWakePhraseListener() {
        guard !alwaysOnVoiceSessionActive, !isListening, !responseIsStreaming else { return }
        wakePhraseListener.start { [weak self] phrase in
            guard let self else { return }
            NSLog("Nex heard wake phrase: %@", phrase.rawValue)
            Task { @MainActor in await self.startGlobalDictation(automaticallySubmitAfterSilence: true) }
        }
    }

    private func captureScreenAttachmentIfNeeded() -> NexusScreenAttachment? {
        guard settings.shareScreenWithVisionModels,
              modelDownloadViewModel.activeModelSupportsImageInput else { return nil }
        guard let attachment = NexusScreenCapture.captureCurrentScreen() else {
            NSLog("Nexus could not capture screen context; continuing without an image")
            return nil
        }
        return attachment
    }

    private func applyingCurrentScreenAttachment(to messages: [NexusChatMessage]) -> [NexusChatMessage] {
        guard let attachment = currentRequestScreenAttachment,
              let userIndex = messages.lastIndex(where: { $0.role == "user" }) else { return messages }
        var result = messages
        let original = result[userIndex]
        result[userIndex] = .init(
            role: original.role,
            content: original.content + "\n\nA current screenshot of the user's screen is attached. Use it only when it helps answer the request.",
            imageBase64: attachment.base64,
            imageMediaType: attachment.mediaType
        )
        return result
    }

    private func startResponseIfPossible() {
        let prompt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if NexusSecretStoreRuntime.usesSyntheticResponse {
            startAutomationResponse(for: prompt)
            return
        }
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
        // A generated status must be the first text Nex presents.  Previously
        // the model-backed modes wrote and spoke “Preparing a response…” here,
        // which could outlive (and visually mask) the actual generated line.
        // Deterministic mode is intentionally immediate; model-backed modes
        // stay text-free until their real status arrives.
        let immediateStatus = settings.statusMode == .deterministic
            ? NexusStatusLineGenerator.status(for: prompt)
            : nil
        if let immediateStatus {
            interaction.acknowledge(immediateStatus)
        }
        if let screen { resize(to: expandedSize(for: screen), animated: true) }
        if let immediateStatus {
            responseSpeaker.speakImmediately(immediateStatus)
        }
        responseTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, responseGeneration == generation else { return }
            responseSpeaker.beginStreaming()
            responseIsStreaming = true
            do {
                let baseMessages = applyingCurrentScreenAttachment(
                    to: await conversationSession.contextMessages()
                )
                requestAsyncStatusIfNeeded(prompt: prompt, generation: generation)
                let presentationTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard let self, !Task.isCancelled, self.responseGeneration == generation else { return }
                    guard !self.isThinking, !self.isUsingTool else { return }
                    self.beginThinkingPresentation()
                    if let screen = self.screen { self.resize(to: self.listeningSize(for: screen), animated: true) }
                }
                defer { presentationTask.cancel() }
                await memory.prepareToolRegistry()
                try? await webSearch.registerIfNeeded()
                try? await youtubeTools.registerIfNeeded()
                try? await terminalActions.register(on: computerRegistry)
                try? await finderActions.register(on: computerRegistry)
                try? await spotifyActions.register(on: computerRegistry)
                try? await messagesActions.register(on: computerRegistry)
                try? await photosActions.register(on: computerRegistry)
                try? await vscodeActions.register(on: computerRegistry)
                try? await codexActions.register(on: computerRegistry)
                try? await obsidianActions.register(on: computerRegistry)
                try? await githubActions.register(on: computerRegistry)
                try? await systemActions.register(on: computerRegistry)
                try? await xcodeActions.register(on: computerRegistry)
                try? await previewActions.register(on: computerRegistry)
                try? await applicationActions.register(on: computerRegistry)
                try? await browserActions.register(on: computerRegistry)
                try? await chromeTabActions.register(on: computerRegistry)
                try? await connectorManager.reloadStoredConnections(registry: computerRegistry)
                try? await toolSearch.registerIfNeeded()
                let allDefinitions = await memory.registry.definitions()
                let discovery = await toolSearch.search(query: prompt)
                var definitions = await toolSearch.definitions(for: discovery)
                if let searchTool = allDefinitions.first(where: { $0.name == NexToolSearchService.actionName }) {
                    definitions.append(searchTool)
                }
                definitions.sort { $0.name < $1.name }
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
                // Keep the acknowledgement readable, then deliberately enter
                // the compact working state. Planning completes before the
                // answer starts so an internal “I should search” thought can
                // never be exposed as the user-facing answer.
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled, responseGeneration == generation else { return }
                if !isThinking && !isUsingTool {
                    beginThinkingPresentation()
                    if let screen { resize(to: listeningSize(for: screen), animated: true) }
                }

                if plan.actions.isEmpty {
                    let answer = try await streamModelResponse(messages: baseMessages, generation: generation)
                    let finalDelta = responseSpeechCursor.consume(delta: "", accumulated: answer)
                    if !finalDelta.isEmpty { responseSpeaker.append(finalDelta) }
                    toolResult = nil
                } else {
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
                        if !result.discoveredToolNames.isEmpty {
                            let alreadyAvailable = Set(definitions.map(\.name))
                            let newlyAvailable = allDefinitions.filter {
                                result.discoveredToolNames.contains($0.name)
                                    && !alreadyAvailable.contains($0.name)
                            }
                            definitions.append(contentsOf: newlyAvailable)
                            definitions.sort { $0.name < $1.name }
                        }
                        let startedPlayback = actions.contains {
                            ["youtube_play_current", "youtube_play", "youtube_fullscreen"].contains($0.tool)
                        } && mediaOverlayTab != nil
                        if startedPlayback { break }

                        let planningContext = applyingCurrentScreenAttachment(
                            to: await conversationSession.contextMessages(
                                memoryLookupPerformed: memoryLookupPerformed,
                                webContext: result.context
                            )
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
                    let messages = applyingCurrentScreenAttachment(
                        to: await conversationSession.contextMessages(
                            memoryLookupPerformed: memoryLookupPerformed,
                            webContext: result.context
                        )
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

    /// A deterministic, no-network responder used exclusively by the UI
    /// automation profile.  It proves the real typed-input → compact work
    /// state → tool receipt → answer UI lifecycle without exercising a live
    /// model, microphone, Keychain, connector, or destructive tool.  Live
    /// model/tool verification remains separate and opt-in.
    private func startAutomationResponse(for prompt: String) {
        guard !prompt.isEmpty else { return }
        responseTask?.cancel()
        let generation = UUID()
        responseGeneration = generation
        responseIsStreaming = true
        interaction.acknowledge("Validating typed request…")
        responseTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, self.responseGeneration == generation else { return }
            let activity = ToolActivity(
                actionID: "automation.typed_request",
                toolName: "Nexus automation",
                status: "Validated typed request",
                spokenStatus: "",
                icon: .systemSymbol("checkmark.seal"),
                phase: .completed,
                result: .object(["status": .string("validated")])
            )
            self.interaction.completeToolActivity(activity)
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, self.responseGeneration == generation else { return }
            let answer = "Automation response: \(prompt)"
            self.interaction.receiveAnswer(answer)
            _ = await self.conversationSession.appendAssistant(answer)
            self.responseIsStreaming = false
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
                        maximumTokens: 24,
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
                        maximumTokens: 24,
                        includeNexusSystemPrompt: false,
                        onDelta: { _, _ in }
                    )
                case .deterministic:
                    return
                }
                guard responseGeneration == generation,
                      let status = NexusStatusLineGenerator.sanitize(raw) else { return }
                // Never replace the transcript or an answer with a late
                // status-model result. `workingStatus` is retained through the
                // compact thinking handoff and displayed as soon as that state
                // is active. Do not accept a result after the response ended.
                guard responseIsStreaming else { return }
                interaction.updateWorkingStatus(status)
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

    func confirmTaskPreview(_ id: UUID) {
        // Confirmation controls are registered without a `nex.` namespace.
        // The old spelling failed and discarded the error, leaving every
        // confirmation card looking like it had done nothing.
        Task { _ = try? await memory.registry.execute(name: "confirm_action", arguments: ["actionId": .string(id.uuidString)], invocation: .app) }
    }

    func cancelTaskPreview(_ id: UUID?) {
        if let id { Task { _ = try? await memory.registry.execute(name: "cancel_action", arguments: ["actionId": .string(id.uuidString)], invocation: .app) } }
        interaction.dismiss()
        if let screen { resize(to: idleSize(for: screen), animated: true) }
    }

    func sendMessageDraft(id: String, recipient: String, body: String) {
        Task {
            _ = try? await memory.registry.execute(
                name: "messages.send_draft",
                arguments: [
                    "messageDraftId": .string(id),
                    "recipient": .string(recipient),
                    "body": .string(body)
                ],
                invocation: .app
            )
        }
    }

    func connectProvider(_ provider: NexConnectorProvider) { connectorAuth.connectWithEnabledScopes(provider) }
    func openTaskPreviewTarget(_ url: URL) { NSWorkspace.shared.open(url) }

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
            cliSettings: .shared,
            connectorAuth: connectorAuth
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
        // NSPanel can be ordered out by another application's activation even
        // when it remains alive. Re-ordering here is intentional: every
        // public Nexus transition (hover, global hold-Command, a tool event,
        // or streamed text) passes through this method. It keeps the notch
        // above the frontmost app without activating Nexus or stealing focus.
        panel.orderFrontRegardless()
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
        if interaction.toolActivity?.requiresExpandedPreview == true {
            return CGSize(width: min(650, screen.frame.width * 0.58), height: min(500, screen.frame.height * 0.62))
        }
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

private struct NexusScreenAttachment: Sendable {
    let base64: String
    let mediaType: String
}

/// Produces a bounded JPEG so enabling vision context does not turn an
/// ordinary prompt into a multi-megabyte full-resolution desktop upload. macOS
/// owns the Screen Recording permission prompt; a declined or unavailable
/// permission simply leaves the request text-only.
private enum NexusScreenCapture {
    static func captureCurrentScreen() -> NexusScreenAttachment? {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess(),
              let image = CGWindowListCreateImage(
                .infinite,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution]
              ) else { return nil }

        let source = NSImage(cgImage: image, size: .init(width: image.width, height: image.height))
        let longestEdge = CGFloat(max(image.width, image.height))
        let scale = min(1, 1_920 / max(1, longestEdge))
        let targetSize = NSSize(
            width: max(1, CGFloat(image.width) * scale),
            height: max(1, CGFloat(image.height) * scale)
        )
        let target = NSImage(size: targetSize)
        target.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: targetSize))
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.68]
              ) else { return nil }
        return .init(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg")
    }
}

/// Stores the exact accessibility element focused at shortcut press, so a
/// cleaned result cannot land in a different app if focus changes while the
/// user is speaking.
private final class NexusFocusedTextTarget: @unchecked Sendable {
    private let element: AXUIElement

    private init(element: AXUIElement) { self.element = element }

    static func requestingAccessIfNeeded() -> NexusFocusedTextTarget? {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        let element = focused as! AXUIElement
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return nil }
        return .init(element: element)
    }

    func replaceSelectedText(with text: String) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }
}

enum NexusDictationRefinementPrompt {
    static func messages(for transcript: String) -> [NexusChatMessage] {
        [
            .init(
                role: "system",
                content: """
                NEXUS_DICTATION_REFINEMENT
                Transform one spoken utterance into polished text for insertion into the focused field. Preserve its meaning, names, numbers, quotes, code, and commands. Remove only clear verbal disfluencies and resolve unmistakable self-corrections. A correction marker is never part of the output: "actually", "make that", "scratch that", or "I mean". If one revises a preceding phrase or numbered item, discard the old phrase and marker; output only the replacement. Infer punctuation, paragraphs, and lists when the utterance strongly supports them. Do not summarize, answer, add commentary, labels, Markdown fences, or quotation marks around the result. If meaning is ambiguous, preserve the original wording.

                Examples:
                Spoken: "um schedule it for Tuesday actually Thursday"
                Output: "Schedule it for Thursday."
                Spoken: "one apples two actually make that bananas three oranges"
                Output:
                1. Apples
                2. Bananas
                3. Oranges
                Spoken: "one finish onboarding screens two actually make that settings screens three ship the build by Friday"
                Output:
                1. Finish onboarding screens
                2. Settings screens
                3. Ship the build by Friday
                """
            ),
            .init(role: "user", content: transcript)
        ]
    }

    static func sanitize(_ result: String, fallback: String) -> String {
        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              !cleaned.localizedCaseInsensitiveContains("NEXUS_DICTATION_REFINEMENT") else { return fallback }
        return cleaned
    }
}

private struct NexusSpeculativeDictation: Sendable {
    let raw: String
    let cleaned: String
}

private extension String {
    /// Comparison only; it does not modify the text we eventually insert.
    /// Apple Speech commonly changes capitalization or whitespace between its
    /// final partial and endpoint result.
    var normalizedForDictationMatch: String {
        lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
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
    private let requiresOption: Bool
    private var gesture: CommandHoldGestureState
    private var timer: DispatchSourceTimer?
    private var globalInputMonitor: Any?
    private var localInputMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var observedFlags: CGEventFlags?
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
        requiresOption: Bool = false,
        holdDuration: TimeInterval = CommandHoldGestureState.defaultHoldDuration,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onDoubleTap: @escaping () -> Void
    ) {
        self.requiresOption = requiresOption
        gesture = CommandHoldGestureState(holdDuration: holdDuration)
        self.onPress = onPress
        self.onRelease = onRelease
        self.onDoubleTap = onDoubleTap
    }

    func install() {
        guard timer == nil else { return }
        let cancellationEvents: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
        ]
        let watchedEvents = cancellationEvents.union(.flagsChanged)
        globalInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: watchedEvents) { [weak self] event in
            self?.receive(event: event)
        }
        localInputMonitor = NSEvent.addLocalMonitorForEvents(matching: watchedEvents) { [weak self] event in
            self?.receive(event: event)
            return event
        }

        installGlobalEventTapIfPossible()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
        NSLog(
            "Nexus registered %@ dictation with a %d ms threshold (event tap: %@)",
            requiresOption ? "Option-Command" : "Command",
            Int(gesture.holdDuration * 1_000),
            eventTap == nil ? "unavailable" : "active"
        )
    }

    func cancelCurrentHold() {
        disqualifiedByInput = true
        poll()
    }

    private func poll() {
        let flags = observedFlags ?? CGEventSource.flagsState(.combinedSessionState)
        let commandIsDown = flags.contains(.maskCommand)
            && (!requiresOption || flags.contains(.maskAlternate))
        let otherModifiersAreDown = flags.contains(.maskShift)
            || flags.contains(.maskControl)
            || (!requiresOption && flags.contains(.maskAlternate))
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

    private func receive(event: NSEvent) {
        if event.type == .flagsChanged {
            observedFlags = Self.cgEventFlags(from: event.modifierFlags)
        } else {
            disqualifiedByInput = true
        }
        poll()
    }

    private static func cgEventFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        return result
    }

    /// A modifier-only gesture cannot be registered with Carbon. A passive
    /// CGEvent tap is the reliable macOS mechanism for observing it while a
    /// different app is frontmost. It never consumes keystrokes. If macOS has
    /// not granted Input Monitoring yet, keep the NSEvent/poll fallback and
    /// ask once so the next hold works without requiring Nexus to be focused.
    private func installGlobalEventTapIfPossible() {
        if !CGPreflightListenEventAccess() {
            let requestedKey = "NexusRequestedInputMonitoring.v1"
            if !UserDefaults.standard.bool(forKey: requestedKey) {
                UserDefaults.standard.set(true, forKey: requestedKey)
                _ = CGRequestListenEventAccess()
            }
            NSLog("Nexus needs Input Monitoring for the global hold-Command gesture")
            return
        }

        let eventMask: CGEventMask =
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Nexus could not create its passive global key event tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<NexusCommandHoldMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        monitor.receive(type: type, flags: event.flags)
        return Unmanaged.passUnretained(event)
    }

    private func receive(type: CGEventType, flags: CGEventFlags) {
        observedFlags = flags
        switch type {
        case .flagsChanged:
            break
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            disqualifiedByInput = true
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        default:
            break
        }
        poll()
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
        if let globalInputMonitor { NSEvent.removeMonitor(globalInputMonitor) }
        if let localInputMonitor { NSEvent.removeMonitor(localInputMonitor) }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
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
        hidesOnDeactivate = false
        worksWhenModal = true
        acceptsMouseMovedEvents = true
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    // Hovering only orders the panel front. It becomes key after an
    // intentional interaction so the typed request field can receive input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, onMouseDown?(event.locationInWindow) == true {
            return
        }
        super.sendEvent(event)
    }
}
