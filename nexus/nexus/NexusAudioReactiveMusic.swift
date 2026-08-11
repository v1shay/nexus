import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import CryptoKit
import ScreenCaptureKit
import SwiftUI

struct BrowserTab: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: URL
    let isActive: Bool
}

enum MediaPlatform: String, Codable, Sendable, CaseIterable {
    case youtube
    case youtubeMusic
    case x
    case instagram
    case twitch
    case spotify
    case other

    static func classify(url: URL) -> Self {
        let host = url.host?.lowercased() ?? ""
        if host == "music.youtube.com" { return .youtubeMusic }
        if host == "youtu.be" || host.hasSuffix("youtube.com") { return .youtube }
        if host == "x.com" || host.hasSuffix(".x.com") || host.hasSuffix("twitter.com") { return .x }
        if host == "instagram.com" || host.hasSuffix(".instagram.com") { return .instagram }
        if host == "twitch.tv" || host.hasSuffix(".twitch.tv") { return .twitch }
        if host == "open.spotify.com" || host.hasSuffix(".spotify.com") { return .spotify }
        return .other
    }
}

struct MediaTab: Identifiable, Sendable, Equatable {
    let tab: BrowserTab
    let platform: MediaPlatform
    let mediaID: String?
    let thumbnailURL: URL?
    let priority: Int

    var id: String { tab.id }

    init?(tab: BrowserTab) {
        let platform = MediaPlatform.classify(url: tab.url)
        guard platform != .other else { return nil }
        let mediaID = Self.identifier(for: tab.url, platform: platform)
        self.tab = tab
        self.platform = platform
        self.mediaID = mediaID
        self.thumbnailURL = Self.thumbnailURL(for: mediaID, platform: platform)
        self.priority = (tab.isActive ? 100 : 0) + Self.platformPriority(platform)
    }

    private static func platformPriority(_ platform: MediaPlatform) -> Int {
        switch platform {
        case .youtube, .youtubeMusic, .twitch: 30
        case .spotify: 20
        case .instagram, .x: 10
        case .other: 0
        }
    }

    private static func identifier(for url: URL, platform: MediaPlatform) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        switch platform {
        case .youtube, .youtubeMusic:
            if url.host?.lowercased() == "youtu.be" { return components.first }
            if let index = components.firstIndex(of: "shorts"), components.indices.contains(index + 1) {
                return components[index + 1]
            }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value
        case .x:
            guard let index = components.firstIndex(of: "status"), components.indices.contains(index + 1) else { return nil }
            return components[index + 1]
        case .instagram:
            guard let kind = components.first, ["reel", "p"].contains(kind), components.count > 1 else { return nil }
            return components[1]
        case .twitch:
            return components.first
        case .spotify, .other:
            return nil
        }
    }

    private static func thumbnailURL(for mediaID: String?, platform: MediaPlatform) -> URL? {
        guard let mediaID, !mediaID.isEmpty else { return nil }
        guard platform == .youtube || platform == .youtubeMusic else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(mediaID)/mqdefault.jpg")
    }
}

@MainActor
protocol BrowserTabProviding {
    func listTabs() async throws -> [BrowserTab]
    func activate(tabID: String) async throws
    func activeTab() async throws -> BrowserTab?
}

enum BrowserTabProviderError: LocalizedError {
    case chromeUnavailable
    case scriptFailed(String)
    case tabNotFound

    var errorDescription: String? {
        switch self {
        case .chromeUnavailable: "Google Chrome is not running."
        case .scriptFailed(let message): "Chrome tab access failed: \(message)"
        case .tabNotFound: "That Chrome tab is no longer available."
        }
    }
}

/// Uses Chrome's scripting dictionary rather than Accessibility scraping. The
/// first actual call is what causes macOS to ask for Automation permission.
@MainActor
final class ChromeBrowserTabProvider: BrowserTabProviding {
    private var cachedTabs: [String: BrowserTab] = [:]

    func listTabs() async throws -> [BrowserTab] {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.google.Chrome" }) else {
            cachedTabs = [:]
            throw BrowserTabProviderError.chromeUnavailable
        }
        let script = """
        tell application "Google Chrome"
            set tabRows to {}
            set windowNumber to 0
            repeat with chromeWindow in windows
                set windowNumber to windowNumber + 1
                set currentTabIndex to active tab index of chromeWindow
                set tabNumber to 0
                repeat with chromeTab in tabs of chromeWindow
                    set tabNumber to tabNumber + 1
                    set end of tabRows to {windowNumber, tabNumber, title of chromeTab, URL of chromeTab, tabNumber is currentTabIndex}
                end repeat
            end repeat
            return tabRows
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error) else {
            throw BrowserTabProviderError.scriptFailed(error?.description ?? "No AppleScript result")
        }
        if let error { throw BrowserTabProviderError.scriptFailed(error.description) }

        guard result.numberOfItems > 0 else {
            cachedTabs = [:]
            return []
        }
        var tabs: [BrowserTab] = []
        for index in 1...result.numberOfItems {
            guard let row = result.atIndex(index), row.numberOfItems >= 5,
                  let title = row.atIndex(3)?.stringValue,
                  let urlString = row.atIndex(4)?.stringValue,
                  let url = URL(string: urlString) else { continue }
            let windowIndex = Int(row.atIndex(1)?.int32Value ?? 0)
            let tabIndex = Int(row.atIndex(2)?.int32Value ?? 0)
            guard windowIndex > 0, tabIndex > 0 else { continue }
            let tab = BrowserTab(
                id: "chrome:\(windowIndex):\(tabIndex):\(urlHash(url))",
                windowIndex: windowIndex,
                tabIndex: tabIndex,
                title: title,
                url: url,
                isActive: row.atIndex(5)?.booleanValue ?? false
            )
            tabs.append(tab)
        }
        cachedTabs = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        return tabs
    }

    func activate(tabID: String) async throws {
        let refreshedTabs = try await listTabs()
        let tab = cachedTabs[tabID] ?? refreshedTabs.first(where: { $0.id == tabID })
        guard let tab else { throw BrowserTabProviderError.tabNotFound }
        let script = """
        tell application "Google Chrome"
            set active tab index of window \(tab.windowIndex) to \(tab.tabIndex)
            set index of window \(tab.windowIndex) to 1
            activate
        end tell
        """
        var error: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { throw BrowserTabProviderError.scriptFailed(error.description) }
    }

    func activeTab() async throws -> BrowserTab? {
        let tabs = try await listTabs()
        return tabs.first(where: \.isActive)
    }

    private func urlHash(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// A local-only audio meter for the music surface in the notch. ScreenCaptureKit
/// supplies the same output mix the user hears, so this works for Spotify as
/// well as browser audio (YouTube, Instagram, X, and other sites). No samples
/// are retained, written to disk, or sent over the network.
@MainActor
final class NexusAudioReactiveMusic: NSObject, ObservableObject {
    struct Palette: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        /// Neutral fallback when source artwork has no usable dominant color.
        /// A music card should never randomly turn Nexus blue.
        static let defaultBlue = Palette(red: 0.86, green: 0.88, blue: 0.92)

        var color: Color {
            Color(red: red, green: green, blue: blue)
        }
    }

    struct SpotifyTrack: Equatable, Sendable {
        let title: String
        let artist: String
        let artworkURL: URL?
    }

    enum BrowserSource: Equatable, Sendable {
        case youtube(videoID: String?)
        case youtubeMusic(videoID: String?)
        case instagram
        case x
        case twitch

        var name: String {
            switch self {
            case .youtube: "YouTube"
            case .youtubeMusic: "YouTube Music"
            case .instagram: "Instagram"
            case .x: "X"
            case .twitch: "Twitch"
            }
        }

        var palette: Palette {
            switch self {
            case .youtube: .init(red: 1, green: 0.17, blue: 0.17)
            case .youtubeMusic: .init(red: 1, green: 0.12, blue: 0.20)
            case .instagram: .init(red: 0.83, green: 0.20, blue: 0.58)
            case .x: .init(red: 0.82, green: 0.90, blue: 1)
            case .twitch: .init(red: 0.60, green: 0.38, blue: 0.95)
            }
        }

        var videoThumbnailURL: URL? {
            let id: String?
            switch self {
            case .youtube(let value), .youtubeMusic(let value): id = value
            case .instagram, .x, .twitch: id = nil
            }
            guard let id, !id.isEmpty else { return nil }
            return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }

        var svg: Data {
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let suppliedAsset: URL = switch self {
            case .youtube, .youtubeMusic: downloads.appendingPathComponent("youtube-icon.svg")
            case .instagram: downloads.appendingPathComponent("instagram-2-1-logo-svgrepo-com.svg")
            case .x: downloads.appendingPathComponent("icons8-x-30.png")
            case .twitch: downloads.appendingPathComponent("twitch.svg")
            }
            // Prefer the user-supplied marks. The small inline versions below
            // remain only as a resilient fallback if Downloads is cleaned up.
            if let data = try? Data(contentsOf: suppliedAsset), !data.isEmpty {
                return data
            }
            let source: String = switch self {
            case .youtube, .youtubeMusic:
                "<svg viewBox=\"0 0 48 48\" xmlns=\"http://www.w3.org/2000/svg\"><rect x=\"4\" y=\"11\" width=\"40\" height=\"26\" rx=\"8\" fill=\"#ff2525\"/><path d=\"M20 17.5 32 24 20 30.5Z\" fill=\"white\"/></svg>"
            case .instagram:
                "<svg viewBox=\"0 0 48 48\" xmlns=\"http://www.w3.org/2000/svg\"><defs><linearGradient id=\"g\" x1=\"0\" y1=\"1\" x2=\"1\" y2=\"0\"><stop stop-color=\"#ffb72c\"/><stop offset=\".5\" stop-color=\"#e32688\"/><stop offset=\"1\" stop-color=\"#6547d9\"/></linearGradient></defs><rect x=\"6\" y=\"6\" width=\"36\" height=\"36\" rx=\"11\" fill=\"url(#g)\"/><circle cx=\"24\" cy=\"24\" r=\"8\" fill=\"none\" stroke=\"white\" stroke-width=\"3\"/><circle cx=\"34\" cy=\"14\" r=\"2\" fill=\"white\"/></svg>"
            case .x:
                "<svg viewBox=\"0 0 48 48\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M8 7h8l8.1 11.2L33.5 7H40l-13 14.8L41 41h-8l-9.8-13.4L11.4 41H5l14.1-16.1Z\" fill=\"#e8f3ff\"/></svg>"
            case .twitch:
                "<svg viewBox=\"0 0 48 48\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M10 6h31v24L30 41H19l-6 5v-5h-3Zm7 7v13h5v-13Zm12 0v13h5v-13Z\" fill=\"#a970ff\"/></svg>"
            }
            return Data(source.utf8)
        }

        init?(mediaTab: MediaTab) {
            switch mediaTab.platform {
            case .youtube:
                self = .youtube(videoID: mediaTab.mediaID)
            case .youtubeMusic:
                self = .youtubeMusic(videoID: mediaTab.mediaID)
            case .instagram:
                self = .instagram
            case .x:
                self = .x
            case .twitch:
                self = .twitch
            case .spotify, .other:
                return nil
            }
        }
    }

    enum CaptureState: Equatable, Sendable {
        case inactive
        case awaitingPermission
        case running
        case unavailable(String)
    }

    @Published private(set) var track: SpotifyTrack?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var palette = Palette.defaultBlue
    @Published private(set) var browserSource: BrowserSource?
    @Published private(set) var browserArtwork: NSImage?
    @Published private(set) var browserAccessError: String?
    @Published private(set) var energy: CGFloat = 0
    @Published private(set) var captureState: CaptureState = .inactive
    @Published private(set) var activeMediaTab: MediaTab?

    /// Keeps browser/video playback visible for a moment between quiet samples.
    private(set) var lastAudibleAt: Date?
    var hasAudibleSystemAudio: Bool {
        guard let lastAudibleAt else { return false }
        return Date().timeIntervalSince(lastAudibleAt) < 1.15
    }
    // A recognized active media page is enough to surface its card. This
    // avoids the old circular failure where the card was hidden until audio
    // capture had already proven it was playing.
    var isPlaying: Bool { track != nil || browserSource != nil || hasAudibleSystemAudio }
    var activeArtwork: NSImage? { track == nil ? browserArtwork : artwork }
    var activePalette: Palette { track == nil ? (browserSource?.palette ?? .defaultBlue) : palette }
    var activeYouTubeTab: MediaTab? {
        guard let activeMediaTab,
              activeMediaTab.platform == .youtube || activeMediaTab.platform == .youtubeMusic,
              activeMediaTab.mediaID?.isEmpty == false else { return nil }
        return activeMediaTab
    }
    private let sampleQueue = DispatchQueue(label: "na.nexus.audio-reactive.samples", qos: .userInteractive)
    private var stream: SCStream?
    private var spotifyTimer: Timer?
    private var artworkTask: Task<Void, Never>?
    private var browserArtworkTask: Task<Void, Never>?
    private var permissionRetryTask: Task<Void, Never>?
    private var isStartingCapture = false
    private var lastSpotifySignature = ""
    private let chromeTabs = ChromeBrowserTabProvider()
    private var chromePollTimer: Timer?
    private var chromePollTask: Task<Void, Never>?
    private var chromeWorkspaceObservers: [NSObjectProtocol] = []
    private var chromeSnapshotHash = ""
    private var notchIsExpanded = false

    func start() {
        guard spotifyTimer == nil else { return }
        refreshSpotify()
        refreshBrowserSource()
        installChromeWorkspaceObservers()
        rescheduleChromePolling()
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
        browserArtworkTask?.cancel()
        browserArtworkTask = nil
        permissionRetryTask?.cancel()
        permissionRetryTask = nil
        chromePollTimer?.invalidate()
        chromePollTimer = nil
        chromePollTask?.cancel()
        chromePollTask = nil
        chromeWorkspaceObservers.forEach(NotificationCenter.default.removeObserver)
        chromeWorkspaceObservers.removeAll()
        activeMediaTab = nil
        let activeStream = stream
        stream = nil
        captureState = .inactive
        Task { @MainActor in
            try? await activeStream?.stopCapture()
        }
    }

    /// A durable Nexus host can request Screen & System Audio Recording once;
    /// subsequent captures reuse that macOS grant and need no Spotify sign-in.
    func requestAndStartCaptureIfPossible() {
        guard stream == nil, !isStartingCapture else { return }
        guard CGPreflightScreenCaptureAccess() else {
            let host = NexusPermissionHostIdentity.current()
            guard host.isDurable else {
                captureState = .unavailable(host.statusMessage)
                return
            }
            captureState = .awaitingPermission
            guard NexusScreenCapture.requestAccess(prompt: true) else { return }
            // CGRequestScreenCaptureAccess returns while the privacy sheet is
            // still up on some macOS releases. Retry briefly so accepting it
            // starts the meter immediately rather than requiring an app restart.
            permissionRetryTask?.cancel()
            permissionRetryTask = Task { @MainActor [weak self] in
                for _ in 0..<20 {
                    // `Task.sleep(for:)` triggered inconsistent Swift 6
                    // diagnostics in Xcode's test compiler. Nanoseconds is
                    // available on every deployment target Nexus supports.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled, let self else { return }
                    if CGPreflightScreenCaptureAccess() {
                        self.requestAndStartCaptureIfPossible()
                        return
                    }
                }
            }
            return
        }
        isStartingCapture = true
        Task { @MainActor [weak self] in
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
        var scriptError: NSDictionary?
        let result = script?.executeAndReturnError(&scriptError).stringValue ?? ""
        guard scriptError == nil, !result.isEmpty else {
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
        refreshBrowserSource()
    }

    /// Controls the tab polling budget without Accessibility permissions.
    /// Chrome has no tab-change event stream, so state is published only when
    /// its complete tab snapshot changes.
    func setNotchExpanded(_ expanded: Bool) {
        guard notchIsExpanded != expanded else { return }
        notchIsExpanded = expanded
        rescheduleChromePolling()
    }

    /// Activates the real origin of the compact media card. Spotify is an app
    /// source; web platforms are existing Chrome tabs, never freshly opened
    /// URLs. Keeping this single entry point lets the notch artwork be a
    /// reliable "go back to it" control for every supported source.
    func activateCurrentMediaSource() async {
        if track != nil {
            activateSpotify()
            return
        }
        guard let tabID = activeMediaTab?.tab.id else { return }
        do {
            try await chromeTabs.activate(tabID: tabID)
        } catch {
            // The tab may have been closed after the card appeared. A refresh
            // removes stale state rather than opening a new URL.
        }
        await refreshChromeTabs(force: true)
    }

    private func activateSpotify() {
        if let spotify = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.spotify.client"
        }) {
            spotify.activate(options: [.activateIgnoringOtherApps])
            return
        }
        // The registered URL scheme works even when Spotify was installed in
        // a non-standard Applications folder. No account credential is read
        // or stored by Nexus.
        if let url = URL(string: "spotify:") {
            NSWorkspace.shared.open(url)
        }
    }

    private func installChromeWorkspaceObservers() {
        guard chromeWorkspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let handler: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                await self?.refreshChromeTabs(force: true)
                self?.rescheduleChromePolling()
            }
        }
        chromeWorkspaceObservers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: handler),
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: handler),
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: handler)
        ]
    }

    private func rescheduleChromePolling() {
        chromePollTimer?.invalidate()
        chromePollTimer = nil
        guard isChromeRunning else {
            updateChromeMedia(from: [])
            return
        }
        let interval: TimeInterval
        if notchIsExpanded {
            interval = 0.5
        } else if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" {
            interval = 1
        } else {
            interval = 4
        }
        chromePollTimer = Timer.scheduledTimer(
            timeInterval: interval,
            target: self,
            selector: #selector(refreshChromeTabsTimer),
            userInfo: nil,
            repeats: true
        )
        chromePollTimer?.tolerance = interval * 0.18
        Task { @MainActor [weak self] in await self?.refreshChromeTabs(force: false) }
    }

    @objc private func refreshChromeTabsTimer() {
        guard chromePollTask == nil else { return }
        chromePollTask = Task { @MainActor [weak self] in
            defer { self?.chromePollTask = nil }
            await self?.refreshChromeTabs(force: false)
        }
    }

    private var isChromeRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.google.Chrome" }
    }

    private func refreshChromeTabs(force: Bool) async {
        guard isChromeRunning else {
            chromeSnapshotHash = ""
            updateChromeMedia(from: [])
            return
        }
        do {
            let tabs = try await chromeTabs.listTabs()
            let snapshot = tabs
                .map { "\($0.windowIndex):\($0.tabIndex):\($0.url.absoluteString):\($0.isActive)" }
                .joined(separator: "|")
            guard force || snapshot != chromeSnapshotHash else { return }
            chromeSnapshotHash = snapshot
            browserAccessError = nil
            updateChromeMedia(from: tabs.compactMap(MediaTab.init))
        } catch {
            // A permission sheet, denied Automation grant, or temporary Chrome
            // scripting error must never make an already-visible media card
            // disappear. Keep the last verified tab until Chrome genuinely
            // exits or the next successful snapshot proves it closed.
            browserAccessError = error.localizedDescription
        }
    }

    private func updateChromeMedia(from mediaTabs: [MediaTab]) {
        let previousID = activeMediaTab?.id
        // A freshly active media tab is an explicit user selection. Once
        // Chrome goes into the background, retain that tab until it closes so
        // the card remains a reliable way back to it.
        let next = mediaTabs.first(where: { $0.tab.isActive })
            ?? mediaTabs.first(where: { $0.id == previousID })
            ?? mediaTabs.sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.tab.id < $1.tab.id
            }.first
        guard next != activeMediaTab else { return }
        activeMediaTab = next
        guard track == nil else { return }
        if let next {
            updateBrowserSource(BrowserSource(mediaTab: next))
        } else {
            updateBrowserSource(nil)
        }
    }

    private func refreshBrowserSource() {
        guard track == nil else { return }
        if isChromeRunning {
            Task { @MainActor [weak self] in await self?.refreshChromeTabs(force: false) }
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            updateBrowserSource(nil)
            return
        }
        let browserName: String?
        switch app.bundleIdentifier ?? "" {
        case "com.apple.Safari": browserName = "Safari"
        case "com.google.Chrome": browserName = "Google Chrome"
        case "com.microsoft.edgemac": browserName = "Microsoft Edge"
        case "company.thebrowser.Browser", "com.brave.Browser": browserName = "Brave Browser"
        default: browserName = nil
        }
        guard let browserName, let url = activeURL(in: browserName) else {
            updateBrowserSource(nil)
            return
        }
        let host = url.host?.lowercased() ?? ""
        if host.contains("youtube.com") || host == "youtu.be" {
            updateBrowserSource(.youtube(videoID: youtubeVideoID(from: url)))
        } else if host.contains("instagram.com") {
            updateBrowserSource(.instagram)
        } else if host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter.com") {
            updateBrowserSource(.x)
        } else {
            updateBrowserSource(nil)
        }
    }

    private func activeURL(in browserName: String) -> URL? {
        let script: String
        if browserName == "Safari" {
            script = "tell application \"Safari\" to return URL of current tab of front window"
        } else {
            script = "tell application \"\(browserName)\" to return URL of active tab of front window"
        }
        var scriptError: NSDictionary?
        let value = NSAppleScript(source: script)?.executeAndReturnError(&scriptError).stringValue
        guard scriptError == nil, let value, !value.isEmpty else { return nil }
        return URL(string: value)
    }

    private func youtubeVideoID(from url: URL) -> String? {
        if url.host?.lowercased() == "youtu.be" { return url.pathComponents.dropFirst().first }
        if url.path.hasPrefix("/shorts/") { return url.pathComponents.dropFirst().dropFirst().first }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value
    }

    private func updateBrowserSource(_ source: BrowserSource?) {
        guard source != browserSource else { return }
        browserSource = source
        browserArtworkTask?.cancel()
        browserArtwork = nil
        guard let thumbnailURL = source?.videoThumbnailURL else { return }
        browserArtworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: thumbnailURL),
                  !Task.isCancelled,
                  let image = NSImage(data: data) else { return }
            browserArtwork = image
        }
    }

    private func loadArtwork(from url: URL?) {
        artworkTask?.cancel()
        artwork = nil
        palette = .defaultBlue
        guard let url else { return }
        artworkTask = Task { @MainActor [weak self] in
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
        draw(
            in: NSRect(x: 0, y: 0, width: 1, height: 1),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
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
