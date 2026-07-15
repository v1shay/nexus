import SwiftUI
import AppKit

@main
struct NexusApp: App {
    @StateObject private var appState = NexusAppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .background(WindowReader { window in
                    appState.attach(window)
                })
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 218, height: 62)
        .commands {
            CommandMenu("Nexus") {
                Button("Toggle Overlay") { appState.toggleOverlay() }
                    .keyboardShortcut(.space, modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class NexusAppState: ObservableObject {
    @Published private(set) var isExpanded = false
    private weak var window: NSWindow?

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        positionWindow(animated: false)
    }

    func toggleOverlay() {
        isExpanded.toggle()
        positionWindow(animated: true)
    }

    private func positionWindow(animated: Bool) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let size = isExpanded ? NSSize(width: 770, height: 390) : NSSize(width: 218, height: 62)
        let frame = screen.visibleFrame
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height + 4)
        let apply = { window.setFrame(NSRect(origin: origin, size: size), display: true) }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(NSRect(origin: origin, size: size), display: true)
            }
        } else {
            apply()
        }
    }
}

private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { onResolve(window) }
        }
    }
}
