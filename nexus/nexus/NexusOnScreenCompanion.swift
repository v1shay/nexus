import AppKit
import ScreenCaptureKit
import SwiftUI

/// Experimental visual guidance inspired by Clicky's interaction model, but
/// implemented against Nexus's own ScreenCaptureKit and model stack. The
/// currently selected Nexus pet follows the cursor, travels to a found target,
/// then returns. It is click-through only: no click, drag, keyboard, or
/// drawing input is ever synthesized from a model result.
@MainActor
final class NexusOnScreenCompanion: ObservableObject {
    static let shared = NexusOnScreenCompanion()

    private let state = NexusOnScreenOverlayState()
    private var windows: [CGDirectDisplayID: NexusOnScreenOverlayWindow] = [:]
    private var expiryTask: Task<Void, Never>?
    private var cursorTimer: Timer?

    private init() {}

    func reconcile(enabled: Bool, tint: NexusOnScreenTint = .cyan, bubbleEnabled: Bool = true) {
        state.tint = tint
        state.bubbleEnabled = bubbleEnabled
        if !bubbleEnabled { state.bubbleText = nil }
        guard enabled else {
            hide()
            return
        }
        rebuildWindowsIfNeeded()
        startCursorTrackingIfNeeded()
        windows.values.forEach { $0.orderFrontRegardless() }
    }

    func point(at screenPoint: CGPoint, on frame: CGRect, label: String) {
        rebuildWindowsIfNeeded()
        state.target = .init(point: screenPoint, frame: frame, label: label)
        state.targetCursorOrigin = NSEvent.mouseLocation
        state.activity = .tool
        startCursorTrackingIfNeeded()
        windows.values.forEach { $0.orderFrontRegardless() }
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.clearTarget()
        }
    }

    /// The notch and companion share these activity names. The companion
    /// stays visual-only; this never starts recording or speech.
    func setActivity(_ activity: NexusPetActivity) {
        state.activity = activity
    }

    /// Displays only user-visible, concise text beside the companion. The
    /// caller must never pass hidden model reasoning or planning content.
    func setBubble(_ text: String?) {
        guard state.bubbleEnabled else {
            state.bubbleText = nil
            return
        }
        state.bubbleText = Self.normalizedBubbleText(text)
    }

    nonisolated static func normalizedBubbleText(_ text: String?) -> String? {
        let normalized = (text ?? "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : String(normalized.suffix(280))
    }

    func hide() {
        expiryTask?.cancel()
        expiryTask = nil
        clearTarget()
        cursorTimer?.invalidate()
        cursorTimer = nil
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func clearTarget() {
        state.target = nil
        state.targetCursorOrigin = nil
        if state.activity == .tool { state.activity = .idle }
    }

    private func startCursorTrackingIfNeeded() {
        guard cursorTimer == nil else { return }
        state.cursorLocation = NSEvent.mouseLocation
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let cursor = NSEvent.mouseLocation
            self.state.cursorLocation = cursor
            // A target is momentary guidance, never a mode that traps the pet
            // away from the pointer. Moving the mouse intentionally returns it.
            if let origin = self.state.targetCursorOrigin,
               self.state.target != nil,
               hypot(cursor.x - origin.x, cursor.y - origin.y) > 16 {
                self.expiryTask?.cancel()
                self.expiryTask = nil
                self.clearTarget()
            }
        }
        cursorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func rebuildWindowsIfNeeded() {
        let screens = NSScreen.screens
        let screenIDs = Set(screens.compactMap(Self.displayID(for:)))
        for (id, window) in windows where !screenIDs.contains(id) {
            window.orderOut(nil)
            windows.removeValue(forKey: id)
        }
        for screen in screens {
            guard let id = Self.displayID(for: screen), windows[id] == nil else { continue }
            windows[id] = NexusOnScreenOverlayWindow(screen: screen, state: state)
        }
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

@MainActor
private final class NexusOnScreenOverlayState: ObservableObject {
    struct Target: Equatable {
        let point: CGPoint
        let frame: CGRect
        let label: String
    }

    @Published var target: Target?
    @Published var cursorLocation = NSEvent.mouseLocation
    @Published var activity: NexusPetActivity = .idle
    @Published var tint: NexusOnScreenTint = .cyan
    @Published var bubbleText: String?
    @Published var bubbleEnabled = true
    var targetCursorOrigin: CGPoint?
}

private final class NexusOnScreenOverlayWindow: NSWindow {
    init(screen: NSScreen, state: NexusOnScreenOverlayState) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: NexusOnScreenOverlayView(screenFrame: screen.frame, state: state))
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct NexusOnScreenOverlayView: View {
    let screenFrame: CGRect
    @ObservedObject var state: NexusOnScreenOverlayState

    var body: some View {
        ZStack {
            Color.clear

            // This is one pet, not a cursor plus a target marker. Switching
            // `state.target` changes its position, and SwiftUI carries the
            // selected animated pet from the cursor to the destination.
            let target = state.target.flatMap { $0.frame == screenFrame ? $0 : nil }
            let destination = target.map { localPosition(for: $0.point) }
                ?? localPosition(for: state.cursorLocation, offset: .init(width: 24, height: 28))
            NexusOnScreenAnimatedPet(
                pet: selectedPet,
                activity: target == nil ? state.activity : .tool,
                height: target == nil ? 38 : 66
            )
            .shadow(color: state.tint.color.opacity(target == nil ? 0.32 : 0.64), radius: target == nil ? 4 : 13)
            .position(destination)
            .opacity(target == nil && !screenFrame.contains(state.cursorLocation) ? 0 : 1)
            .animation(.interpolatingSpring(stiffness: 170, damping: 17), value: state.target)
            .animation(.easeOut(duration: 0.10), value: state.cursorLocation)

            if let target {
                Text(target.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(state.tint.color.opacity(0.38))
                            }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(state.tint.color.opacity(0.68), lineWidth: 1)
                    }
                    .frame(width: 220)
                    .position(x: destination.x, y: max(34, destination.y - 54))
                .transition(.opacity.combined(with: .scale(scale: 0.82)))
            }

            if let bubble = state.bubbleText,
               state.bubbleEnabled,
               target != nil || (state.target == nil && screenFrame.contains(state.cursorLocation)) {
                CompanionBubble(text: bubble, tint: state.tint.color)
                    .frame(width: min(292, max(188, screenFrame.width * 0.36)))
                    .position(bubblePosition(near: destination, targeting: target != nil))
                    .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .bottomLeading)))
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: state.target)
    }

    private func localPosition(for global: CGPoint, offset: CGSize = .zero) -> CGPoint {
        .init(
            x: global.x - screenFrame.minX + offset.width,
            y: screenFrame.height - (global.y - screenFrame.minY) + offset.height
        )
    }

    private func bubblePosition(near pet: CGPoint, targeting: Bool) -> CGPoint {
        let width = min(292, max(188, screenFrame.width * 0.36))
        let x = min(screenFrame.width - width / 2 - 12, max(width / 2 + 12, pet.x + width / 2 + 24))
        let y = min(screenFrame.height - 42, max(42, pet.y + (targeting ? 62 : -36)))
        return .init(x: x, y: y)
    }

    private var selectedPet: NexusPet {
        NexusPetCatalog.pet(withID: UserDefaults.standard.string(forKey: "nexus.selectedPetID"))
    }
}

/// A deliberately small, translucent caption rather than a second chat UI.
/// It inherits the user-selected tint and is always click-through with the
/// overlay. The visible content is bounded by the companion controller.
private struct CompanionBubble: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.96))
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(tint.opacity(0.20))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(tint.opacity(0.72), lineWidth: 1)
            }
            .shadow(color: tint.opacity(0.20), radius: 11, y: 4)
    }
}

/// Sprite-sheet pets provide distinct rows for each state. This wrapper adds
/// a small, state-specific motion layer so the bundled animated-GIF pet is
/// equally legible as idle, listening, thinking, and speaking.
private struct NexusOnScreenAnimatedPet: View {
    let pet: NexusPet
    let activity: NexusPetActivity
    let height: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            NexusPetView(pet: pet, activity: activity, height: height)
                .scaleEffect(scale(at: seconds))
                .offset(y: verticalOffset(at: seconds))
                .rotationEffect(.degrees(rotation(at: seconds)))
        }
        .frame(width: height * (192 / 208), height: height)
    }

    private func scale(at seconds: TimeInterval) -> CGFloat {
        switch activity {
        case .idle: 1 + CGFloat(sin(seconds * 2.2)) * 0.025
        case .dictating: 1 + CGFloat(sin(seconds * 7.4)) * 0.055
        case .thinking: 1 + CGFloat(sin(seconds * 4.6)) * 0.035
        case .speaking: 1 + CGFloat(sin(seconds * 10.2)) * 0.075
        case .overlay: 1
        case .tool: 1 + CGFloat(sin(seconds * 5.8)) * 0.045
        }
    }

    private func verticalOffset(at seconds: TimeInterval) -> CGFloat {
        switch activity {
        case .idle: CGFloat(sin(seconds * 1.8)) * 1.5
        case .dictating: CGFloat(sin(seconds * 6.2)) * 2.0
        case .thinking: CGFloat(sin(seconds * 3.6)) * 2.6
        case .speaking: CGFloat(abs(sin(seconds * 9.5))) * -3.3
        case .overlay: 0
        case .tool: CGFloat(sin(seconds * 5.2)) * 2.2
        }
    }

    private func rotation(at seconds: TimeInterval) -> Double {
        switch activity {
        case .thinking: Double(sin(seconds * 2.4)) * 2.2
        case .speaking: Double(sin(seconds * 8.2)) * 1.5
        case .tool: Double(sin(seconds * 4.0)) * 1.2
        case .idle, .dictating, .overlay: 0
        }
    }
}

@MainActor
enum NexusOnScreenLocator {
    private struct Capture {
        let imageBase64: String
        let width: Int
        let height: Int
        let frame: CGRect
    }

    static func requestNeedsVisualPointing(_ prompt: String) -> Bool {
        let normalized = prompt.lowercased()
        let phrases = ["point", "show me", "where is", "where's", "which button", "which icon", "highlight", "on my screen", "on screen"]
        return phrases.contains { normalized.contains($0) }
    }

    static func locate(
        for prompt: String,
        models: ModelDownloadViewModel
    ) async -> (point: CGPoint, frame: CGRect, label: String)? {
        guard models.activeModelSupportsImageInput,
              NexusPermissionCoordinator.shared.isVerified(.screenRecording),
              let capture = await captureCursorDisplay() else { return nil }

        let request = [
            NexusChatMessage(role: "system", content: """
            You are Nexus's visual pointer. Inspect the attached current-screen image and locate one visible user-interface element requested by the user. Return exactly compact JSON and no markdown:
            {"found":true,"x":123,"y":456,"label":"short visible target label"}
            Coordinates must be pixels in the supplied image, with 0,0 at its upper-left. If the requested target is not visible or is ambiguous, return {"found":false}. This is visual guidance only: never claim that an action was performed.
            """),
            NexusChatMessage(
                role: "user",
                content: "User request: \(prompt)\nImage size: \(capture.width)x\(capture.height).",
                imageBase64: capture.imageBase64,
                imageMediaType: "image/jpeg"
            )
        ]

        do {
            let raw = try await models.response(
                messages: request,
                temperature: 0,
                maximumTokens: 140,
                includeNexusSystemPrompt: false,
                onDelta: { _, _ in }
            )
            guard let payload = parse(raw), payload.found else { return nil }
            let x = min(max(0, payload.x), Double(capture.width))
            let y = min(max(0, payload.y), Double(capture.height))
            let mapped = CGPoint(
                x: capture.frame.minX + (x / Double(capture.width)) * capture.frame.width,
                y: capture.frame.minY + capture.frame.height - (y / Double(capture.height)) * capture.frame.height
            )
            return (mapped, capture.frame, payload.label.isEmpty ? "Here" : payload.label)
        } catch {
            NexusDiagnostics.record("[Nexus On-screen] visual pointer failed: \(error.localizedDescription)")
            return nil
        }
    }

    private struct PointerResult: Decodable {
        let found: Bool
        let x: Double
        let y: Double
        let label: String

        init(found: Bool, x: Double = 0, y: Double = 0, label: String = "") {
            self.found = found
            self.x = x
            self.y = y
            self.label = label
        }
    }

    private static func parse(_ raw: String) -> PointerResult? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PointerResult.self, from: data)
    }

    private static func captureCursorDisplay() async -> Capture? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let cursor = NSEvent.mouseLocation
            let screenByID = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                NexusOnScreenCompanion.displayID(for: screen).map { ($0, screen) }
            })
            guard let display = content.displays.first(where: { display in
                (screenByID[display.displayID]?.frame ?? display.frame).contains(cursor)
            }) ?? content.displays.first,
            let screen = screenByID[display.displayID] else { return nil }

            let ownWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let configuration = SCStreamConfiguration()
            let longest = max(display.width, display.height)
            let scale = min(1.0, 1_280.0 / CGFloat(max(1, longest)))
            configuration.width = max(1, Int(CGFloat(display.width) * scale))
            configuration.height = max(1, Int(CGFloat(display.height) * scale))
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let jpeg = NSBitmapImageRep(cgImage: image).representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.78]
            ) else { return nil }
            return .init(
                imageBase64: jpeg.base64EncodedString(),
                width: image.width,
                height: image.height,
                frame: screen.frame
            )
        } catch {
            NexusDiagnostics.record("[Nexus On-screen] ScreenCaptureKit capture failed: \(error.localizedDescription)")
            return nil
        }
    }
}
