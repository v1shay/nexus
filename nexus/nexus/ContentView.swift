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
            if notch.isShowingMusic {
                MusicPlaybackIndicator()
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            } else if notch.isUsingTool, let activity = notch.toolActivity {
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

/// Local playback surface. Spotify supplies title and cover art through its
/// macOS scripting dictionary; browser video still gets the same real-time
/// audio-reactive orb without pretending that Nexus knows its title/artwork.
private struct MusicPlaybackIndicator: View {
    @EnvironmentObject private var notch: NotchController

    var body: some View {
        ZStack(alignment: .top) {
            NotchSurface(cornerRadius: 14).fill(.black)
            HStack(spacing: 0) {
                albumArt
                    .frame(width: 32, height: 32)

                Color.clear.frame(maxWidth: .infinity)

                NexusOrbAnimation(
                    mode: .music,
                    size: 30,
                    tint: notch.musicPalette.color,
                    energy: notch.musicEnergy
                )
                .frame(width: 32, height: 32)
            }
            .padding(.horizontal, 13)
            .frame(maxHeight: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notch.musicTrack.map { "Playing \($0.title) by \($0.artist)" } ?? "System audio is playing")
    }

    @ViewBuilder
    private var albumArt: some View {
        if let artwork = notch.musicArtwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(notch.musicPalette.color.opacity(0.24))
                .overlay {
                    brandMark
                }
        }
    }

    @ViewBuilder
    private var brandMark: some View {
        if let source = notch.musicBrowserSource {
            ToolIconView(source: .svg(data: source.svg, fallbackSystemName: "play.rectangle.fill"), size: 20)
        } else if notch.musicTrack != nil {
            ToolIconView(source: .svg(data: Self.spotifySVG, fallbackSystemName: "music.note"), size: 20)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(notch.musicPalette.color)
        }
    }

    private static let spotifySVG = Data("""
    <svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg">
      <circle cx="24" cy="24" r="22" fill="#1ed760"/>
      <path d="M12 19c9-3 18-2 25 2M13.5 25c7-2 15-1.4 21 1.5M15 30c5.6-1.5 11.4-1 16 1" fill="none" stroke="#07150d" stroke-width="3.2" stroke-linecap="round"/>
    </svg>
    """.utf8)
}

private struct ToolActivityIndicator: View {
    @EnvironmentObject private var notch: NotchController
    let activity: ToolActivity

    private var isCodex: Bool { activity.toolName == "Codex" }
    private var isNexCLI: Bool { activity.toolName == "Nex CLI" }
    private var liveLine: String { activity.detail ?? activity.status }

    var body: some View {
        ZStack(alignment: .top) {
            NotchSurface(cornerRadius: 18).fill(.black)
            HStack(spacing: 0) {
                Group {
                    if isCodex {
                        CodexSessionPicker(selectedSessionID: activity.codexSessionID)
                    } else if isNexCLI {
                        NexCLIActivityMark()
                    } else {
                        NexusPetView(pet: notch.selectedPet, activity: .tool, height: 31)
                    }
                }
                .frame(width: isCodex ? 96 : NotchGeometry.wingWidth)
                Color.clear.frame(maxWidth: .infinity)
                Group {
                    if isCodex, activity.phase == .completed {
                        CodexCompletionIndicator()
                    } else if isCodex, activity.codexKind == .thinking {
                        // Codex thinking deliberately uses Nex's existing
                        // three-dot motion rather than a separate SVG.
                        ThinkingIndicator()
                    } else {
                        AnimatedToolIcon(
                            source: activity.icon,
                            isFailure: activity.phase == .failed,
                            isCodex: isCodex
                        )
                    }
                }
                .frame(width: NotchGeometry.wingWidth)
            }
            // Keep both activity marks clear of the curved notch edges, and
            // align their visual centre with the space above the live line.
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .offset(y: 5)

            VStack(spacing: 5) {
                if activity.toolName == "Web Search", !activity.sources.isEmpty {
                    SearchResultTicker(sources: activity.sources)
                } else {
                    ShimmeringStatusText(
                        text: liveLine,
                        isFailure: activity.phase == .failed,
                        style: activity.toolName == "Web Search"
                            ? .google
                            : (activity.toolName == "Nex Memory" ? .obsidian : (isCodex ? .codex : .white))
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 43)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(activity.toolName). \(liveLine)")
    }
}

/// Compact worker mark: a small, high-contrast ASCII logo rather than a
/// second pet. Its neutral grey/white treatment shares the thinking shimmer.
private struct NexCLIActivityMark: View {
    var body: some View {
        Text("NEX")
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .tracking(-1.2)
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(.white.opacity(0.10), in: Capsule())
            .accessibilityLabel("Nex CLI")
    }
}

private struct CodexSessionPicker: View {
    @EnvironmentObject private var notch: NotchController
    let selectedSessionID: String?
    @State private var isUsagePopoverPresented = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isUsagePopoverPresented.toggle()
            } label: {
                CodexAvatarView()
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isUsagePopoverPresented, arrowEdge: .top) {
                CodexUsagePopover(usage: notch.codexUsageLimit)
            }
            .accessibilityLabel("Show Codex usage")

            if notch.codexSessions.count > 1 {
                HStack(spacing: 4) {
                    ForEach(Array(notch.codexSessions.prefix(2).enumerated()), id: \.element.id) { index, session in
                        Button {
                            notch.selectCodexSession(session.id)
                        } label: {
                            Text("\(index + 1)")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(session.id == selectedSessionID ? .white : .white.opacity(0.62))
                                .frame(width: 12, height: 12)
                                .background(session.id == selectedSessionID ? Color.blue.opacity(0.9) : Color.white.opacity(0.12))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show Codex task \(index + 1): \(session.title)")
                    }
                }
            }
        }
        .frame(width: 96, height: 29, alignment: .center)
    }
}

private struct CodexUsagePopover: View {
    let usage: CodexUsageLimit?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Codex usage")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            if let usage {
                Text("\(Int(usage.usedPercent.rounded()))% used")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)
                Text("Weekly limit · resets \(usage.resetsAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Text("Waiting for Codex’s next usage update.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 210, alignment: .leading)
    }
}

private struct CodexAvatarView: View {
    var body: some View {
        Group {
            if let image = NSImage(contentsOf: CodexProgressAssets.avatarURL) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right").resizable().scaledToFit()
            }
        }
        .frame(width: 25, height: 25)
        .clipShape(Circle())
        .shadow(color: .blue.opacity(0.9), radius: 6)
        .accessibilityLabel("Codex")
    }
}

private struct CodexCompletionIndicator: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.cyan.opacity(0.95), .blue.opacity(0.96), .indigo.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 22, height: 22)
                .shadow(color: .blue.opacity(0.8), radius: 6)
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Codex task complete")
    }
}

/// Keeps the live search view informative without reading or exposing URLs.
/// Titles arrive from the actual completed tool result, not fabricated UI data.
private struct SearchResultTicker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sources: [ToolReceiptSource]

    var body: some View {
        Group {
            if reduceMotion {
                sourceLine(index: 0)
            } else {
                TimelineView(.periodic(from: .now, by: 1.35)) { timeline in
                    let elapsed = max(0, timeline.date.timeIntervalSinceReferenceDate)
                    sourceLine(index: Int(elapsed / 1.35) % sources.count)
                        .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private func sourceLine(index: Int) -> some View {
        let source = sources[min(max(0, index), sources.count - 1)]
        HStack(spacing: 5) {
            Image(systemName: "newspaper")
                .font(.system(size: 9, weight: .semibold))
            Text(source.title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .foregroundStyle(.cyan.opacity(0.82))
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityLabel("Search result: \(source.title)")
    }
}

private struct AnimatedToolIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let source: ToolIconSource
    let isFailure: Bool
    var isCodex = false

    @ViewBuilder
    var body: some View {
        if reduceMotion || isFailure {
            if isCodex {
                codexIcon
            } else {
                ToolIconView(source: source)
                    .foregroundStyle(isFailure ? .red.opacity(0.9) : .white.opacity(0.82))
            }
        } else if isCodex {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.8) / 1.8
                let glow = (sin(phase * .pi * 2) + 1) / 2
                codexIcon
                    .shadow(color: .blue.opacity(glow * 0.9), radius: 4 + glow * 5)
                    .scaleEffect(0.96 + glow * 0.04)
            }
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

    private var codexIcon: some View {
        ZStack {
            ToolIconView(source: source).opacity(0.24)
            LinearGradient(
                colors: [.cyan.opacity(0.92), .blue, .indigo.opacity(0.94)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .mask(ToolIconView(source: source))
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

private enum StatusShimmerStyle {
    case white
    case google
    case obsidian
    case codex

    var colors: [Color] {
        switch self {
        case .white: [.clear, .white.opacity(0.88), .white, .white.opacity(0.88), .clear]
        case .google: [.clear, .red.opacity(0.9), .yellow.opacity(0.95), .green.opacity(0.92), .blue.opacity(0.95), .clear]
        case .obsidian: [.clear, .purple.opacity(0.7), .indigo.opacity(0.98), .purple.opacity(0.82), .clear]
        case .codex: [.clear, .cyan.opacity(0.78), .blue.opacity(0.98), .indigo.opacity(0.9), .cyan.opacity(0.78), .clear]
        }
    }
}

private struct ShimmeringStatusText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let isFailure: Bool
    var style: StatusShimmerStyle = .white

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
                        colors: style.colors,
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
        SimulatedGlassNotch(isExpanded: isExpanded)
    }
}

/// Clear custom glass that uses no macOS 26-only APIs.
private struct SimulatedGlassNotch: View {
    let isExpanded: Bool

    var body: some View {
        let shape = NotchSurface(cornerRadius: isExpanded ? 29 : 10)

        ZStack {
            // Closed: merges seamlessly with the physical camera housing.
            shape
                .fill(.black)
                .opacity(isExpanded ? 0 : 1)

            // Expanded: black at the top, then nearly transparent.
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            .black.opacity(0.94),
                            .black.opacity(0.62),
                            .black.opacity(0.20),
                            .black.opacity(0.035)
                        ],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.66)
                    )
                )
                .opacity(isExpanded ? 1 : 0)

            // Crisp specular edge, without blur or frosted material.
            shape
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.42),
                            .white.opacity(0.16),
                            .white.opacity(0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.85
                )
                .opacity(isExpanded ? 1 : 0)
        }
        .overlay {
            shape.stroke(.white.opacity(isExpanded ? 0.10 : 0), lineWidth: 2)
                .blur(radius: 1.2)
        }
        .shadow(color: .black.opacity(isExpanded ? 0.26 : 0), radius: 14, y: 5)
    }
}

private struct ListeningWings: View {
    @EnvironmentObject private var notch: NotchController
    let isThinking: Bool
    private let wingWidth = NotchGeometry.wingWidth

    var body: some View {
        if isThinking, let sentence = notch.thinkingSentence {
            StreamingThinkingIndicator(sentence: sentence)
        } else {
            compactWings
        }
    }

    private var compactWings: some View {
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

                Group {
                    if isThinking, let status = notch.workingStatus {
                        ShimmeringStatusText(text: status, isFailure: false)
                            .padding(.horizontal, 8)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity)

                Group {
                    NexusOrbAnimation(
                        mode: isThinking ? .thinkingCycle : .composing,
                        size: 27
                    )
                }
                .frame(width: wingWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isThinking ? "Nexus is thinking" : "Nexus is dictating")
    }
}

/// A model's native reasoning stream is never spoken or saved. It is shown
/// sentence-by-sentence only while the user has explicitly enabled thinking.
private struct StreamingThinkingIndicator: View {
    @EnvironmentObject private var notch: NotchController
    let sentence: String

    var body: some View {
        ZStack(alignment: .top) {
            NotchSurface(cornerRadius: 18).fill(.black)
            HStack(spacing: 0) {
                NexusPetView(pet: notch.selectedPet, activity: .thinking, height: 31)
                    .frame(width: NotchGeometry.wingWidth)
                Color.clear.frame(maxWidth: .infinity)
                NexusOrbAnimation(mode: .thinkingCycle, size: 27)
                    .frame(width: NotchGeometry.wingWidth)
            }
            .frame(height: 34)

            ShimmeringStatusText(text: sentence, isFailure: false, style: .white)
                .padding(.horizontal, 24)
                .padding(.top, 45)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nexus thinking: \(sentence)")
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
                    Image("Obsidian")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 17)
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.09), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(saveButtonColor)
                .disabled(notch.memory.saveState == .saving || notch.memory.saveState == .saved)
                .help(saveHelp)
                .accessibilityLabel(notch.memory.saveState.label)
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

                    if notch.activeModelSupportsThinking {
                        Button { notch.toggleThinkingMode() } label: {
                            Image(systemName: notch.thinkingModeEnabled ? "brain.head.profile.fill" : "brain.head.profile")
                                .font(.system(size: 14, weight: .medium))
                                .frame(width: 30, height: 30)
                                .background(
                                    notch.thinkingModeEnabled ? .purple.opacity(0.24) : .white.opacity(0.09),
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(notch.thinkingModeEnabled ? .purple.opacity(0.95) : .white.opacity(0.72))
                        .help(notch.thinkingModeEnabled ? "Stream model thinking" : "Enable streamed model thinking")
                        .accessibilityLabel(notch.thinkingModeEnabled ? "Disable streamed model thinking" : "Enable streamed model thinking")
                    }

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
        if activity.sources.isEmpty && activity.query == nil {
            receiptLabel
        } else {
            Button { showsSources.toggle() } label: { receiptLabel }
                .buttonStyle(.plain)
                .popover(isPresented: $showsSources, arrowEdge: .top) {
                    ToolReceiptSourcesView(activity: activity)
                }
                .help(activity.query == nil ? "Show sources" : "Show submitted query and sources")
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
                Text(activity.toolName == "Web Search" ? "Web sources" : "Obsidian sources")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }

            if let query = activity.query {
                VStack(alignment: .leading, spacing: 5) {
                    Text(activity.toolName == "Web Search" ? "Search query" : "Retrieval query")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(query)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }

            if !activity.sources.isEmpty {
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
                            if let url = URL(string: source.sourceID),
                               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                                Link(destination: url) {
                                    Label(url.host ?? source.sourceID, systemImage: "arrow.up.right")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                }
                                .foregroundStyle(.cyan.opacity(0.9))
                            } else {
                                Text(source.sourceID)
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(15)
        .frame(width: 380)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources used for this response")
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
