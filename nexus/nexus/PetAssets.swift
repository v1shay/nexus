import AppKit
import SwiftUI

struct NexusPet: Identifiable, Equatable, Sendable {
    enum Artwork: Equatable, Sendable {
        case atlas
        case animatedGIF(URL)
    }

    let id: String
    let displayName: String
    let description: String
    let artwork: Artwork

    init(
        id: String,
        displayName: String,
        description: String,
        artwork: Artwork = .atlas
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.artwork = artwork
    }
}

enum NexusPetActivity: Sendable {
    case idle
    case dictating
    case thinking
    case overlay
    case tool

    var atlasRow: Int {
        switch self {
        case .idle: 0
        case .dictating: 6   // waiting / attentive listening
        case .thinking: 7    // active task work
        case .overlay: 8     // reviewing the completed response
        case .tool: 7
        }
    }

    var frameCount: Int { 6 }

    var frameDuration: TimeInterval {
        switch self {
        case .idle: 0.24
        case .dictating: 0.13
        case .thinking, .tool: 0.14
        case .overlay: 0.20
        }
    }
}

enum NexusPetCatalog {
    static let all: [NexusPet] = [
        NexusPet(
            id: "tiko",
            displayName: "Tiko",
            description: "A tiny yellow utility robot with curious camera eyes and friendly clamp arms."
        ),
        NexusPet(
            id: "kabi",
            displayName: "Kabi",
            description: "A sleepy teal companion who is happiest with an apple."
        ),
        NexusPet(
            id: "macintosh",
            displayName: "Macintosh",
            description: "A tiny retro Macintosh-inspired Finder face companion."
        ),
        NexusPet(
            id: "lil-finder",
            displayName: "Lil Finder",
            description: "A rounded blue-and-white digital companion."
        ),
        NexusPet(
            id: "crt-pal",
            displayName: "CRT Pal",
            description: "A monitor-headed companion with a glowing green CRT face."
        ),
        NexusPet(
            id: "pan-chan-laptop",
            displayName: "Pan-chan",
            description: "A fluffy panda helper who works from a tiny laptop."
        ),
        NexusPet(
            id: "linux",
            displayName: "Linux",
            description: "The animated Linux companion from your Downloads folder.",
            artwork: .animatedGIF(
                URL(fileURLWithPath: "/Users/vishayagarwal/Downloads/icons8-linux.gif")
            )
        )
    ]

    static func pet(withID id: String?) -> NexusPet {
        all.first { $0.id == id } ?? all[0]
    }
}

@MainActor
private enum NexusPetAtlasCache {
    private static var images: [String: NSImage] = [:]

    static func image(for pet: NexusPet) -> NSImage? {
        if let image = images[pet.id] { return image }
        guard
            let url = Bundle.main.url(
                forResource: "spritesheet",
                withExtension: "webp",
                subdirectory: "Pets/\(pet.id)"
            ),
            let image = NSImage(contentsOf: url)
        else { return nil }
        images[pet.id] = image
        return image
    }
}

struct NexusPetView: View {
    let pet: NexusPet
    let activity: NexusPetActivity
    let height: CGFloat

    private let atlasColumns: CGFloat = 8
    private let atlasRows: CGFloat = 9
    private let cellAspectRatio: CGFloat = 192 / 208

    var body: some View {
        Group {
            switch pet.artwork {
            case .atlas:
                TimelineView(.animation(minimumInterval: activity.frameDuration)) { timeline in
                    let frame = Int(
                        timeline.date.timeIntervalSinceReferenceDate / activity.frameDuration
                    ) % activity.frameCount

                    Group {
                        if let atlas = NexusPetAtlasCache.image(for: pet) {
                            GeometryReader { proxy in
                                Image(nsImage: atlas)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(
                                        width: proxy.size.width * atlasColumns,
                                        height: proxy.size.height * atlasRows
                                    )
                                    .offset(
                                        x: -CGFloat(frame) * proxy.size.width,
                                        y: -CGFloat(activity.atlasRow) * proxy.size.height
                                    )
                            }
                        } else {
                            Image(systemName: "pawprint.fill")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.cyan)
                                .padding(height * 0.18)
                        }
                    }
                    .frame(width: height * cellAspectRatio, height: height)
                    .clipped()
                }
            case .animatedGIF(let url):
                AnimatedGIFPetView(url: url)
                    .frame(width: height * cellAspectRatio, height: height)
            }
        }
        .frame(width: height * cellAspectRatio, height: height)
        .accessibilityLabel("\(pet.displayName), \(activity.accessibilityDescription)")
    }
}

/// AppKit keeps GIF animation alive across SwiftUI updates, unlike a plain
/// `Image(nsImage:)`, which would freeze on the first frame.
private struct AnimatedGIFPetView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        imageView.image = NSImage(contentsOf: url)
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        guard imageView.image == nil else { return }
        imageView.image = NSImage(contentsOf: url)
        imageView.animates = true
    }
}

/// NEX's compact block wordmark. Keeping it vector-based makes it crisp in
/// both the terminal masthead and the very small notch tool indicator.
struct NexWordmark: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let unit = min(proxy.size.width / 13.2, proxy.size.height / 5)
            HStack(spacing: unit * 0.55) {
                nexGlyph(unit: unit, pattern: [
                    "1001",
                    "1101",
                    "1011",
                    "1001",
                    "1001"
                ])
                nexGlyph(unit: unit, pattern: [
                    "1111",
                    "1000",
                    "1110",
                    "1000",
                    "1111"
                ])
                nexGlyph(unit: unit, pattern: [
                    "1001",
                    "0110",
                    "0010",
                    "0110",
                    "1001"
                ])
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .accessibilityLabel("Nex")
    }

    @ViewBuilder
    private func nexGlyph(unit: CGFloat, pattern: [String]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(pattern.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, bit in
                        Rectangle()
                            .fill(bit == "1" ? color : .clear)
                            .frame(width: unit, height: unit)
                    }
                }
            }
        }
    }
}

private extension NexusPetActivity {
    var accessibilityDescription: String {
        switch self {
        case .idle: "idle"
        case .dictating: "listening"
        case .thinking: "thinking"
        case .overlay: "reviewing the response"
        case .tool: "using a tool"
        }
    }
}
