import SwiftUI

/// The panel is visually indistinguishable from the physical cutout at rest.
/// Interaction state is supplied by the AppKit controller above the view.
struct ContentView: View {
    @EnvironmentObject private var notch: NotchController

    var body: some View {
        ZStack(alignment: .top) {
            if notch.isListening {
                ListeningWings()
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            } else {
                NotchSurface(cornerRadius: notch.isExpanded ? 29 : 10)
                    .fill(.black.opacity(notch.isExpanded ? 0.82 : 1))
                    .background(.ultraThinMaterial, in: NotchSurface(cornerRadius: notch.isExpanded ? 29 : 10))
                    .overlay {
                        NotchSurface(cornerRadius: notch.isExpanded ? 29 : 10)
                            .stroke(.white.opacity(notch.isExpanded ? 0.18 : 0), lineWidth: 0.8)
                    }

                if notch.isExpanded {
                    TranscriptContents()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(width: notch.currentSize.width, height: notch.currentSize.height)
        .contentShape(Rectangle())
        .onHover { notch.updateHover($0) }
        .animation(.interpolatingSpring(stiffness: 340, damping: 31), value: notch.currentSize)
        .animation(.easeInOut(duration: 0.18), value: notch.isListening)
        .animation(.easeInOut(duration: 0.22), value: notch.hasTranscript)
    }
}

private struct ListeningWings: View {
    private let wingWidth: CGFloat = 62

    var body: some View {
        ZStack {
            NotchSurface(cornerRadius: 13)
                .fill(.black)

            HStack(spacing: 0) {
                AgentOrb(size: 27)
                    .frame(width: wingWidth)

                Color.clear
                    .frame(maxWidth: .infinity)

                DictationBars()
                    .frame(width: wingWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nexus is dictating")
    }
}

private struct TranscriptContents: View {
    @EnvironmentObject private var notch: NotchController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                AgentOrb(size: 34)
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

            Spacer(minLength: 20)

            Text(notch.transcript)
                .font(.system(size: 25, weight: .medium, design: .rounded))
                .tracking(-0.3)
                .lineSpacing(5)
                .foregroundStyle(.white.opacity(0.96))
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.9))
                Capsule()
                    .fill(.white.opacity(0.16))
                    .frame(height: 1)
            }
            .padding(.bottom, 1)
        }
        .padding(.horizontal, 27)
        .padding(.top, 20)
        .padding(.bottom, 20)
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
