import SwiftUI

/// Native Canvas adaptation of the Thinking Orbs state vocabulary
/// (MIT, https://github.com/Jakubantalik/thinking-orbs). It intentionally
/// avoids a WebView or JavaScript runtime in the notch.
struct NexusOrbAnimation: View {
    enum Mode: Equatable {
        /// Dictation uses the Orb project's composing state at 1.5× speed.
        case composing
        case thinkingCycle
    }

    private enum State: Equatable {
        case composing
        case listening
        case searching
        case solving
    }

    let mode: Mode
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { timeline in
            let now = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let state = state(at: now)
            Canvas { context, canvasSize in
                draw(state, in: canvasSize, time: now, context: &context)
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch mode {
        case .composing: "Nex is listening"
        case .thinkingCycle: "Nex is thinking"
        }
    }

    private func state(at time: TimeInterval) -> State {
        switch mode {
        case .composing: return State.composing
        case .thinkingCycle:
            // Distinct work verbs keep the compact notch alive without a
            // random status: search → solve → listen for the next constraint.
            let states: [State] = [.searching, .solving, .listening]
            return states[Int(time / 2.25) % states.count]
        }
    }

    private func draw(_ state: State, in canvas: CGSize, time: TimeInterval, context: inout GraphicsContext) {
        let diameter = min(canvas.width, canvas.height)
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let dotRadius = max(1.05, diameter * 0.041)

        let animationTime = state == .composing ? time * 1.5 : time
        switch state {
        case .composing:
            // Undulating multi-band sash: the deliberate, faster composing
            // mark used while the microphone is actively transcribing.
            for band in 0..<4 {
                for point in 0..<15 {
                    let progress = Double(point) / 14
                    let x = center.x + (CGFloat(progress) - 0.5) * diameter * 0.74
                    let y = center.y
                        + CGFloat(band - 1) * diameter * 0.095
                        + sin(progress * .pi * 2 + animationTime * 7.8 + Double(band) * 0.9) * diameter * 0.075
                    dot(
                        at: CGPoint(x: x, y: y),
                        radius: dotRadius,
                        opacity: 0.40 + 0.50 * (sin(progress * .pi * 2 - animationTime * 5.5) + 1) / 2,
                        context: &context
                    )
                }
            }

        case .listening:
            // Three small waveform rings. This is the dictation/composing mark.
            for ring in 0..<3 {
                let radius = diameter * (0.23 + CGFloat(ring) * 0.105)
                for point in 0..<20 {
                    let angle = Double(point) / 20 * .pi * 2
                    let wave = sin(angle * 3 - animationTime * 7.4 + Double(ring) * 1.2) * diameter * 0.043
                    let x = center.x + cos(angle) * radius
                    let y = center.y + sin(angle) * radius * 0.58 + wave
                    dot(at: CGPoint(x: x, y: y), radius: dotRadius, opacity: 0.40 + 0.48 * (sin(angle - animationTime * 4) + 1) / 2, context: &context)
                }
            }

        case .searching:
            // A dotted globe and a bright scanning meridian.
            for latitude in -2...2 {
                let y = CGFloat(latitude) * diameter * 0.115
                let radius = sqrt(max(0, pow(diameter * 0.36, 2) - pow(y, 2)))
                for point in 0..<13 {
                let angle = Double(point) / 13 * .pi * 2 + animationTime * 0.24
                    let x = center.x + cos(angle) * radius
                    let dotY = center.y + y + sin(angle) * diameter * 0.018
                    dot(at: CGPoint(x: x, y: dotY), radius: dotRadius, opacity: 0.28, context: &context)
                }
            }
            let scan = animationTime * 2.4
            for point in 0..<16 {
                let angle = Double(point) / 16 * .pi * 2
                let x = center.x + cos(angle) * diameter * 0.14 * cos(scan)
                let y = center.y + sin(angle) * diameter * 0.36
                dot(at: CGPoint(x: x, y: y), radius: dotRadius * 1.15, opacity: 0.38 + 0.58 * (sin(angle + scan) + 1) / 2, context: &context)
            }

        case .solving:
            // Three bands briefly scatter then snap into aligned rows.
            for band in 0..<3 {
                let y = center.y + CGFloat(band - 1) * diameter * 0.19
                for point in 0..<11 {
                    let progress = (sin(animationTime * 3.2 + Double(band) * 1.7) + 1) / 2
                    let x = center.x + (CGFloat(point) - 5) * diameter * 0.071
                    let scatter = sin(animationTime * 7.5 + Double(point * 3 + band)) * diameter * 0.065 * CGFloat(1 - progress)
                    dot(at: CGPoint(x: x + scatter, y: y), radius: dotRadius, opacity: 0.42 + 0.48 * progress, context: &context)
                }
            }
        }
    }

    private func dot(at point: CGPoint, radius: CGFloat, opacity: Double, context: inout GraphicsContext) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
    }
}
