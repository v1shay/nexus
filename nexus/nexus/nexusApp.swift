import SwiftUI
import AppKit

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
    @Published private(set) var currentSize = CGSize(width: 190, height: 32)

    private var panel: NexusNotchPanel?
    private var screen: NSScreen?
    private var closeTask: Task<Void, Never>?
    private var hotKeyMonitor: Any?
    private var localKeyMonitor: Any?

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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// ⌥Space starts/stops the voice session. The global monitor handles it
    /// outside Nexus when macOS Accessibility permission is granted.
    private func installHotKeyMonitor() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 49, event.modifierFlags.contains(.option) else { return }
            Task { @MainActor in self?.toggleListening() }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
    }

    func toggleListening() {
        closeTask?.cancel()
        isListening.toggle()
        if !isListening { collapse() }
    }

    func updateHover(_ hovering: Bool) {
        closeTask?.cancel()
        if hovering {
            expand()
        } else {
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.collapse()
            }
        }
    }

    private func expand() {
        guard !isExpanded, let screen else { return }
        isExpanded = true
        resize(to: expandedSize(for: screen), animated: true)
    }

    private func collapse() {
        guard isExpanded, let screen else { return }
        isExpanded = false
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
        CGSize(width: min(620, screen.frame.width * 0.46), height: 210)
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
        resize(to: isExpanded ? expandedSize(for: screen) : closedSize(for: screen), animated: false)
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
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
