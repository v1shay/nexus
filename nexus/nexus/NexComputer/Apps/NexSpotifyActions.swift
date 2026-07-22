import AppKit
import Foundation

struct NexSpotifyPlaybackSnapshot: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    let uri: String
    let state: String
    let volume: Int
}

protocol NexSpotifyControlling: Sendable {
    func open() async throws
    func openSearch(query: String) async throws
    func play(uri: String) async throws
    func control(_ command: String) async throws
    func setVolume(_ volume: Int) async throws
    func currentTrack() async throws -> NexSpotifyPlaybackSnapshot
}

enum NexSpotifyError: LocalizedError, Equatable {
    case unavailable
    case invalidQuery
    case exactResolutionUnavailable(String)
    case automation(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Spotify is not installed."
        case .invalidQuery: "A Spotify search query or exact Spotify URL/URI is required."
        case .exactResolutionUnavailable(let query): "Opened Spotify search for “\(query)”, but exact playback resolution cannot be verified without a resolved Spotify URI."
        case .automation(let message): "Spotify automation failed: \(message)"
        }
    }
}

final class NexSpotifyDesktopController: NexSpotifyControlling, @unchecked Sendable {
    func open() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else { throw NexSpotifyError.unavailable }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func openSearch(query: String) async throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NexSpotifyError.invalidQuery }
        try await open()
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/#?&")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "spotify:search:\(encoded)"), NSWorkspace.shared.open(url) else {
            throw NexSpotifyError.automation("Spotify rejected the search URL.")
        }
    }

    func play(uri: String) async throws {
        let normalized = Self.spotifyURI(uri)
        guard normalized.hasPrefix("spotify:track:") || normalized.hasPrefix("spotify:album:") || normalized.hasPrefix("spotify:artist:") || normalized.hasPrefix("spotify:playlist:") else {
            throw NexSpotifyError.invalidQuery
        }
        _ = try script("tell application \"Spotify\" to play track \"\(Self.escape(normalized))\"")
    }

    func control(_ command: String) async throws {
        let statement: String
        switch command {
        case "pause": statement = "pause"
        case "resume": statement = "play"
        case "toggle": statement = "playpause"
        case "next": statement = "next track"
        case "previous": statement = "previous track"
        case "volume_up": statement = "set sound volume to (sound volume + 10)"
        case "volume_down": statement = "set sound volume to (sound volume - 10)"
        default: throw NexToolError.invalidEnum(field: "command", allowed: ["pause", "resume", "toggle", "next", "previous", "volume_up", "volume_down"])
        }
        _ = try script("tell application \"Spotify\" to \(statement)")
    }

    func setVolume(_ volume: Int) async throws {
        _ = try script("tell application \"Spotify\" to set sound volume to \(min(max(volume, 0), 100))")
    }

    func currentTrack() async throws -> NexSpotifyPlaybackSnapshot {
        let output = try script("""
        tell application "Spotify"
            if player state is stopped then return "|||stopped|" & (sound volume as text)
            set t to current track
            return (name of t) & "|" & (artist of t) & "|" & (album of t) & "|" & (spotify url of t) & "|" & (player state as text) & "|" & (sound volume as text)
        end tell
        """)
        let parts = output.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 6 else { throw NexSpotifyError.automation("Spotify returned malformed track metadata.") }
        return .init(title: parts[0], artist: parts[1], album: parts[2], uri: parts[3], state: parts[4], volume: Int(parts[5]) ?? 0)
    }

    private func script(_ source: String) throws -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { throw NexSpotifyError.automation(error[NSAppleScript.errorMessage] as? String ?? error.description) }
        return result?.stringValue ?? ""
    }

    private static func spotifyURI(_ value: String) -> String {
        guard let url = URL(string: value), url.host == "open.spotify.com" else { return value }
        let pieces = url.pathComponents.filter { $0 != "/" }
        guard pieces.count >= 2 else { return value }
        return "spotify:\(pieces[0]):\(pieces[1])"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

actor NexSpotifyActionCatalog {
    private let controller: any NexSpotifyControlling
    private var registered = false

    init(controller: any NexSpotifyControlling = NexSpotifyDesktopController()) { self.controller = controller }

    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }
        let controller = controller
        try await registry.register(manifest: Self.openManifest) { _, _ in
            try await controller.open(); return Self.result(display: "Opened Spotify.", status: "opened")
        }
        try await registry.register(manifest: Self.searchManifest) { arguments, _ in
            guard let query = arguments["query"]?.string else { throw NexToolError.missingField("query") }
            try await controller.openSearch(query: query)
            return Self.result(display: "Opened Spotify search for “\(query)”.", status: "search_opened", query: query, resolved: false)
        }
        try await registry.register(manifest: Self.playManifest) { arguments, _ in
            guard let query = arguments["query"]?.string else { throw NexToolError.missingField("query") }
            if query.hasPrefix("spotify:") || query.contains("open.spotify.com/") {
                try await controller.play(uri: query)
                let track = try? await controller.currentTrack()
                return Self.result(display: "Started Spotify playback.", status: "playing", query: query, resolved: track != nil, track: track)
            }
            let artist = arguments["artist"]?.string
            let search = [query, artist].compactMap { $0 }.joined(separator: " ")
            try await controller.openSearch(query: search)
            return Self.result(
                display: "Opened the best available Spotify search for “\(search)”. Choose a result before playback; exact resolution was not fabricated.",
                status: "resolution_required", query: search, resolved: false
            )
        }
        try await registry.register(manifest: Self.controlManifest) { arguments, _ in
            guard let command = arguments["command"]?.string else { throw NexToolError.missingField("command") }
            try await controller.control(command)
            return Self.result(display: "Spotify: \(command.replacingOccurrences(of: "_", with: " ")).", status: command)
        }
        try await registry.register(manifest: Self.volumeManifest) { arguments, _ in
            guard let volume = arguments["volume"]?.integer else { throw NexToolError.missingField("volume") }
            try await controller.setVolume(volume)
            return Self.result(display: "Set Spotify volume to \(volume)%.", status: "volume_set", volume: volume)
        }
        try await registry.register(manifest: Self.trackManifest) { _, _ in
            let track = try await controller.currentTrack()
            return Self.result(display: track.title.isEmpty ? "Spotify is stopped." : "\(track.title) — \(track.artist)", status: track.state, resolved: true, track: track)
        }
        registered = true
    }

    private static func result(
        display: String,
        status: String,
        query: String = "",
        resolved: Bool = true,
        volume: Int? = nil,
        track: NexSpotifyPlaybackSnapshot? = nil
    ) -> NexJSONValue {
        .object([
            "display": .string(display), "status": .string(status), "query": .string(query), "resolved": .bool(resolved),
            "title": .string(track?.title ?? ""), "artist": .string(track?.artist ?? ""), "album": .string(track?.album ?? ""),
            "uri": .string(track?.uri ?? ""), "volume": .number(Double(volume ?? track?.volume ?? 0))
        ])
    }

    private static let output = NexToolInputSchema(fields: [
        "display": .init(.string, required: true), "status": .init(.string, required: true), "query": .init(.string, required: true),
        "resolved": .init(.boolean, required: true), "title": .init(.string, required: true), "artist": .init(.string, required: true),
        "album": .init(.string, required: true), "uri": .init(.string, required: true), "volume": .init(.integer, required: true)
    ])
    private static let controls = ["pause", "resume", "toggle", "next", "previous", "volume_up", "volume_down"]
    private static let types = ["track", "album", "artist", "playlist", "auto"]
    private static let openManifest = manifest("spotify.open", "Open or activate the Spotify desktop app.", ["Open Spotify"], .init(fields: [:]))
    private static let searchManifest = manifest("spotify.search", "Open a precise search in Spotify and report that the result is unresolved until Spotify supplies an exact URI.", ["Search Spotify for Summer by Calvin Harris"], .init(fields: ["query": .init(.string, required: true)]))
    private static let playManifest = manifest("spotify.play", "Play an exact Spotify URL or URI, or open a name-and-artist search without falsely claiming which result played.", ["Play this Spotify link", "Find Summer by Calvin Harris"], .init(fields: [
        "query": .init(.string, required: true), "artist": .init(.string), "type": .init(.string, allowedValues: types), "shuffle": .init(.boolean)
    ]))
    private static let controlManifest = manifest("spotify.control", "Pause, resume, toggle, skip, go to the previous track, or adjust Spotify volume by ten percent.", ["Pause Spotify", "Skip this song"], .init(fields: ["command": .init(.string, required: true, allowedValues: controls)]))
    private static let volumeManifest = manifest("spotify.set_volume", "Set Spotify's exact playback volume from zero to one hundred.", ["Set Spotify volume to 35 percent"], .init(fields: ["volume": .init(.integer, required: true, minimum: 0, maximum: 100)]))
    private static let trackManifest = manifest("spotify.get_current_track", "Read Spotify's current track, artist, album, playback state, URI, and volume.", ["What is playing on Spotify?"], .init(fields: [:]))
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ input: NexToolInputSchema) -> NexComputerActionManifest {
        .init(actionID: id, application: "Spotify", provider: "Spotify Desktop", bundleIdentifier: "com.spotify.client", description: description,
              examples: examples, aliases: [id.replacingOccurrences(of: ".", with: " ")], tags: ["spotify", "music", "playback", "playlist", "song"],
              inputSchema: input, outputSchema: output, implementationMethod: .appleScript,
              requiredPermissions: [.init(id: "automation.com.spotify.client", permission: .automation)], registryPermission: .automation,
              riskClass: .low, confirmationPolicy: .never, availabilityCheck: .application(bundleIdentifier: "com.spotify.client"), timeoutSeconds: 15,
              supportsCancellation: false, dryRunBehavior: .supported("Would perform \(id) in Spotify."), previewRenderer: "spotify.playback", tests: ["NexSpotifyActionTests"])
    }
}
