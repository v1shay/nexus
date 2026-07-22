import Foundation

/// A deliberately narrow, media-only command path.  Once Nex is already
/// playing a YouTube video, these spoken phrases should control the player
/// immediately instead of waiting for an LLM tool-planning round trip.
enum NexMediaVoiceCommand {
    static func requestsFullscreen(_ prompt: String) -> Bool {
        let normalized = prompt
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let explicitPhrases = [
            "full screen",
            "fullscreen",
            "full scren",
            "full size",
            "make it big",
            "make it bigger",
            "make this big",
            "make this bigger"
        ]

        return normalized.split(separator: " ").contains("enlarge")
            || explicitPhrases.contains { normalized.contains($0) }
    }
}

struct NexYouTubeCandidate: Codable, Equatable, Sendable {
    let videoID: String
    let title: String

    var url: URL {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
    }

    var toolValue: NexJSONValue {
        .object([
            "video_id": .string(videoID),
            "title": .string(title),
            "url": .string(url.absoluteString)
        ])
    }
}

enum NexYouTubeSearchError: LocalizedError {
    case noResults
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noResults: "YouTube did not return playable video results for that request."
        case .invalidResponse: "Nex could not read YouTube’s search response."
        }
    }
}

/// Local, API-key-free YouTube discovery. This only identifies public video
/// IDs from YouTube's own search page; it never downloads or extracts media.
struct NexYouTubeSearchService: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String, limit: Int = 5) async throws -> [NexYouTubeCandidate] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw NexToolError.missingField("query") }
        guard var components = URLComponents(string: "https://www.youtube.com/results") else {
            throw NexYouTubeSearchError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "search_query", value: normalized)]
        guard let url = components.url else { throw NexYouTubeSearchError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw NexYouTubeSearchError.invalidResponse
        }

        let ids = Self.videoIDs(in: html, limit: limit)
        guard !ids.isEmpty else { throw NexYouTubeSearchError.noResults }
        var candidates: [NexYouTubeCandidate] = []
        for id in ids {
            let title = (try? await title(for: id)) ?? "YouTube video \(id)"
            candidates.append(.init(videoID: id, title: title))
        }
        return candidates
    }

    static func videoIDs(in html: String, limit: Int = 5) -> [String] {
        let pattern = #"\"videoId\":\"([A-Za-z0-9_-]{11})\""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        return expression.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges == 2,
                  let idRange = Range(match.range(at: 1), in: html) else { return nil }
            let id = String(html[idRange])
            return seen.insert(id).inserted ? id : nil
        }.prefix(max(1, limit)).map { $0 }
    }

    private func title(for videoID: String) async throws -> String {
        guard var components = URLComponents(string: "https://www.youtube.com/oembed") else {
            throw NexYouTubeSearchError.invalidResponse
        }
        components.queryItems = [
            .init(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            .init(name: "format", value: "json")
        ]
        guard let url = components.url else { throw NexYouTubeSearchError.invalidResponse }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NexYouTubeSearchError.invalidResponse
        }
        let value = try JSONDecoder().decode(OEmbedResponse.self, from: data)
        return value.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct OEmbedResponse: Decodable {
        let title: String
    }
}

/// Registers media actions through the same validated registry used by memory,
/// web, and NexCLI. The UI receives a selected `MediaTab` only after a tool's
/// strict schema has accepted its arguments.
@MainActor
final class NexYouTubeToolController {
    typealias PlaybackHandler = @MainActor (MediaTab?, Bool) -> Bool

    private let registry: NexToolRegistry
    private let browserTabs: any BrowserTabProviding
    private let searchService: NexYouTubeSearchService
    private let onPlaybackRequested: PlaybackHandler
    private var isRegistered = false

    init(
        registry: NexToolRegistry,
        browserTabs: (any BrowserTabProviding)? = nil,
        searchService: NexYouTubeSearchService = .init(),
        onPlaybackRequested: @escaping PlaybackHandler
    ) {
        self.registry = registry
        self.browserTabs = browserTabs ?? ChromeBrowserTabProvider()
        self.searchService = searchService
        self.onPlaybackRequested = onPlaybackRequested
    }

    func registerIfNeeded() async throws {
        guard !isRegistered else { return }
        try await registerCurrentTabTool()
        try await registerSearchTool()
        try await registerPlayTool()
        try await registerFullscreenTool()
        isRegistered = true
    }

    private func registerCurrentTabTool() async throws {
        try await register(.init(
            name: "youtube_play_current",
            description: "Play the currently active Google Chrome YouTube or YouTube Music video inside the Nex media overlay. Use when the user asks to play, show, or continue the video already open in Chrome.",
            statusLabel: "Opening the current YouTube video…",
            completionLabel: "Playing YouTube",
            spokenStatus: "Opening the current YouTube video.",
            iconSystemName: "play.rectangle.fill",
            permission: .automation,
            schema: .init(fields: [:]),
            application: "YouTube",
            provider: "Google Chrome",
            examples: ["Play the YouTube video I already have open", "Continue this video in the notch"],
            aliases: ["play current video", "show this YouTube tab", "continue video"],
            tags: ["YouTube", "video", "playback", "Chrome", "media"],
            handler: { [weak self] _, _ in
                guard let self else {
                    throw NexToolError.executionFailed(code: "youtube_unavailable", message: "YouTube playback is unavailable.")
                }
                return try await self.playCurrentChromeVideo()
            }
        ))
    }

    private func registerSearchTool() async throws {
        try await register(.init(
            name: "youtube_search",
            description: "Find public YouTube videos for a user request. Returns a compact candidate list with stable video_id values. After receiving candidates, call youtube_play with one returned video_id to start playback.",
            statusLabel: "Searching YouTube…",
            completionLabel: "Found YouTube videos",
            spokenStatus: "Searching YouTube.",
            iconSystemName: "play.rectangle.fill",
            permission: .network,
            schema: .init(fields: ["query": .init(.string, required: true, description: "Standalone description of the YouTube video to find.")]),
            application: "YouTube",
            provider: "YouTube search",
            examples: ["Find a calculus tutorial to play", "Play a video about robotic arms"],
            aliases: ["find a YouTube video", "search YouTube", "find a video"],
            tags: ["YouTube", "video", "search", "media"],
            handler: { [searchService] arguments, context in
                guard let query = arguments["query"]?.string else { throw NexToolError.missingField("query") }
                await context.reportProgress("Looking for matching videos…", 0.25)
                let candidates = try await searchService.search(query: query)
                await context.reportProgress("Selecting playable results…", 0.9)
                return .object([
                    "query": .string(query),
                    "count": .number(Double(candidates.count)),
                    "results": .array(candidates.map(\.toolValue))
                ])
            }
        ))
    }

    private func registerPlayTool() async throws {
        try await register(.init(
            name: "youtube_play",
            description: "Play one YouTube search candidate in Nex. video_id must be a stable 11-character ID returned by youtube_search; do not invent one.",
            statusLabel: "Starting YouTube…",
            completionLabel: "Playing YouTube",
            spokenStatus: "Starting YouTube.",
            iconSystemName: "play.rectangle.fill",
            permission: .automation,
            schema: .init(fields: ["video_id": .init(.string, required: true, description: "Stable video ID returned by youtube_search.")]),
            application: "YouTube",
            provider: "Nex media overlay",
            examples: ["Play the selected YouTube search result"],
            aliases: ["play selected video", "start YouTube result"],
            tags: ["YouTube", "video", "playback", "media"],
            handler: { [weak self] arguments, _ in
                guard let self else {
                    throw NexToolError.executionFailed(code: "youtube_unavailable", message: "YouTube playback is unavailable.")
                }
                guard let videoID = arguments["video_id"]?.string else { throw NexToolError.missingField("video_id") }
                return try await self.play(videoID: videoID)
            }
        ))
    }

    private func registerFullscreenTool() async throws {
        try await register(.init(
            name: "youtube_fullscreen",
            description: "Make the currently playing Nex YouTube overlay fill the screen. Use only after Nex has already opened a YouTube video.",
            statusLabel: "Expanding YouTube…",
            completionLabel: "Expanded YouTube",
            spokenStatus: "Making the video full screen.",
            iconSystemName: "arrow.up.left.and.arrow.down.right",
            permission: .automation,
            schema: .init(fields: [:]),
            application: "YouTube",
            provider: "Nex media overlay",
            examples: ["Make this YouTube video full screen", "Enlarge the playing video"],
            aliases: ["full screen video", "enlarge video", "make video bigger"],
            tags: ["YouTube", "video", "fullscreen", "media"],
            handler: { [weak self] _, _ in
                guard let self else {
                    throw NexToolError.executionFailed(code: "youtube_unavailable", message: "YouTube playback is unavailable.")
                }
                return try await self.makeFullscreen()
            }
        ))
    }

    private func playCurrentChromeVideo() async throws -> NexJSONValue {
        guard let tab = try await browserTabs.activeTab(), let media = MediaTab(tab: tab),
              media.platform == .youtube || media.platform == .youtubeMusic,
              let videoID = media.mediaID else {
            throw NexToolError.executionFailed(
                code: "youtube_current_tab_required",
                message: "Open a YouTube video in the active Google Chrome tab first."
            )
        }
        guard onPlaybackRequested(media, false) else {
            throw NexToolError.executionFailed(code: "youtube_presentation_unavailable", message: "Nex could not open the YouTube player.")
        }
        return NexYouTubeCandidate(videoID: videoID, title: tab.title).toolValue
    }

    private func play(videoID: String) async throws -> NexJSONValue {
        guard Self.isValidVideoID(videoID) else {
            throw NexToolError.executionFailed(
                code: "youtube_invalid_video_id",
                message: "YouTube video_id must be an 11-character ID returned by youtube_search."
            )
        }
        let candidate = NexYouTubeCandidate(videoID: videoID, title: "YouTube video \(videoID)")
        let tab = BrowserTab(
            id: "nex:youtube:\(videoID)",
            windowIndex: 0,
            tabIndex: 0,
            title: candidate.title,
            url: candidate.url,
            isActive: false
        )
        guard let media = MediaTab(tab: tab) else {
            throw NexToolError.executionFailed(code: "youtube_invalid_video_id", message: "Nex could not open that YouTube video.")
        }
        guard onPlaybackRequested(media, false) else {
            throw NexToolError.executionFailed(code: "youtube_presentation_unavailable", message: "Nex could not open the YouTube player.")
        }
        return candidate.toolValue
    }

    private func makeFullscreen() async throws -> NexJSONValue {
        // The controller validates that a player exists before it applies the
        // presentation change. This callback deliberately carries no URL.
        guard onPlaybackRequested(nil, true) else {
            throw NexToolError.executionFailed(code: "youtube_player_required", message: "Play a YouTube video in Nex before requesting full screen.")
        }
        return .object(["fullscreen": .bool(true)])
    }

    private func register(_ tool: NexRegisteredTool) async throws {
        do {
            try await registry.register(tool)
        } catch NexToolError.duplicateRegistration {
            // A shared registry can legitimately be prepared twice during an
            // app lifecycle; retain idempotent registration semantics.
        }
    }

    nonisolated static func isValidVideoID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil
    }
}
