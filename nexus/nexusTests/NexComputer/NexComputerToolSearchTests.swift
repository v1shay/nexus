import XCTest
@testable import nexus

final class NexComputerToolSearchTests: XCTestCase {
    private let engine = NexToolSearchEngine()

    func testRanksNamesDescriptionsExamplesAliasesTagsFieldsAndWorkflows() {
        let playlist = tool(
            name: "spotify.play_playlist",
            description: "Play a selected Spotify playlist.",
            application: "Spotify",
            provider: "Spotify Connect",
            examples: ["Play my summer playlist"],
            aliases: ["put on music"],
            tags: ["music", "playlist"],
            workflows: ["music playback"]
        )
        let calendar = tool(
            name: "calendar.create_event",
            description: "Create a calendar event.",
            application: "Calendar",
            provider: "EventKit",
            tags: ["schedule"]
        )

        XCTAssertEqual(search("play my summer playlist", [playlist, calendar]).map(\.tool), ["spotify.play_playlist"])
        XCTAssertEqual(search("put on music", [playlist, calendar]).map(\.tool), ["spotify.play_playlist"])
        XCTAssertEqual(search("Spotify music playback", [playlist, calendar]).map(\.tool), ["spotify.play_playlist"])
    }

    func testCompoundRequestReturnsStrongCandidateForEachIndependentClause() {
        let web = tool(
            name: "web.search",
            description: "Search current public information and weather.",
            application: "Web",
            provider: "Search",
            tags: ["current", "weather"]
        )
        let mail = tool(
            name: "mail.send",
            description: "Send an email message to a recipient.",
            application: "Mail",
            provider: "Gmail",
            tags: ["email", "message"]
        )

        let names = Set(search("find tomorrow's weather and email the result", [web, mail]).map(\.tool))
        XCTAssertEqual(names, ["web.search", "mail.send"])
    }

    func testEnforcesTopKAndSuppressesIrrelevantTools() {
        let tools = (0..<7).map { index in
            tool(
                name: "music.action_\(index)",
                description: "Play music playlist variation \(index).",
                application: "Music",
                provider: "Fixture",
                tags: ["music", "playlist"]
            )
        }
        XCTAssertEqual(search("play music", tools, maximumResults: 3).count, 3)
        XCTAssertTrue(search("explain mitochondrial inheritance", tools).isEmpty)
    }

    func testUnavailableActionsAreOmittedOrClearlyMarked() {
        let unavailable = NexToolSearchEngine.Document(
            tool: tool(
                name: "slack.send_message",
                description: "Send a Slack message.",
                application: "Slack",
                provider: "Slack API",
                tags: ["Slack", "message"]
            ),
            isAvailable: false,
            unavailableReason: "Slack is not connected."
        )
        XCTAssertTrue(engine.search(query: "send Slack message", documents: [unavailable]).candidates.isEmpty)

        let included = engine.search(
            query: "send Slack message",
            documents: [unavailable],
            availabilityPolicy: .includeUnavailable
        ).candidates
        XCTAssertEqual(included.first?.tool, "slack.send_message")
        XCTAssertEqual(included.first?.isAvailable, false)
        XCTAssertEqual(included.first?.unavailableReason, "Slack is not connected.")
    }

    func testDuplicateSemanticActionsCollapseDeterministically() {
        let first = tool(
            name: "mail.compose",
            description: "Create and send an email.",
            application: "Mail",
            provider: "Native",
            tags: ["email"]
        )
        let duplicate = tool(
            name: "mail.send",
            description: "Create and send an email.",
            application: "Mail",
            provider: "Native",
            tags: ["email"]
        )
        XCTAssertEqual(search("send an email", [duplicate, first]).map(\.tool), ["mail.compose"])
    }

    func testInternalSearchActionUsesSharedRegistryAndReturnsExplicitAllowlist() async throws {
        let registry = NexToolRegistry()
        try await registry.register(tool(
            name: "notes.create",
            description: "Create a note.",
            application: "Notes",
            provider: "Native",
            tags: ["note", "writing"]
        ))
        let service = NexToolSearchService(registry: registry)
        try await service.registerIfNeeded()

        let result = try await registry.execute(
            name: NexToolSearchService.actionName,
            arguments: ["query": .string("write a note")],
            invocation: .modelDiscovery
        )
        guard case .object(let object) = result,
              case .array(let candidates) = object["candidates"],
              case .object(let first) = candidates.first else {
            return XCTFail("Expected a structured candidate list")
        }
        XCTAssertEqual(first["tool"], .string("notes.create"))
        XCTAssertFalse(candidates.contains { candidate in
            guard case .object(let fields) = candidate else { return false }
            return fields["tool"] == .string(NexToolSearchService.actionName)
        })
    }

    func testPlannerRejectsRegisteredButUndiscoveredAction() {
        let web = tool(
            name: "web_search",
            description: "Search current public information.",
            application: "Web",
            provider: "Search",
            tags: ["current", "search"]
        )
        let memory = tool(
            name: "memory_search",
            description: "Search saved personal memory.",
            application: "Obsidian",
            provider: "Memory",
            tags: ["personal", "memory"]
        )
        let raw = #"{"actions":[{"tool":"memory_search","arguments":{"query":"private profile"}}],"memory_write":null}"#
        XCTAssertTrue(NexPrimaryToolPlanner.parse(raw, registeredTools: [web]).actions.isEmpty)
        XCTAssertEqual(
            NexPrimaryToolPlanner.parse(raw, registeredTools: [web, memory]).actions.map(\.tool),
            ["memory_search"]
        )
    }

    private func search(
        _ query: String,
        _ tools: [NexRegisteredTool],
        maximumResults: Int = NexToolSearchEngine.defaultMaximumResults
    ) -> [NexToolSearchCandidate] {
        engine.search(
            query: query,
            documents: tools.map { NexToolSearchEngine.Document(tool: $0) },
            maximumResults: maximumResults
        ).candidates
    }

    private func tool(
        name: String,
        description: String,
        application: String,
        provider: String,
        examples: [String] = [],
        aliases: [String] = [],
        tags: [String] = [],
        workflows: [String] = []
    ) -> NexRegisteredTool {
        .init(
            name: name,
            description: description,
            statusLabel: "Working…",
            spokenStatus: "Working.",
            iconSystemName: "gearshape",
            permission: .automation,
            schema: .init(fields: [
                "query": .init(.string, description: "What to find or act on.")
            ]),
            application: application,
            provider: provider,
            examples: examples,
            aliases: aliases,
            tags: tags,
            supportedWorkflows: workflows
        ) { _, _ in .object([:]) }
    }
}
