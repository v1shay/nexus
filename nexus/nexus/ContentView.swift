import SwiftUI

/// The panel is visually indistinguishable from the physical cutout at rest.
/// Interaction state is supplied by the AppKit controller above the view.
struct ContentView: View {
    @EnvironmentObject private var notch: NotchController

    var body: some View {
        ZStack(alignment: .top) {
            if notch.isListening || notch.isThinking {
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
    let isThinking: Bool
    private let wingWidth = NotchGeometry.wingWidth

    var body: some View {
        ZStack {
            NotchSurface(cornerRadius: 13)
                .fill(.black)

            HStack(spacing: 0) {
                AgentOrb(size: 27)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                InteractiveAgentOrb(
                    size: 34,
                    isMuted: notch.isVoiceMuted,
                    mute: notch.toggleVoiceMute,
                    close: notch.dismissOverlay
                )
                Spacer()
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

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(notch.transcript)
                        .font(.system(size: notch.answer.isEmpty ? 25 : 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(notch.answer.isEmpty ? 0.96 : 0.62))

                    if !notch.answer.isEmpty {
                        Capsule()
                            .fill(.white.opacity(0.14))
                            .frame(height: 1)
                        Text(notch.answer)
                            .font(.system(size: 21, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.96))
                    }
                }
                .tracking(-0.2)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 27)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }
}

private struct InteractiveAgentOrb: View {
    let size: CGFloat
    let isMuted: Bool
    let mute: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack {
            AgentOrb(size: size)
                .opacity(isMuted ? 0.55 : 1)
            if isMuted {
                Circle().fill(.black.opacity(0.48))
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { result in
                    switch result {
                    case .first: close()
                    case .second: mute()
                    }
                }
        )
        .help(isMuted ? "Click to unmute · Double-click to close" : "Click to mute · Double-click to close")
        .accessibilityLabel(isMuted ? "Nexus voice muted" : "Nexus voice active")
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

private struct AgentOrb: View {
    let size: CGFloat
    @State private var rotates = false

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: [.cyan, .blue, .white, .indigo, .cyan], center: .center))
                .rotationEffect(.degrees(rotates ? 360 : 0))
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.92), .clear], center: .init(x: 0.31, y: 0.25), startRadius: 0, endRadius: size * 0.58))
            Circle().stroke(.white.opacity(0.45), lineWidth: 0.6)
        }
        .frame(width: size, height: size)
        .shadow(color: .cyan.opacity(0.42), radius: 8)
        .onAppear {
            withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) { rotates = true }
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
