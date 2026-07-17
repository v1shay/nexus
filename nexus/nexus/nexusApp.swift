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
    private var launchTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Unit tests inject XCTest into the app process. They construct every
        // controller explicitly and must not initialize the real Keychain,
        // global hotkey, notch panel, or LaunchAgent as a side effect.
        if NSClassFromString("XCTestCase") != nil { return }
        if NexusConnectHostProcess.isCurrentProcess {
            let host = NexusConnectHostDaemon()
            connectHost = host
            launchTask = Task { @MainActor in await host.start() }
            return
        }
        if CommandLine.arguments.contains("--nexus-ui-testing") {
            let notch = NotchController()
            self.notch = notch
            notch.install(startServices: false)
            return
        }
        launchTask = Task { @MainActor [weak self] in
            await Self.retireOlderInstances()
            guard !Task.isCancelled else { return }
            let notch = NotchController()
            self?.notch = notch
            notch.install()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchTask?.cancel()
        notch?.shutdown()
        connectHost?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        notch?.confirmDiscardBeforeQuit() == false ? .terminateCancel : .terminateNow
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

    var presentation: NotchPresentation { interaction.presentation }
    var isExpanded: Bool { interaction.presentation == .overlay }
    var isListening: Bool { interaction.presentation == .dictating }
    var isThinking: Bool { interaction.presentation == .thinking }
    var isUsingTool: Bool { interaction.presentation == .tool }
    var toolActivity: ToolActivity? { interaction.toolActivity }
    var transcript: String { interaction.transcript }
    var answer: String { interaction.answer }

    private var panel: NexusNotchPanel?
    private var screen: NSScreen?
    private var closeTask: Task<Void, Never>?
    private var commandHoldMonitor: NexusCommandHoldMonitor?
    private var pointerMonitor: PointerProximityMonitor?
    private var modelPanel: NSPanel?
    private var savedChatsPanel: NSPanel?
    private let speechTranscriber = SpeechTranscriber()
    private let connectController: NexusConnectController
    private let modelDownloadViewModel: ModelDownloadViewModel
    private var automaticRevealIsWaitingForNotchVisit = false
    private let responseSpeaker = ResponseSpeaker()
    private var responseTask: Task<Void, Never>?
    private var responseGeneration = UUID()
    private var responseSpeechCursor = StreamedSpeechCursor()
    private let conversationSession: NexConversationSession
    let memory: NexMemoryController
    private var memoryObservation: AnyCancellable?
    private var toolEventTask: Task<Void, Never>?
    private var responseIsStreaming = false
    private var previousThinkingPhrase: String?
    private var hoverSession = NotchHoverSession()
    private var suppressAutomaticResponseReveal = false

    init(connectController: NexusConnectController? = nil) {
        let resolvedConnectController = connectController ?? .shared
        let conversationSession = NexConversationSession()
        self.connectController = resolvedConnectController
        self.conversationSession = conversationSession
        modelDownloadViewModel = ModelDownloadViewModel(connect: resolvedConnectController)
        memory = NexMemoryController(conversation: conversationSession)
        memoryObservation = memory.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
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
        self.panel = panel
        if startServices {
            startToolEventListener()
            memory.start()
            installCommandHoldMonitor()
            installPointerMonitor()
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

    private func startGlobalDictation() async {
        closeTask?.cancel()
        if responseIsStreaming, !responseSpeechCursor.text.isEmpty {
            await conversationSession.appendAssistant(responseSpeechCursor.text, interrupted: true)
            await memory.conversationDidChange()
        }
        responseIsStreaming = false
        responseTask?.cancel()
        responseGeneration = UUID()
        responseSpeechCursor = StreamedSpeechCursor()
        responseSpeaker.stop()
        suppressAutomaticResponseReveal = false
        interaction.beginDictation()
        if let screen {
            resize(to: listeningSize(for: screen), animated: true)
        }
        speechTranscriber.start { [weak self] text in
            Task { @MainActor in self?.interaction.updateTranscript(text) }
        }
    }

    private func finishGlobalDictation() async {
        speechTranscriber.stop()
        interaction.finishDictation()
        let finalizedPrompt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalizedPrompt.isEmpty, let turn = await conversationSession.appendUser(finalizedPrompt) {
            await memory.conversationDidChange()
            memory.storeExplicitRememberRequest(prompt: finalizedPrompt, evidenceMessageID: turn.id)
        }
        automaticRevealIsWaitingForNotchVisit = true
        if let screen {
            resize(to: expandedSize(for: screen), animated: true)
        }
        startResponseIfPossible()
    }

    private func startResponseIfPossible() {
        let prompt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, modelDownloadViewModel.activeModel != nil else { return }
        responseTask?.cancel()
        let generation = UUID()
        responseGeneration = generation
        responseSpeechCursor = StreamedSpeechCursor()
        responseTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, responseGeneration == generation else { return }
            if let identityAnswer = NexAssistantIdentityIntent.answer(for: prompt) {
                responseSpeaker.beginStreaming()
                responseIsStreaming = true
                _ = responseSpeechCursor.consume(delta: identityAnswer, accumulated: identityAnswer)
                interaction.receiveAnswer(identityAnswer)
                await conversationSession.appendAssistant(identityAnswer)
                await memory.conversationDidChange()
                responseSpeaker.append(identityAnswer)
                responseSpeaker.finishStreaming()
                responseIsStreaming = false
                automaticRevealIsWaitingForNotchVisit = true
                if let screen { resize(to: expandedSize(for: screen), animated: true) }
                return
            }
            let acknowledgement = PromptAcknowledgement.text(for: prompt, avoiding: previousThinkingPhrase)
            previousThinkingPhrase = acknowledgement
            responseSpeaker.beginStreaming()
            responseIsStreaming = true
            interaction.acknowledge(acknowledgement)
            if let screen { resize(to: expandedSize(for: screen), animated: true) }
            await responseSpeaker.speakImmediatelyAndWait(acknowledgement)
            guard !Task.isCancelled, responseGeneration == generation else { return }
            do {
                if let compound = NexCompoundMemoryQuery.split(prompt) {
                    // Answer the independent portion first, then visibly check
                    // memory and stream the personal-history portion as a
                    // second segment. This avoids one long silent retrieval.
                    interaction.beginThinking()
                    if let screen { resize(to: listeningSize(for: screen), animated: true) }
                    var immediateMessages = await conversationSession.contextMessages()
                    immediateMessages.append(.init(
                        role: "system",
                        content: "For this first response segment, answer only this independent question: \(compound.immediateQuestion). Do not answer the memory-dependent part yet."
                    ))
                    let immediateAnswer = try await streamModelResponse(
                        messages: immediateMessages,
                        generation: generation
                    )
                    let immediateDelta = responseSpeechCursor.consume(delta: "", accumulated: immediateAnswer)
                    if !immediateDelta.isEmpty { responseSpeaker.append(immediateDelta) }
                    let immediateRenderedAnswer = responseSpeechCursor.text
                    try? await Task.sleep(for: .milliseconds(180))

                    let retrievedContext = await retrieveMemoryContext(
                        prompt: compound.memoryQuestion,
                        generation: generation
                    )
                    guard !Task.isCancelled, responseGeneration == generation else { return }
                    interaction.beginThinking()
                    if let screen { resize(to: listeningSize(for: screen), animated: true) }
                    responseSpeechCursor.beginSegment()
                    var memoryMessages = await conversationSession.contextMessages(retrievedContext: retrievedContext)
                    memoryMessages.append(.init(role: "assistant", content: immediateRenderedAnswer))
                    memoryMessages.append(.init(
                        role: "system",
                        content: "Continue without repeating the first segment. Answer only this memory-dependent question using stored evidence when available: \(compound.memoryQuestion). If no evidence was retrieved, say that clearly."
                    ))
                    let memoryAnswer = try await streamModelResponse(messages: memoryMessages, generation: generation)
                    let finalDelta = responseSpeechCursor.consume(delta: "", accumulated: memoryAnswer)
                    if !finalDelta.isEmpty { responseSpeaker.append(finalDelta) }
                } else {
                    let retrievedContext = await retrieveMemoryContext(prompt: prompt, generation: generation)
                    guard !Task.isCancelled, responseGeneration == generation else { return }
                    interaction.beginThinking()
                    if let screen { resize(to: listeningSize(for: screen), animated: true) }
                    let messages = await conversationSession.contextMessages(retrievedContext: retrievedContext)
                    let answer = try await streamModelResponse(messages: messages, generation: generation)
                    let finalSpeechDelta = responseSpeechCursor.consume(delta: "", accumulated: answer)
                    if !finalSpeechDelta.isEmpty { responseSpeaker.append(finalSpeechDelta) }
                }
                guard !Task.isCancelled, responseGeneration == generation else { return }
                let reveal = !suppressAutomaticResponseReveal
                interaction.receiveAnswer(responseSpeechCursor.text, reveal: reveal)
                await conversationSession.appendAssistant(responseSpeechCursor.text)
                await memory.conversationDidChange()
                responseIsStreaming = false
                automaticRevealIsWaitingForNotchVisit = reveal
                if reveal, let screen { resize(to: expandedSize(for: screen), animated: true) }
                responseSpeaker.finishStreaming()
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
            }
        }
    }

    private func retrieveMemoryContext(prompt: String, generation: UUID) async -> String? {
        do {
            return try await memory.retrievalContext(for: prompt)
        } catch {
            guard !Task.isCancelled, responseGeneration == generation else { return nil }
            // Preserve the failed indicator long enough to be legible, then
            // continue honestly without retrieved evidence.
            try? await Task.sleep(for: .milliseconds(650))
            return nil
        }
    }

    private func streamModelResponse(
        messages: [NexusChatMessage],
        generation: UUID
    ) async throws -> String {
        try await modelDownloadViewModel.response(messages: messages) { [weak self] delta, accumulated in
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
        automaticRevealIsWaitingForNotchVisit = false
        suppressAutomaticResponseReveal = false
        interaction.dismiss()
        if let screen { resize(to: closedSize(for: screen), animated: true) }
    }

    private func quickDismiss() {
        guard isListening || isExpanded || isThinking || isUsingTool else { return }
        closeTask?.cancel()
        automaticRevealIsWaitingForNotchVisit = false
        suppressAutomaticResponseReveal = true

        if isListening {
            speechTranscriber.stop()
            interaction.dismiss()
            if let screen { resize(to: closedSize(for: screen), animated: true) }
        } else if isExpanded {
            collapse()
        } else {
            interaction.dismiss()
            if let screen { resize(to: closedSize(for: screen), animated: true) }
        }
    }

    /// Entry point for the future tool router. It is intentionally not called
    /// by ordinary prompts yet; when tool execution is added, this keeps UI and
    /// voice status synchronized through the same activity object.
    func beginToolActivity(_ activity: ToolActivity) {
        interaction.beginToolActivity(activity)
        if let screen { resize(to: toolActivitySize(for: screen), animated: true) }
        responseSpeaker.speakImmediately(activity.spokenStatus)
    }

    func finishToolActivity() {
        interaction.beginThinking()
        if let screen { resize(to: listeningSize(for: screen), animated: true) }
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
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Models"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ModelAggregatorView(viewModel: modelDownloadViewModel))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        modelPanel = panel
    }

    func shutdown() {
        speechTranscriber.stop()
        responseTask?.cancel()
        responseSpeaker.stop()
        toolEventTask?.cancel()
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

    private func handleToolEvent(_ event: NexToolLifecycleEvent) {
        switch event.phase {
        case .started, .progress:
            interaction.beginToolActivity(.lifecycle(event))
            if let screen { resize(to: toolActivitySize(for: screen), animated: true) }
        case .completed:
            interaction.beginThinking()
            if let screen { resize(to: listeningSize(for: screen), animated: true) }
        case .failed:
            interaction.beginToolActivity(.lifecycle(event))
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
            expand()
        } else {
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
        interaction.hideOverlay()
        resize(to: closedSize(for: screen), animated: true)
    }

    private func resize(to size: CGSize, animated: Bool) {
        guard let panel, let screen else { return }
        let requestedSizeChanged = abs(currentSize.width - size.width) > 0.5
            || abs(currentSize.height - size.height) > 0.5
        let targetFrame = frame(for: size, on: screen)
        let frameChanged = abs(panel.frame.minX - targetFrame.minX) > 0.5
            || abs(panel.frame.minY - targetFrame.minY) > 0.5
            || abs(panel.frame.width - targetFrame.width) > 0.5
            || abs(panel.frame.height - targetFrame.height) > 0.5
        currentSize = size
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

    private func expandedSize(for screen: NSScreen) -> CGSize {
        CGSize(width: min(680, screen.frame.width * 0.5), height: 245)
    }

    private func listeningSize(for screen: NSScreen) -> CGSize {
        NotchGeometry.listeningSize(for: closedSize(for: screen))
    }

    private func toolActivitySize(for screen: NSScreen) -> CGSize {
        CGSize(width: min(500, screen.frame.width * 0.42), height: 82)
    }

    private func frame(for size: CGSize, on screen: NSScreen) -> NSRect {
        NotchGeometry.centeredTopFrame(for: size, on: screen.frame)
    }

    @objc private func displayConfigurationChanged() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        self.screen = screen
        let size: CGSize = switch interaction.presentation {
        case .idle: closedSize(for: screen)
        case .dictating: listeningSize(for: screen)
        case .thinking: listeningSize(for: screen)
        case .tool: toolActivitySize(for: screen)
        case .overlay: expandedSize(for: screen)
        }
        resize(to: size, animated: false)
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
}
