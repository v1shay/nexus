import SwiftUI
import AppKit
import Carbon.HIToolbox

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        notch.install()
    }
}

@MainActor
final class NotchController: ObservableObject {
    @Published private(set) var isExpanded = false
    @Published private(set) var isListening = false
    @Published private(set) var isHoverPreview = false
    @Published private(set) var hasTranscript = false
    @Published private(set) var transcript = ""
    @Published private(set) var currentSize = CGSize(width: 190, height: 32)

    private var panel: NexusNotchPanel?
    private var screen: NSScreen?
    private var closeTask: Task<Void, Never>?
    private var globalHotKey: NexusGlobalHotKey?
    private var pointerMonitor: PointerProximityMonitor?
    private var modelPanel: NSPanel?

    static let preview: NotchController = {
        let controller = NotchController()
        controller.isListening = true
        return controller
    }()

    func install() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        self.screen = screen
        currentSize = closedSize(for: screen)

        let panel = NexusNotchPanel(
            contentRect: frame(for: currentSize, on: screen),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: ContentView().environmentObject(self))
        panel.orderFrontRegardless()
        self.panel = panel
        installHotKeyMonitor()
        installPointerMonitor()

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
        let isOverPanel = isExpanded && (panel?.frame.contains(location) ?? false)
        updateHover(isOverNotchZone || isOverPanel)
    }

    /// Carbon hotkeys are delivered by macOS rather than by Nexus's focused
    /// window, which is what makes this work above every other application.
    private func installHotKeyMonitor() {
        globalHotKey = NexusGlobalHotKey(
            onPress: { [weak self] in
                Task { @MainActor in self?.startGlobalDictation() }
            },
            onRelease: { [weak self] in
                Task { @MainActor in self?.finishGlobalDictation() }
            }
        )
        globalHotKey?.install()
    }

    private func startGlobalDictation() {
        closeTask?.cancel()
        isListening = true
        isHoverPreview = false
        hasTranscript = false
        transcript = ""
        if let screen {
            isExpanded = false
            resize(to: listeningSize(for: screen), animated: true)
        }
    }

    private func finishGlobalDictation() {
        isListening = false
        isHoverPreview = false
        hasTranscript = true
        if let screen {
            isExpanded = false
            resize(to: closedSize(for: screen), animated: true)
        }
    }

    func toggleListening() {
        closeTask?.cancel()
        isListening.toggle()
        if isListening {
            isHoverPreview = false
            hasTranscript = false
            transcript = ""
            if let screen {
                isExpanded = false
                resize(to: listeningSize(for: screen), animated: true)
            }
        } else {
            hasTranscript = true
            if let screen {
                isExpanded = false
                resize(to: closedSize(for: screen), animated: true)
            }
        }
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
        panel.contentView = NSHostingView(rootView: ModelAggregatorView())
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        modelPanel = panel
    }

    func updateHover(_ hovering: Bool) {
        closeTask?.cancel()
        if hovering {
            guard !isListening else { return }
            isHoverPreview = false
            expand()
        } else {
            guard !isListening else { return }
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
        isExpanded = true
        resize(to: size(screen), animated: true)
    }

    private func collapse() {
        guard isExpanded, let screen else { return }
        isExpanded = false
        isHoverPreview = false
        resize(to: closedSize(for: screen), animated: true)
    }

    private func resize(to size: CGSize, animated: Bool) {
        guard let panel, let screen else { return }
        currentSize = size
        let targetFrame = frame(for: size, on: screen)
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
        let notch = closedSize(for: screen)
        return CGSize(width: notch.width + 124, height: notch.height + 10)
    }

    private func frame(for size: CGSize, on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    @objc private func displayConfigurationChanged() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        self.screen = screen
        let size = isListening
            ? listeningSize(for: screen)
            : (isExpanded ? expandedSize(for: screen) : closedSize(for: screen))
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

    func install() {
        let target = GetApplicationEventTarget()
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(
            target,
            nexusGlobalHotKeyHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        let identifier = EventHotKeyID(signature: 0x4E585553, id: 1) // "NXUS"
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | shiftKey),
            identifier,
            target,
            0,
            &hotKey
        )
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
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(onMove: @escaping (NSPoint) -> Void) {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { _ in
            onMove(NSEvent.mouseLocation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { event in
            onMove(NSEvent.mouseLocation)
            return event
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
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
