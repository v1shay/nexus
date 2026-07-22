import SwiftUI

// Native Swift port of the relevant rendering mechanics from
// https://github.com/Jakubantalik/thinking-orbs (MIT License).
// Copyright (c) 2026 Jakub Antalik. The copyright and permission notice
// below applies to the ported algorithms in this file.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions: The above copyright
// notice and this permission notice shall be included in all copies or
// substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
// WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

/// The same 20px tuned presets and 3D dot language as Thinking Orbs, rendered
/// with SwiftUI Canvas so the notch remains entirely native.
struct NexusOrbAnimation: View {
    enum Mode: Equatable {
        /// The source library's composing ribbon, intentionally 1.5× faster.
        case composing
        case thinkingCycle
    }

    fileprivate enum State: Equatable { case composing, listening, searching, solving }

    let mode: Mode
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { timeline in
            let seconds = reduceMotion ? 0.6 : timeline.date.timeIntervalSinceReferenceDate
            let state = state(at: seconds)
            Canvas { context, canvasSize in
                NexusOrbRenderer.draw(state: state, into: &context, size: canvasSize, seconds: seconds)
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel(mode == .composing ? "Nex is listening" : "Nex is thinking")
    }

    private func state(at seconds: TimeInterval) -> State {
        switch mode {
        case .composing: return .composing
        case .thinkingCycle:
            let states: [State] = [.searching, .solving, .listening]
            return states[Int(seconds / 2.25) % states.count]
        }
    }
}

private enum NexusOrbRenderer {
    private struct Dot {
        let x: Double
        let y: Double
        let z: Double
        let radius: Double
        /// Source "ink" value: mirrored on Nexus's dark notch.
        let ink: Double
        let alpha: Double
    }

    private struct Projection {
        let yaw: Double
        let tilt: Double
        let center: Double
        let scale: Double

        func apply(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            let x1 = x * cos(yaw) + z * sin(yaw)
            let z1 = -x * sin(yaw) + z * cos(yaw)
            let y1 = y * cos(tilt) - z1 * sin(tilt)
            let z2 = y * sin(tilt) + z1 * cos(tilt)
            return (center + x1 * scale, center - y1 * scale, z2)
        }
    }

    // These are the source library's purpose-tuned 20px presets. Drawing in
    // a 20pt logical canvas and scaling the final dots preserves their density
    // when Nexus gives the mark slightly more room in the notch.
    private static let logicalSize = 20.0

    static func draw(state: NexusOrbAnimation.State, into context: inout GraphicsContext, size: CGSize, seconds: TimeInterval) {
        let t = seconds * speed(for: state)
        let dots: [Dot]
        switch state {
        case .searching: dots = globe(time: t)
        case .solving: dots = rubik(time: t)
        case .listening: dots = wave(time: t)
        case .composing: dots = ribbon(time: t)
        }
        paint(dots, into: &context, canvasSize: size)
    }

    private static func speed(for state: NexusOrbAnimation.State) -> Double {
        switch state {
        case .searching: 2.665
        case .solving: 1.95
        case .listening: 3.998
        case .composing: 3.12 * 1.5
        }
    }

    // MARK: searching · globe

    private static func globe(time: Double) -> [Dot] {
        let radius = logicalSize / 2 * 0.82
        let projection = Projection(yaw: time * 0.5, tilt: 0.4 + 0.06 * sin(time * 0.35), center: logicalSize / 2, scale: radius)
        let scan = time * (0.5 + (1.7 - 0.5) * 4.335)
        let rs = radiusScale(0.6)
        var dots: [Dot] = []
        for ring in 0...6 {
            let latitude = -.pi / 2 + Double(ring) / 6 * .pi
            let cosLatitude = cos(latitude)
            let sinLatitude = sin(latitude)
            let count = max(1, Int((abs(cosLatitude) * 14).rounded()))
            for index in 0..<count {
                let longitude = Double(index) / Double(count) * .pi * 2
                let point = projection.apply(cosLatitude * cos(longitude), sinLatitude, cosLatitude * sin(longitude))
                let depth = (point.2 + 1) / 2
                let delta = angleDelta(longitude + time * 0.5, scan)
                let boost = exp(-(delta * delta) / 0.18) * max(0, point.2)
                dots.append(.init(
                    x: point.0, y: point.1, z: point.2,
                    radius: (1.05 + 2.975 * depth + boost) * rs,
                    ink: 0.62 - 0.54 * depth,
                    alpha: 0.45 + 0.55 * min(1, boost)
                ))
            }
        }
        return dots
    }

    // MARK: solving · rubik

    private struct Move { let axis: Int; let low: Double; let high: Double; let angle: Double }

    private static func rubik(time: Double) -> [Dot] {
        let radius = logicalSize / 2 * 0.82
        let projection = Projection(yaw: time * 0.55, tilt: 0.35 + 0.1 * sin(time * 0.9), center: logicalSize / 2, scale: radius)
        let moves = makeMoves(count: 14)
        let cycle = solveCycle(time: time, count: moves.count, slotDuration: 0.42, rest: 1.2)
        let rs = radiusScale(0.6)
        var dots: [Dot] = []
        for ring in 0...4 {
            let latitude = -.pi / 2 + Double(ring) / 4 * .pi
            let cosLatitude = cos(latitude)
            let sinLatitude = sin(latitude)
            let count = max(1, Int((abs(cosLatitude) * 12).rounded()))
            for index in 0..<count {
                let longitude = Double(index) / Double(count) * .pi * 2
                let moved = applyMoves(
                    x: cosLatitude * cos(longitude), y: sinLatitude, z: cosLatitude * sin(longitude),
                    moves: moves, progress: cycle.progress, active: cycle.active
                )
                let point = projection.apply(moved.x, moved.y, moved.z)
                let depth = (point.2 + 1) / 2
                dots.append(.init(
                    x: point.0, y: point.1, z: point.2,
                    radius: (1.14 + 3.23 * depth + (moved.isActive ? 0.57 : 0)) * rs,
                    ink: 0.62 - 0.54 * depth - (moved.isActive ? 0.14 : 0),
                    alpha: 1
                ))
            }
        }
        return dots
    }

    private static func makeMoves(count: Int) -> [Move] {
        (0..<count).map { index in
            let axis = min(2, Int(floor(hash(Double(index), 2.3) * 3)))
            let low = -1 + 0.5 * Double(min(3, Int(floor(hash(Double(index), 5.9) * 4))))
            let direction = hash(Double(index), 7.7) < 0.5 ? 1.0 : -1.0
            return Move(axis: axis, low: low, high: low + 0.5, angle: direction * .pi / 2)
        }
    }

    private static func solveCycle(time: Double, count: Int, slotDuration: Double, rest: Double) -> (progress: [Double], active: Int) {
        let cycle = 2 * Double(count) * slotDuration + rest
        let current = time.truncatingRemainder(dividingBy: cycle)
        var progress = Array(repeating: 0.0, count: count)
        var active = -1
        if current < 2 * Double(count) * slotDuration {
            let slot = Int(floor(current / slotDuration))
            let percent = (current - Double(slot) * slotDuration) / slotDuration
            let clamped = min(1, percent / 0.7)
            let eased = 1 - pow(1 - clamped, 3)
            if slot < count {
                for index in 0..<slot { progress[index] = 1 }
                progress[slot] = eased
                active = slot
            } else {
                let reverse = 2 * count - 1 - slot
                if reverse > 0 { for index in 0..<reverse { progress[index] = 1 } }
                progress[reverse] = 1 - eased
                active = reverse
            }
        }
        return (progress, active)
    }

    private static func applyMoves(x: Double, y: Double, z: Double, moves: [Move], progress: [Double], active: Int) -> (x: Double, y: Double, z: Double, isActive: Bool) {
        var x = x
        var y = y
        var z = z
        var isActive = false
        for index in moves.indices where progress[index] > 0 {
            let move = moves[index]
            let coordinate = move.axis == 0 ? x : (move.axis == 1 ? y : z)
            guard coordinate >= move.low && coordinate < move.high else { continue }
            if index == active { isActive = true }
            let cosine = cos(move.angle * progress[index])
            let sine = sin(move.angle * progress[index])
            if move.axis == 0 {
                let newY = y * cosine - z * sine
                z = y * sine + z * cosine
                y = newY
            } else if move.axis == 1 {
                let newX = x * cosine + z * sine
                z = -x * sine + z * cosine
                x = newX
            } else {
                let newX = x * cosine - y * sine
                y = x * sine + y * cosine
                x = newX
            }
        }
        return (x, y, z, isActive)
    }

    // MARK: listening · wave

    private static func wave(time: Double) -> [Dot] {
        let radius = logicalSize / 2 * 0.874
        let projection = Projection(yaw: time * 0.18, tilt: 0.38, center: logicalSize / 2, scale: 1)
        let rs = radiusScale(0.6)
        var dots: [Dot] = []
        for ring in 0...5 {
            let latitude = -.pi / 2 + Double(ring) / 5 * .pi
            let cosLatitude = cos(latitude)
            let sinLatitude = sin(latitude)
            let wave = 0.62 * sin(time * 2.1 - Double(ring) * 0.52) + 0.38 * sin(time * 1.27 + Double(ring) * 0.83)
            let warpedRadius = radius * (0.88 + 0.105 * wave)
            let count = max(1, Int((abs(cosLatitude) * 13).rounded()))
            for index in 0..<count {
                let longitude = Double(index) / Double(count) * .pi * 2
                let point = projection.apply(
                    cosLatitude * cos(longitude) * warpedRadius,
                    sinLatitude * warpedRadius,
                    cosLatitude * sin(longitude) * warpedRadius
                )
                let depth = (point.2 / radius + 1) / 2
                let crest = max(0, wave)
                dots.append(.init(
                    x: point.0, y: point.1, z: point.2,
                    radius: (0.96 + 2.72 * depth) * (1 + 0.4 * crest) * rs,
                    ink: 0.66 - 0.56 * depth - 0.1 * crest,
                    alpha: 1
                ))
            }
        }
        return dots
    }

    // MARK: composing · ribbon

    private static func ribbon(time: Double) -> [Dot] {
        let radius = logicalSize / 2 * 0.78
        let projection = Projection(yaw: 0, tilt: 0.3, center: logicalSize / 2, scale: 1)
        let rs = radiusScale(0.6)
        var dots: [Dot] = []
        for index in 0..<8 {
            let direction = fibonacciDirection(index: index, count: 8)
            let point = projection.apply(direction.0 * radius, direction.1 * radius, direction.2 * radius)
            let depth = (point.2 / radius + 1) / 2
            dots.append(.init(x: point.0, y: point.1, z: point.2, radius: 0.8 * rs, ink: 0.78, alpha: 0.1 + 0.22 * depth))
        }

        // Source preset after count scaling: 2 lanes × 20 segments, with its
        // fixed orientation and traveling two-wave deformation.
        let lanes = 10
        let segments = 20
        let tilt = 0.55
        let ux = 1.0, uy = 0.0, uz = 0.0
        let vx = 0.0, vy = cos(tilt), vz = sin(tilt)
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx
        for lane in 0..<lanes {
            let laneOffset = (Double(lane) - Double(lanes - 1) / 2) * 0.075
            let edge = abs(Double(lane) - Double(lanes - 1) / 2) / (Double(lanes - 1) / 2)
            for segment in 0..<segments {
                let angle = Double(segment) / Double(segments) * .pi * 2
                let wobble = 0.16 * sin(angle * 3 - time * 1.7 + Double(lane) * 0.22) + 0.07 * sin(angle * 5 + time * 1.1)
                let offset = laneOffset + wobble
                let x = ux * cos(angle) + vx * sin(angle) + nx * offset
                let y = uy * cos(angle) + vy * sin(angle) + ny * offset
                let z = uz * cos(angle) + vz * sin(angle) + nz * offset
                let length = sqrt(x * x + y * y + z * z)
                let point = projection.apply(x / length * radius, y / length * radius, z / length * radius)
                let depth = (point.2 / radius + 1) / 2
                dots.append(.init(
                    x: point.0, y: point.1, z: point.2,
                    radius: (1.1803 + 1.8241 * depth) * (1 - 0.25 * edge) * rs,
                    ink: 0.52 - 0.44 * depth + 0.18 * edge,
                    alpha: 0.4 + 0.6 * depth
                ))
            }
        }
        return dots
    }

    // MARK: shared source primitives

    private static func paint(_ dots: [Dot], into context: inout GraphicsContext, canvasSize: CGSize) {
        let scale = min(canvasSize.width, canvasSize.height) / logicalSize
        let offsetX = (canvasSize.width - logicalSize * scale) / 2
        let offsetY = (canvasSize.height - logicalSize * scale) / 2
        for dot in dots.sorted(by: { $0.z < $1.z }) where dot.alpha >= 0.02 {
            let brightness = min(1, max(0, 1 - dot.ink))
            let radius = max(0.3, dot.radius) * scale
            let rect = CGRect(
                x: offsetX + CGFloat(dot.x) * scale - radius,
                y: offsetY + CGFloat(dot.y) * scale - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(Color(white: brightness).opacity(dot.alpha)))
        }
    }

    private static func angleDelta(_ lhs: Double, _ rhs: Double) -> Double {
        atan2(sin(lhs - rhs), cos(lhs - rhs))
    }

    private static func hash(_ first: Double, _ second: Double) -> Double {
        let value = sin(first * 12.9898 + second * 78.233) * 43758.5453
        return value - floor(value)
    }

    private static func fibonacciDirection(index: Int, count: Int) -> (Double, Double, Double) {
        let golden = .pi * (3 - sqrt(5.0))
        let y = 1 - 2 * (Double(index) + 0.5) / Double(count)
        let radius = sqrt(1 - y * y)
        let angle = Double(index) * golden
        return (radius * cos(angle), y, radius * sin(angle))
    }

    private static func radiusScale(_ exponent: Double) -> Double {
        pow(logicalSize / 300, exponent)
    }
}
