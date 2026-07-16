import SwiftUI

/// The view never pretends to be the camera cutout: at rest it is visually
/// indistinguishable from it.  The panel simply grows down from that location.
struct ContentView: View {
    @EnvironmentObject private var notch: NotchController

    var body: some View {
        ZStack(alignment: .top) {
            NotchSurface(cornerRadius: notch.isExpanded ? 28 : 10)
                .fill(.black.opacity(notch.isExpanded ? 0.78 : 1))
                .background(.ultraThinMaterial, in: NotchSurface(cornerRadius: notch.isExpanded ? 28 : 10))
                .overlay {
                    // The low-opacity lower stop lets the desktop gently bleed through,
                    // instead of ending in a hard black card.
                    NotchSurface(cornerRadius: notch.isExpanded ? 28 : 10)
                        .fill(
                            LinearGradient(
                                colors: [.black.opacity(0.18), .black.opacity(0.56), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

            if notch.isListening {
                ListeningContents()
                    .padding(.horizontal, notch.isExpanded ? 28 : 13)
                    .padding(.top, notch.isExpanded ? 22 : 3)
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
            }
        }
        .frame(width: notch.currentSize.width, height: notch.currentSize.height)
        .contentShape(Rectangle())
        .onHover { notch.updateHover($0) }
        .animation(.interpolatingSpring(stiffness: 300, damping: 30), value: notch.isExpanded)
        .animation(.easeInOut(duration: 0.16), value: notch.isListening)
    }
}

private struct ListeningContents: View {
    @EnvironmentObject private var notch: NotchController

    var body: some View {
        HStack {
            AgentOrb(size: notch.isExpanded ? 31 : 23)
            Spacer(minLength: 10)
            DictationBars()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nexus dictation is active")
    }
}

private struct DictationBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.6) {
                ForEach(0..<4, id: \.self) { index in
                    let wave = (sin(time * 7.2 + Double(index) * 1.47) + 1) / 2
                    Capsule()
                        .fill(.white.opacity(0.96))
                        .frame(width: 3.6, height: 7 + wave * 17)
                }
            }
            .frame(height: 25)
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
                .fill(RadialGradient(colors: [.white.opacity(0.9), .clear], center: .init(x: 0.31, y: 0.25), startRadius: 0, endRadius: size * 0.58))
            Circle().stroke(.white.opacity(0.45), lineWidth: 0.6)
        }
        .frame(width: size, height: size)
        .shadow(color: .cyan.opacity(0.42), radius: 8)
        .onAppear {
            withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) { rotates = true }
        }
    }
}

/// A notch has square top edges (hidden in the menu bar) and only rounds at its bottom.
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
