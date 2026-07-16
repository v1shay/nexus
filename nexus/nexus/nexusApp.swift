import SwiftUI
import AppKit
import Carbon.HIToolbox
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
    private let notch = NotchController()
    private var launchTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        launchTask = Task { @MainActor [weak self] in
            await Self.retireOlderInstances()
            guard !Task.isCancelled else { return }
            self?.notch.install()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchTask?.cancel()
        notch.shutdown()
    }

    /// Xcode can launch a new debug build while the previous accessory app is
    /// still alive. Retire the older process before creating any panel so two
    /// independent notch windows can never be visible together.
    private static func retireOlderInstances() async {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let olderInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != currentPID }

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
    private var globalHotKey: NexusGlobalHotKey?
    private var pointerMonitor: PointerProximityMonitor?
    private var modelPanel: NSPanel?
    private let speechTranscriber = SpeechTranscriber()
    private let modelDownloadViewModel = ModelDownloadViewModel()
    private var automaticRevealIsWaitingForNotchVisit = false
    private let responseSpeaker = ResponseSpeaker()
    private var responseTask: Task<Void, Never>?
    private var responseGeneration = UUID()
    private var hoverSession = NotchHoverSession()

    static let preview: NotchController = {
        let controller = NotchController()
        controller.interaction.beginDictation()
        return controller
    }()

    func install() {
        guard panel == nil else { return }
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
        installHotKeyMonitor()
        installPointerMonitor()
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

    /// Carbon hotkeys are delivered by macOS rather than by Nexus's focused
    /// window, which is what makes this work above every other application.
    private func installHotKeyMonitor() {
        let hotKey = NexusGlobalHotKey(
            onPress: { [weak self] in
                Task { @MainActor in self?.startGlobalDictation() }
            },
            onRelease: { [weak self] in
                Task { @MainActor in self?.finishGlobalDictation() }
            }
        )
        globalHotKey = hotKey
        guard !hotKey.install() else { return }

        // Xcode can briefly overlap a terminating debug process with its
        // replacement. Retry once after Carbon has released the old binding.
        Task { [weak self, weak hotKey] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, let hotKey, self.globalHotKey === hotKey else { return }
            _ = hotKey.install()
        }
    }

    private func startGlobalDictation() {
        closeTask?.cancel()
        responseTask?.cancel()
        responseGeneration = UUID()
        responseSpeaker.stop()
        interaction.beginDictation()
        if let screen {
            resize(to: listeningSize(for: screen), animated: true)
        }
        speechTranscriber.start { [weak self] text in
            Task { @MainActor in self?.interaction.updateTranscript(text) }
        }
    }

    private func finishGlobalDictation() {
        speechTranscriber.stop()
        interaction.finishDictation()
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
        responseTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, responseGeneration == generation else { return }
            let acknowledgement = PromptAcknowledgement.text(for: prompt)
            responseSpeaker.beginStreaming()
            interaction.acknowledge(acknowledgement)
            if let screen { resize(to: expandedSize(for: screen), animated: true) }
            responseSpeaker.speakImmediately(acknowledgement)
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled, responseGeneration == generation else { return }
            interaction.beginThinking()
            if let screen { resize(to: listeningSize(for: screen), animated: true) }
            do {
                let answer = try await modelDownloadViewModel.response(to: prompt) { [weak self] delta, accumulated in
                    guard let self else { return }
                    await self.receiveResponseDelta(delta, accumulated: accumulated, generation: generation)
                }
                guard !Task.isCancelled, responseGeneration == generation else { return }
                interaction.receiveAnswer(answer)
                automaticRevealIsWaitingForNotchVisit = true
                if let screen { resize(to: expandedSize(for: screen), animated: true) }
                responseSpeaker.finishStreaming()
            } catch {
                guard !Task.isCancelled, responseGeneration == generation else { return }
                responseSpeaker.stop()
                interaction.failResponse("Nexus couldn’t get a response. \(error.localizedDescription)")
                automaticRevealIsWaitingForNotchVisit = true
                if let screen { resize(to: expandedSize(for: screen), animated: true) }
            }
        }
    }

    private func receiveResponseDelta(_ delta: String, accumulated: String, generation: UUID) {
        guard !Task.isCancelled, responseGeneration == generation else { return }
        interaction.receivePartialAnswer(accumulated)
        automaticRevealIsWaitingForNotchVisit = true
        if let screen { resize(to: expandedSize(for: screen), animated: true) }
        responseSpeaker.append(delta)
    }

    func toggleVoiceMute() {
        isVoiceMuted.toggle()
        responseSpeaker.setMuted(isVoiceMuted)
    }

    func dismissOverlay() {
        responseTask?.cancel()
        responseGeneration = UUID()
        responseSpeaker.stop()
        automaticRevealIsWaitingForNotchVisit = false
        interaction.dismiss()
        if let screen { resize(to: closedSize(for: screen), animated: true) }
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
        modelDownloadViewModel.shutdown()
    }

    private func updateHover(_ hovering: Bool) {
        closeTask?.cancel()
        if hovering {
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

private final class NexusGlobalHotKey {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    @discardableResult
    func install() -> Bool {
        if hotKey != nil { return true }
        let target = GetApplicationEventTarget()
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let handlerStatus = InstallEventHandler(
            target,
            nexusGlobalHotKeyHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            NSLog("Nexus could not install its global hotkey handler: %d", handlerStatus)
            eventHandler = nil
            return false
        }
        let identifier = EventHotKeyID(signature: 0x4E585553, id: 1) // "NXUS"
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | shiftKey),
            identifier,
            target,
            0,
            &hotKey
        )
        guard registrationStatus == noErr else {
            NSLog("Nexus could not register Command-Shift-Space: %d", registrationStatus)
            if let eventHandler { RemoveEventHandler(eventHandler) }
            eventHandler = nil
            hotKey = nil
            return false
        }
        NSLog("Nexus registered Command-Shift-Space")
        return true
    }

    fileprivate func handle(_ event: EventRef?) {
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed): onPress()
        case UInt32(kEventHotKeyReleased): onRelease()
        default: break
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

private let nexusGlobalHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let userData else { return noErr }
    let manager = Unmanaged<NexusGlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    manager.handle(event)
    return noErr
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
