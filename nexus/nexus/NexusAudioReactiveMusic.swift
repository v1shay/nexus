import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import SwiftUI

/// A local-only audio meter for the music surface in the notch. ScreenCaptureKit
/// supplies the same output mix the user hears, so this works for Spotify as
/// well as browser audio (YouTube, Instagram, X, and other sites). No samples
/// are retained, written to disk, or sent over the network.
@MainActor
final class NexusAudioReactiveMusic: NSObject, ObservableObject {
    struct Palette: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        static let defaultBlue = Palette(red: 0.34, green: 0.64, blue: 1.0)

        var color: Color {
            Color(red: red, green: green, blue: blue)
        }
    }

    struct SpotifyTrack: Equatable {
        let title: String
        let artist: String
        let artworkURL: URL?
    }

    enum CaptureState: Equatable {
        case inactive
        case awaitingPermission
        case running
        case unavailable(String)
    }

    @Published private(set) var track: SpotifyTrack?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var palette = Palette.defaultBlue
    @Published private(set) var energy: CGFloat = 0
    @Published private(set) var captureState: CaptureState = .inactive

    /// Keeps browser/video playback visible for a moment between quiet samples.
    private(set) var lastAudibleAt: Date?
    var hasAudibleSystemAudio: Bool {
        guard let lastAudibleAt else { return false }
        return Date().timeIntervalSince(lastAudibleAt) < 1.15
    }
    var isPlaying: Bool { track != nil || hasAudibleSystemAudio }

    private let sampleQueue = DispatchQueue(label: "na.nexus.audio-reactive.samples", qos: .userInteractive)
    private var stream: SCStream?
    private var spotifyTimer: Timer?
    private var artworkTask: Task<Void, Never>?
    private var isStartingCapture = false
    private var lastSpotifySignature = ""

    func start() {
        guard spotifyTimer == nil else { return }
        refreshSpotify()
        spotifyTimer = Timer.scheduledTimer(
            timeInterval: 0.8,
            target: self,
            selector: #selector(refreshSpotifyTimer),
            userInfo: nil,
            repeats: true
        )
        requestAndStartCaptureIfPossible()
    }

    func stop() {
        spotifyTimer?.invalidate()
        spotifyTimer = nil
        artworkTask?.cancel()
        artworkTask = nil
        let activeStream = stream
        stream = nil
        captureState = .inactive
        Task { try? await activeStream?.stopCapture() }
    }

    /// The first call triggers macOS's Screen & System Audio Recording prompt.
    /// Afterwards the grant is persistent and no Spotify sign-in is involved.
    func requestAndStartCaptureIfPossible() {
        guard stream == nil, !isStartingCapture else { return }
        guard CGPreflightScreenCaptureAccess() else {
            captureState = .awaitingPermission
            _ = CGRequestScreenCaptureAccess()
            return
        }
        isStartingCapture = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isStartingCapture = false }
            await self.startCapture()
        }
    }

    private func startCapture() async {
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = shareableContent.displays.first else {
                captureState = .unavailable("No display is available for audio capture.")
                return
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 44_100
            configuration.channelCount = 2
            configuration.queueDepth = 3

            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await newStream.startCapture()
            stream = newStream
            captureState = .running
        } catch {
            captureState = .unavailable(error.localizedDescription)
        }
    }

    private func refreshSpotify() {
        let script = NSAppleScript(source: """
        tell application \"Spotify\"
            if it is running and player state is playing then
                set trackName to name of current track
                set artistName to artist of current track
                set coverURL to artwork url of current track
                return trackName & character id 31 & artistName & character id 31 & coverURL
            end if
        end tell
        return \"\"
        """)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error).stringValue ?? ""
        guard error == nil, !result.isEmpty else {
            if track != nil {
                track = nil
                artwork = nil
                palette = .defaultBlue
            }
            return
        }

        let parts = result.components(separatedBy: "\u{1F}")
        guard parts.count == 3 else { return }
        let url = URL(string: parts[2])
        let nextTrack = SpotifyTrack(title: parts[0], artist: parts[1], artworkURL: url)
        track = nextTrack
        let signature = "\(parts[0])|\(parts[1])|\(parts[2])"
        guard signature != lastSpotifySignature else { return }
        lastSpotifySignature = signature
        loadArtwork(from: url)
    }

    @objc private func refreshSpotifyTimer() {
        refreshSpotify()
    }

    private func loadArtwork(from url: URL?) {
        artworkTask?.cancel()
        artwork = nil
        palette = .defaultBlue
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let image = NSImage(data: data) else { return }
                artwork = image
                palette = image.nexusDominantPalette ?? .defaultBlue
            } catch {
                // Artwork is visual polish only; playback/audio reactivity remains live.
            }
        }
    }

    nonisolated private func receiveAudioEnergy(_ value: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let smoothed = self.energy * 0.62 + value * 0.38
            self.energy = smoothed
            if smoothed > 0.055 { self.lastAudibleAt = Date() }
        }
    }
}

extension NexusAudioReactiveMusic: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              CMSampleBufferIsValid(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr,
        let dataPointer,
        totalLength > 0 else { return }

        let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        let description = format.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)
        let isFloat = description.map { ($0.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0 } ?? true
        let sampleStride = isFloat ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
        let sampleCount = totalLength / sampleStride
        guard sampleCount > 0 else { return }

        // Read a bounded spread of samples. RMS gives the orb its immediate
        // pulse; a short smoothing pass on the main actor avoids jitter.
        let step = max(1, sampleCount / 1_024)
        var sumSquares = 0.0
        var count = 0
        let raw = UnsafeRawPointer(dataPointer)
        for index in Swift.stride(from: 0, to: sampleCount, by: step) {
            let sample: Double
            if isFloat {
                sample = Double(raw.loadUnaligned(fromByteOffset: index * sampleStride, as: Float.self))
            } else {
                sample = Double(raw.loadUnaligned(fromByteOffset: index * sampleStride, as: Int16.self)) / Double(Int16.max)
            }
            sumSquares += sample * sample
            count += 1
        }
        guard count > 0 else { return }
        let rms = sqrt(sumSquares / Double(count))
        let normalized = CGFloat(min(1, max(0, (rms - 0.008) * 6.6)))
        receiveAudioEnergy(normalized)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.captureState = .unavailable(error.localizedDescription)
            self?.stream = nil
        }
    }
}

private extension NSImage {
    var nexusDominantPalette: NexusAudioReactiveMusic.Palette? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: 4,
            bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(in: NSRect(x: 0, y: 0, width: 1, height: 1), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let color = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return nil }
        let maxComponent = max(color.redComponent, color.greenComponent, color.blueComponent, 0.001)
        // Keep dark album covers visible against the black notch without
        // changing their hue relationship.
        let scale = min(1, max(0.58, 0.82 / maxComponent))
        return .init(
            red: min(1, Double(color.redComponent * scale)),
            green: min(1, Double(color.greenComponent * scale)),
            blue: min(1, Double(color.blueComponent * scale))
        )
    }
}
