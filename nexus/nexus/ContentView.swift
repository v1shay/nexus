import AppKit
import Combine
import IOKit.ps
import SwiftUI

/// The panel is visually indistinguishable from the physical cutout at rest.
/// Interaction state is supplied by the AppKit controller above the view.
struct ContentView: View {
    @EnvironmentObject private var notch: NotchController

    var body: some View {
        ZStack(alignment: .top) {
            if notch.isUsingTool, let activity = notch.toolActivity {
                ToolActivityIndicator(activity: activity)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            } else if notch.isListening || notch.isThinking {
                ListeningWings(isThinking: notch.isThinking)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            } else {
                AdaptiveNotchGlass(isExpanded: notch.isExpanded)

                if notch.isExpanded {
                    TranscriptContents()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        // The hosting view already tracks the animated NSPanel frame. Giving
        // this view the final width early makes AppKit clip it from one side,
        // which visually turns a centered expansion into a corner slide.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18), value: notch.isListening)
        .animation(.easeInOut(duration: 0.22), value: notch.presentation)
    }
}

private struct ToolActivityIndicator: View {
    @EnvironmentObject private var notch: NotchController
    let activity: ToolActivity

    var body: some View {
        ZStack(alignment: .top) {
            NotchSurface(cornerRadius: 18).fill(.black)
            HStack(spacing: 0) {
                NexusPetView(pet: notch.selectedPet, activity: .tool, height: 31)
                    .frame(width: NotchGeometry.wingWidth)
                Color.clear.frame(maxWidth: .infinity)
                AnimatedToolIcon(source: activity.icon, isFailure: activity.phase == .failed)
                    .frame(width: NotchGeometry.wingWidth)
            }
            .frame(height: 34)

            ShimmeringStatusText(text: activity.status, isFailure: activity.phase == .failed)
                .padding(.horizontal, 24)
                .padding(.top, 45)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(activity.toolName). \(activity.status)")
    }
}

private struct AnimatedToolIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: ToolIconSource
    let isFailure: Bool

    @ViewBuilder
    var body: some View {
        if reduceMotion || isFailure {
            ToolIconView(source: source)
                .foregroundStyle(isFailure ? .red.opacity(0.9) : .white.opacity(0.82))
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.8) / 1.8
                let glow = (sin(phase * .pi * 2) + 1) / 2
                ToolIconView(source: source)
                    .foregroundStyle(.white.opacity(0.6 + glow * 0.4))
                    .shadow(color: .cyan.opacity(glow * 0.8), radius: 4 + glow * 4)
                    .scaleEffect(0.96 + glow * 0.04)
            }
        }
    }
}

private struct ToolIconView: View {
    let source: ToolIconSource
    var size: CGFloat = 24

    var body: some View {
        Group {
            switch source {
            case .systemSymbol(let name):
                Image(systemName: name).resizable().scaledToFit()
            case .asset(let name, let fallback):
                if let image = NSImage(named: NSImage.Name(name)) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: fallback).resizable().scaledToFit()
                }
            case .svg(let data, let fallback):
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: fallback).resizable().scaledToFit()
                }
            }
        }
        .frame(width: size, height: size)
    }
}

private struct ShimmeringStatusText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let isFailure: Bool

    @ViewBuilder
    var body: some View {
        if reduceMotion || isFailure {
            Text(text)
                .foregroundStyle(isFailure ? .red.opacity(0.9) : .white.opacity(0.78))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.8) / 1.8
                ZStack {
                    Text(text).foregroundStyle(.white.opacity(0.42))
                    LinearGradient(
                        colors: [.clear, .cyan.opacity(0.7), .white, .cyan.opacity(0.7), .clear],
                        startPoint: UnitPoint(x: phase - 0.38, y: 0.5),
                        endPoint: UnitPoint(x: phase + 0.38, y: 0.5)
                    )
                    .mask(Text(text))
                    .shadow(color: .cyan.opacity(0.65), radius: 7)
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct AdaptiveNotchGlass: View {
    let isExpanded: Bool

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            NativeLiquidGlassNotch(isExpanded: isExpanded)
        } else {
            LegacyNotchGlass(isExpanded: isExpanded)
        }
        #else
        LegacyNotchGlass(isExpanded: isExpanded)
        #endif
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private struct NativeLiquidGlassNotch: View {
    let isExpanded: Bool

    var body: some View {
        let shape = NotchSurface(cornerRadius: isExpanded ? 29 : 10)
        shape
            .fill(.black.opacity(isExpanded ? 0.56 : 1))
            .glassEffect(
                .regular.tint(.black.opacity(isExpanded ? 0.42 : 0.72)).interactive(isExpanded),
                in: shape
            )
            .overlay {
                shape.stroke(.white.opacity(isExpanded ? 0.22 : 0), lineWidth: 0.8)
            }
    }
}
#endif

private struct LegacyNotchGlass: View {
    let isExpanded: Bool

    var body: some View {
        let shape = NotchSurface(cornerRadius: isExpanded ? 29 : 10)
        shape
            .fill(.black.opacity(isExpanded ? 0.82 : 1))
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                shape.stroke(.white.opacity(isExpanded ? 0.18 : 0), lineWidth: 0.8)
            }
    }
}

private struct ListeningWings: View {
    @EnvironmentObject private var notch: NotchController
    let isThinking: Bool
    private let wingWidth = NotchGeometry.wingWidth

    var body: some View {
        ZStack {
            NotchSurface(cornerRadius: 13)
                .fill(.black)

            HStack(spacing: 0) {
                NexusPetView(
                    pet: notch.selectedPet,
                    activity: isThinking ? .thinking : .dictating,
                    height: 31
                )
                    .frame(width: wingWidth)

                Color.clear
                    .frame(maxWidth: .infinity)

                Group {
                    if isThinking { ThinkingIndicator() } else { DictationBars() }
                }
                .frame(width: wingWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isThinking ? "Nexus is thinking" : "Nexus is dictating")
    }
}

private struct TranscriptContents: View {
    @EnvironmentObject private var notch: NotchController
    private static let responseBottomID = "nex-response-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                InteractiveNexusPet(
                    pet: notch.selectedPet,
                    height: 44,
                    isMuted: notch.isVoiceMuted,
                    mute: notch.toggleVoiceMute,
                    cycle: notch.cyclePet,
                    close: notch.dismissOverlay
                )
                Button { notch.saveConversation() } label: {
                    Label(notch.memory.saveState.label, systemImage: notch.memory.saveState.systemImage)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(.white.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(saveButtonColor)
                .disabled(notch.memory.saveState == .saving || notch.memory.saveState == .saved)
                .help(saveHelp)
                Spacer()
                HStack(spacing: 7) {
                    Button { notch.openSavedChats() } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.09), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.72))
                    .help("Saved conversations · \(notch.memory.syncState.label)")

                    BatteryPercentageView()

                    Button { notch.openModelAggregator() } label: {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background(.white.opacity(0.09), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.72))
                    .help("Models")
                }
            }

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(notch.transcript)
                            .font(.system(size: notch.answer.isEmpty ? 25 : 17, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(notch.answer.isEmpty ? 0.96 : 0.62))
                            .textSelection(.enabled)

                        if !notch.answer.isEmpty {
                            Capsule()
                                .fill(.white.opacity(0.14))
                                .frame(height: 1)
                            if let receipt = notch.toolReceipt {
                                ToolUsageReceiptView(activity: receipt)
                            }
                            RichMarkdownView(markdown: notch.answer)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.responseBottomID)
                    }
                    .tracking(-0.2)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: notch.answer) { _, _ in
                    Task { @MainActor in
                        await Task.yield()
                        scrollProxy.scrollTo(Self.responseBottomID, anchor: .bottom)
                    }
                }
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 27)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    private var saveButtonColor: Color {
        switch notch.memory.saveState {
        case .saved: .green.opacity(0.9)
        case .failed: .red.opacity(0.9)
        default: .white.opacity(0.76)
        }
    }

    private var saveHelp: String {
        if case .failed(let message) = notch.memory.saveState { return message }
        return "Save this conversation to the iCloud-synced Obsidian vault"
    }
}

private struct ToolUsageReceiptView: View {
    let activity: ToolActivity
    @State private var showsSources = false

    @ViewBuilder
    var body: some View {
        if activity.sources.isEmpty {
            receiptLabel
        } else {
            Button { showsSources.toggle() } label: { receiptLabel }
                .buttonStyle(.plain)
                .popover(isPresented: $showsSources, arrowEdge: .top) {
                    ToolReceiptSourcesView(activity: activity)
                }
                .help("Show Obsidian sources")
        }
    }

    private var receiptLabel: some View {
        HStack(spacing: 7) {
            ToolIconView(source: activity.icon, size: 13)
            Text(activity.status)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(activity.phase == .failed ? .red.opacity(0.9) : .cyan.opacity(0.9))
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(.white.opacity(0.07), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(activity.status)
    }
}

private struct ToolReceiptSourcesView: View {
    let activity: ToolActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ToolIconView(source: activity.icon, size: 18)
                Text("Obsidian sources")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(activity.sources) { source in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(source.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text(source.excerpt)
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(5)
                            Text(source.sourceID)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(15)
        .frame(width: 380)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Obsidian sources used for this response")
    }
}

private struct BatteryPercentageView: View {
    @State private var percentage = BatteryStatusReader.currentPercentage()
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let percentage {
                Text("\(percentage)%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(.white.opacity(0.09), in: Capsule())
                    .accessibilityLabel("Battery \(percentage) percent")
            }
        }
        .onReceive(refreshTimer) { _ in
            percentage = BatteryStatusReader.currentPercentage()
        }
    }
}

enum BatteryStatusReader {
    static func currentPercentage() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  let percentage = percentage(current: current, maximum: maximum) else {
                continue
            }
            return percentage
        }
        return nil
    }

    static func percentage(current: Int, maximum: Int) -> Int? {
        guard maximum > 0 else { return nil }
        return min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
    }
}

private struct InteractiveNexusPet: View {
    let pet: NexusPet
    let height: CGFloat
    let isMuted: Bool
    let mute: () -> Void
    let cycle: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack {
            NexusPetView(pet: pet, activity: .overlay, height: height)
                .opacity(isMuted ? 0.55 : 1)
            if isMuted {
                Circle()
                    .fill(.black.opacity(0.66))
                    .frame(width: height * 0.54, height: height * 0.54)
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: height * 0.23, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: height * 192 / 208, height: height)
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { result in
                    switch result {
                    case .first: close()
                    case .second:
                        if CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) {
                            cycle()
                        } else {
                            mute()
                        }
                    }
                }
        )
        .help(
            isMuted
                ? "Click to unmute · Command-click to change pet · Double-click to close"
                : "Click to mute · Command-click to change pet · Double-click to close"
        )
        .accessibilityLabel("\(pet.displayName). \(isMuted ? "Nexus voice muted" : "Nexus voice active")")
    }
}

private struct ThinkingIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (sin(time * 5.2 - Double(index) * 1.25) + 1) / 2
                    Circle()
                        .fill(.white.opacity(0.45 + phase * 0.5))
                        .frame(width: 5 + phase * 2.5, height: 5 + phase * 2.5)
                        .offset(y: -phase * 3)
                }
            }
            .frame(height: 22)
        }
    }
}

private struct DictationBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.8) {
                ForEach(0..<4, id: \.self) { index in
                    let wave = (sin(time * 7.2 + Double(index) * 1.47) + 1) / 2
                    Capsule()
                        .fill(.white.opacity(0.97))
                        .frame(width: 3.7, height: 7 + wave * 18)
                }
            }
            .frame(height: 26)
        }
    }
}

/// A notch has square top edges (hidden in the menu bar) and rounds only at its bottom.
private struct NotchSurface: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, min(rect.width / 2, rect.height))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    ContentView().environmentObject(NotchController.preview)
}
