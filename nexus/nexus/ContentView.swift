import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: NexusAppState
    @State private var showingModels = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: appState.isExpanded ? 34 : 25, style: .continuous)
                .fill(.black.opacity(0.92))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: appState.isExpanded ? 34 : 25, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: appState.isExpanded ? 34 : 25, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                }

            Group {
                if appState.isExpanded {
                    ExpandedNexusView(showingModels: $showingModels)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)), removal: .opacity))
                } else {
                    CompactNexusView()
                        .transition(.opacity.combined(with: .scale(scale: 0.86)))
                }
            }
            .padding(appState.isExpanded ? 22 : 0)
        }
        .frame(width: appState.isExpanded ? 770 : 218, height: appState.isExpanded ? 390 : 62)
        .contentShape(RoundedRectangle(cornerRadius: appState.isExpanded ? 34 : 25, style: .continuous))
        .onTapGesture {
            guard !appState.isExpanded else { return }
            appState.toggleOverlay()
        }
        .sheet(isPresented: $showingModels) {
            ModelAggregatorView()
                .frame(minWidth: 680, minHeight: 520)
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.82, blendDuration: 0.1), value: appState.isExpanded)
    }
}

private struct CompactNexusView: View {
    @State private var isListening = false

    var body: some View {
        HStack(spacing: 10) {
            AgentOrb(size: 35)
            DictationBars(isListening: isListening)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isListening = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nexus is dictating. Click to open.")
    }
}

private struct ExpandedNexusView: View {
    @EnvironmentObject private var appState: NexusAppState
    @Binding var showingModels: Bool
    @State private var isListening = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                HStack(spacing: 11) {
                    AgentOrb(size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NEXUS")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .tracking(1.5)
                        HStack(spacing: 6) {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text("Listening")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    Button {
                        showingModels = true
                    } label: {
                        Label("Models", systemImage: "cube.transparent")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))

                    Button(action: appState.toggleOverlay) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Collapse Nexus")
                }
            }

            Spacer().frame(height: 31)

            HStack(alignment: .top, spacing: 16) {
                DictationBars(isListening: isListening)
                    .frame(width: 30, height: 32)
                    .padding(.top, 3)

                Text("Yo Nexus, send an email to Sam Altman asking for 2 million OpenAI credits, we just ran out.")
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cyan)
                Text("Nexus is ready to turn this into an action.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                Text("⌘ ↵ to send")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .foregroundStyle(.white)
        .onAppear { isListening = true }
    }
}

private struct DictationBars: View {
    let isListening: Bool
    private let barCount = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isListening)) { timeline in
            HStack(spacing: 3.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    let wave = sin(timeline.date.timeIntervalSinceReferenceDate * 6.4 + Double(index) * 1.35)
                    Capsule()
                        .fill(.white)
                        .frame(width: 4, height: 12 + max(0, wave) * 18)
                }
            }
            .frame(height: 32)
            .animation(.easeInOut(duration: 0.08), value: timeline.date)
        }
    }
}

private struct AgentOrb: View {
    let size: CGFloat
    @State private var rotates = false

    var body: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: [.blue, .cyan, .white.opacity(0.9), .indigo, .blue], center: .center))
                .rotationEffect(.degrees(rotates ? 360 : 0))
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.85), .white.opacity(0.03), .clear], center: .init(x: 0.34, y: 0.28), startRadius: 1, endRadius: size * 0.55))
            Circle()
                .stroke(.white.opacity(0.6), lineWidth: 0.6)
        }
        .frame(width: size, height: size)
        .shadow(color: .cyan.opacity(0.45), radius: 10)
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                rotates = true
            }
        }
    }
}

#Preview {
    ContentView().environmentObject(NexusAppState())
}
