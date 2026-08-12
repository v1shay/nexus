import XCTest
@testable import nexus

final class NexComputerToolSearchTests: XCTestCase {
    private let engine = NexToolSearchEngine()

    func testPermissionHostRequiresAStableNexusSigningIdentity() {
        XCTAssertTrue(
            NexusPermissionSigningIdentity(bundleIdentifier: "na.nexus", requirementHash: "development", hasCertificate: true, certificateSubject: "Apple Development: Nexus", diagnostic: nil).isDurable
        )
        XCTAssertFalse(
            NexusPermissionSigningIdentity(bundleIdentifier: "na.nexus", requirementHash: "", hasCertificate: false, certificateSubject: "", diagnostic: nil).isDurable
        )
        XCTAssertFalse(
            NexusPermissionSigningIdentity(bundleIdentifier: "com.example.other", requirementHash: "development", hasCertificate: true, certificateSubject: "Apple Development: Other", diagnostic: nil).isDurable
        )
    }

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

    func testCompoundRequestPreservesAClauseLeaderAgainstNearbyAlternatives() {
        let network = tool(
            name: "system.get_network_state",
            description: "Read whether this Mac is online and connected to the network.",
            application: "macOS",
            provider: "System",
            examples: ["Is my Mac online?"],
            tags: ["network", "online"]
        )
        let battery = tool(
            name: "system.get_battery",
            description: "Read the Mac battery and power source.",
            application: "macOS",
            provider: "System",
            examples: ["How much battery is left?"],
            tags: ["battery", "power"]
        )
        let volume = tool(
            name: "system.get_volume",
            description: "Read the output volume.",
            application: "macOS",
            provider: "System",
            examples: ["What is the volume?"],
            tags: ["volume", "sound"]
        )
        let spotify = tool(
            name: "spotify.get_current_track",
            description: "Read the current Spotify track and volume.",
            application: "Spotify",
            provider: "Spotify",
            tags: ["music", "track", "volume"]
        )

        let names = Set(search(
            "Tell me whether this Mac is online, whether it is on battery power, and what the current output volume is.",
            [network, battery, volume, spotify]
        ).map(\.tool))
        XCTAssertEqual(names, [network.name, battery.name, volume.name])
    }

    func testAgenticBrowserRequestRanksManagedBrowserInsteadOfWebResearch() {
        let web = tool(
            name: "web_search",
            description: "Search current public facts and return source results.",
            application: "Web",
            provider: "Search",
            tags: ["web", "research", "sources"]
        )
        let browser = tool(
            name: "browser.run_task",
            description: "Run an agentic Nexus managed browser task that visits a URL, navigates a site, clicks, fills forms, downloads, and extracts a webpage.",
            application: "Chrome",
            provider: "Managed Playwright",
            examples: ["Use your browser to inspect this website"],
            tags: ["browser", "website", "navigate", "url", "click", "download"]
        )
        let candidates = search("Use your browser to inspect https://example.com and return the heading", [web, browser])
        XCTAssertEqual(candidates.first?.tool, "browser.run_task")
    }

    func testSimpleExplicitBrowserVisitRanksSimpleURLActionInsteadOfWebResearch() {
        let web = tool(
            name: "web_search",
            description: "Search current public facts and return source results.",
            application: "Web",
            provider: "Search",
            tags: ["web", "research", "sources"]
        )
        let visit = tool(
            name: "browser.visit_url",
            description: "Visit one HTTP(S) page in Nexus managed browser and return readable page text.",
            application: "Chrome",
            provider: "Managed Playwright",
            examples: ["Use Nexus browser to inspect https://example.com"],
            tags: ["browser", "website", "navigate", "url", "inspect"]
        )
        XCTAssertEqual(
            search("Use Nexus browser to visit https://example.com and read the page", [web, visit]).first?.tool,
            "browser.visit_url"
        )
    }

    func testOwnerNameReferenceRanksADeclaredOwnerNameSchema() {
        let application = tool(
            name: "applications.open",
            description: "Open an installed application by bundle identifier.",
            application: "Applications",
            provider: "LaunchServices",
            tags: ["open", "application"]
        )
        let repository = tool(
            name: "github.open_repository",
            description: "Open an exact hosted repository URL or name.",
            application: "GitHub",
            provider: "CLI",
            tags: ["repository"],
            fields: ["repository": .init(.string, required: true, description: "Exact repository in owner/name form.")]
        )
        XCTAssertEqual(
            search("Open v1shay/nexusV2", [application, repository]).first?.tool,
            "github.open_repository"
        )
    }

    func testSemanticCapabilityLookupFindsMessagesForNaturalTextingIntent() {
        let messages = tool(
            name: "messages.draft",
            description: "Create a draft message for a resolved recipient.",
            application: "Messages",
            provider: "Apple Messages",
            tags: ["imessage", "sms", "contact", "chat"]
        )
        let calendar = tool(
            name: "calendar.create_event",
            description: "Create a calendar event.",
            application: "Calendar",
            provider: "EventKit",
            tags: ["schedule", "event"]
        )

        // “text” intentionally does not appear in the Messages manifest.
        // The registry's on-device semantic fallback must still surface the
        // actual Messages action instead of letting the model deny the task.
        XCTAssertEqual(
            search("text someone that they need to get milk", [messages, calendar]).first?.tool,
            "messages.draft"
        )
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

    func testDefaultNativeAllowlistStaysFocusedAtThreeCandidates() {
        let tools = (0..<5).map { index in
            tool(
                name: "notes.action_\(index)",
                description: "Create and organize Markdown notes variation \(index).",
                application: "Notes",
                provider: "Fixture",
                tags: ["notes", "markdown"]
            )
        }
        XCTAssertEqual(search("organize a Markdown note", tools).count, 3)
    }

    func testAbsolutePathDoesNotOutrankFilesystemIntent() {
        let finder = tool(
            name: "finder.search",
            description: "Search an allowed folder by filename and text content.",
            application: "Finder",
            provider: "Nexus Native Files",
            tags: ["file", "folder", "filesystem", "search"]
        )
        let confirmation = tool(
            name: "cancel_action",
            description: "Cancel one pending Nexus action.",
            application: "Nex",
            provider: "Nexus Confirmation Gateway",
            tags: ["confirmation", "cancel"]
        )
        XCTAssertEqual(
            search("In /Users/example/Documents/nexus workspace, find files named Validation", [finder, confirmation]).first?.tool,
            "finder.search"
        )
    }

    func testMarkdownFileInAbsoluteFolderRanksFinderInsteadOfObsidian() {
        let finder = tool(
            name: "finder.search",
            description: "Search an allowed local folder by filename, extension (including Markdown), and text content.",
            application: "Finder",
            provider: "Nexus Native Files",
            examples: ["Find a Markdown file in this folder"],
            tags: ["file", "folder", "filesystem"],
            fields: ["root": .init(.string, required: true, description: "Absolute existing local folder to search. Preserve every supplied path segment, including spaces.")]
        )
        let obsidian = tool(
            name: "obsidian.search",
            description: "Search canonical Markdown notes by title and content inside the configured vault.",
            application: "Obsidian",
            provider: "Obsidian Vault",
            tags: ["notes", "markdown", "vault"]
        )

        XCTAssertEqual(
            search(
                "Find the generated Markdown note named FINDER_SOURCE in /Users/example/Documents/validation-fixtures/Finder Lifecycle Proof.",
                [finder, obsidian]
            ).first?.tool,
            "finder.search"
        )
    }

    func testAbsoluteXcodeProjectPathRanksBuildInsteadOfFinder() {
        let finder = tool(
            name: "finder.copy",
            description: "Copy one file or folder into an allowed directory.",
            application: "Finder",
            provider: "Nexus Native Files",
            tags: ["file", "folder", "filesystem"],
            fields: ["path": .init(.string, required: true, description: "Exact existing source file or folder. Preserve every supplied path segment, including spaces.")]
        )
        let xcode = tool(
            name: "xcode.build",
            description: "Run xcodebuild build with an explicit project or workspace and scheme.",
            application: "Xcode",
            provider: "xcodebuild",
            tags: ["xcode", "build", "swift", "developer"],
            fields: ["path": .init(.string, required: true, description: "Absolute existing Xcode project or workspace path. Preserve every supplied path segment, including spaces.")]
        )

        XCTAssertEqual(
            search(
                "Build the Nexus macOS app from /Users/example/Documents/nexus 2/nexus/nexus.xcodeproj using the nexus scheme.",
                [finder, xcode]
            ).first?.tool,
            "xcode.build"
        )
    }

    func testAbsoluteVSCodeFilePathRanksEditInsteadOfFinder() {
        let finder = tool(
            name: "finder.copy",
            description: "Copy one file or folder into an allowed directory.",
            application: "Finder",
            provider: "Nexus Native Files",
            tags: ["file", "folder", "filesystem"],
            fields: ["path": .init(.string, required: true, description: "Exact existing source file or folder. Preserve every supplied path segment, including spaces.")]
        )
        let vscode = tool(
            name: "vscode.edit_file",
            description: "Perform an exact validated text replacement on disk and return a diff.",
            application: "Visual Studio Code",
            provider: "VS Code CLI",
            tags: ["vscode", "code", "editor", "workspace", "developer"],
            fields: ["path": .init(.string, required: true, description: "Absolute existing file to update. Preserve every supplied path segment, including spaces.")]
        )

        XCTAssertEqual(
            search(
                "In the generated proof file at /Users/example/Documents/nexus 2/VSCODE_ROUTING_PROOF.md, replace STATUS: PENDING with STATUS: VERIFIED.",
                [finder, vscode]
            ).first?.tool,
            "vscode.edit_file"
        )
    }

    func testAbsoluteFileEditKeepsCommaContinuationInOneRequest() {
        let finder = tool(
            name: "finder.copy",
            description: "Copy one file or folder into an allowed directory.",
            application: "Finder",
            provider: "Nexus Native Files",
            tags: ["file", "folder", "filesystem"],
            fields: ["path": .init(.string, required: true, description: "Exact existing source file or folder. Preserve every supplied path segment, including spaces.")]
        )
        let vscode = tool(
            name: "vscode.edit_file",
            description: "Perform an exact validated text replacement on disk and return a diff.",
            application: "Visual Studio Code",
            provider: "VS Code CLI",
            tags: ["vscode", "code", "editor", "workspace", "developer"],
            fields: ["path": .init(.string, required: true, description: "Absolute existing file to update. Preserve every supplied path segment, including spaces.")]
        )
        let status = tool(
            name: "codex.get_status",
            description: "Get the last known structured status for a stable task.",
            application: "Codex",
            provider: "Codex CLI",
            tags: ["task", "status"]
        )

        XCTAssertEqual(
            search(
                "In the generated proof file at /Users/example/Documents/nexus 2/VSCODE_ROUTING_PROOF.md, replace STATUS: PENDING with STATUS: VERIFIED.",
                [finder, vscode, status]
            ).first?.tool,
            "vscode.edit_file"
        )
    }

    func testVaultRelativePathDoesNotPolluteIntentRetrieval() {
        let append = tool(
            name: "obsidian.append_note",
            description: "Atomically append Markdown to an exact existing note and return a diff.",
            application: "Obsidian",
            provider: "Obsidian Vault",
            aliases: ["add to an existing note", "add a line to an existing note", "record a note follow-up"],
            tags: ["notes", "markdown", "vault"],
            fields: ["path": .init(.string, required: true)]
        )
        let branch = tool(
            name: "git.create_branch",
            description: "Create and check out a new local Git branch.",
            application: "Git",
            provider: "Git CLI",
            aliases: ["start a separate local line of work"],
            tags: ["git", "repository", "branch"]
        )
        let confirmation = tool(
            name: "confirm_action",
            description: "Confirm and execute one exact pending Nexus action.",
            application: "Nex",
            provider: "Nexus Confirmation Gateway",
            tags: ["confirmation", "nexus"]
        )

        XCTAssertEqual(
            search(
                "In the validation note at validation/test_nexus_tools_checklist.md, add a short completed line saying the isolated vault check passed.",
                [append, branch, confirmation]
            ).first?.tool,
            "obsidian.append_note"
        )
    }

    func testAbsolutePreviewDocumentPathRanksPreviewInsteadOfEditors() {
        let vscode = tool(
            name: "vscode.open_file",
            description: "Open an existing file at an optional line in VS Code.",
            application: "Visual Studio Code",
            provider: "VS Code CLI",
            tags: ["vscode", "code", "editor", "workspace", "developer"],
            fields: ["path": .init(.string, required: true, description: "Absolute existing source-file path. Preserve every supplied path segment, including spaces.")]
        )
        let xcode = tool(
            name: "xcode.open_file",
            description: "Open an existing source file with xed.",
            application: "Xcode",
            provider: "xcodebuild",
            tags: ["xcode", "build", "swift", "developer"],
            fields: ["path": .init(.string, required: true, description: "Absolute existing source-file path. Preserve every supplied path segment, including spaces.")]
        )
        let preview = tool(
            name: "preview.open",
            description: "Open a supported document with the default macOS Preview handler.",
            application: "Preview",
            provider: "PDFKit",
            tags: ["preview", "pdf", "document", "image", "export"],
            fields: ["path": .init(.string, required: true, description: "Absolute existing PDF or supported document path. Preserve every supplied path segment, including spaces.")]
        )

        XCTAssertEqual(
            search(
                "Open the generated combined PDF at /Users/example/Documents/nexus 2/COMBINED.pdf in Preview.",
                [vscode, xcode, preview]
            ).first?.tool,
            "preview.open"
        )
    }

    func testFinderNativePlanningPolicyTreatsConcretePathsAsActionable() {
        let finder = tool(
            name: "finder.copy",
            description: "Copy one file into an allowed folder.",
            application: "Finder",
            provider: "Nexus Native Files",
            tags: ["file", "folder", "filesystem"]
        )

        let rules = NexPrimaryToolPlanner.nativePlanningMessages(
            context: [.init(role: "user", content: "Copy /tmp/source.md into /tmp/destination.")],
            tools: [finder]
        ).first?.content ?? ""
        XCTAssertTrue(rules.contains("exact absolute source and target paths"))
        XCTAssertTrue(rules.contains("Paths may contain spaces"))
        XCTAssertTrue(rules.contains("preserve both copies"))
        XCTAssertTrue(rules.contains("never invent one"))
    }

    func testExplicitArtifactLabelDoesNotRouteToAnApplicationWithTheSameName() {
        let finder = tool(
            name: "finder.create_folder",
            description: "Create one folder under an existing parent.",
            application: "Finder",
            provider: "Nexus Native Files",
            tags: ["file", "folder", "filesystem"]
        )
        let git = tool(
            name: "git.create_branch",
            description: "Create and check out a local Git branch in a repository.",
            application: "Git",
            provider: "Git CLI",
            tags: ["git", "repository", "branch"]
        )

        XCTAssertEqual(
            search(
                "Make a folder called Git Lifecycle Proof in the disposable validation workspace at /Users/example/Documents/nexus 2/.build/validation-fixtures.",
                [finder, git, tool(
                    name: "xcode.build",
                    description: "Run an Xcode build for a project or workspace.",
                    application: "Xcode",
                    provider: "xcodebuild",
                    tags: ["build", "workspace", "project"]
                )]
            ).first?.tool,
            "finder.create_folder"
        )
    }

    func testSaveStagedWorkSemanticMetadataDiscoversCommitInsteadOfBranch() {
        let commit = tool(
            name: "git.commit",
            description: "Record the current staged Git changes as a local commit with an exact message.",
            application: "Git",
            provider: "Git CLI",
            examples: ["Save the staged work as a local checkpoint"],
            aliases: ["save staged work", "record local checkpoint", "save the prepared change"],
            tags: ["git", "repository", "commit", "staged"]
        )
        let branch = tool(
            name: "git.create_branch",
            description: "Create and check out a new local Git branch.",
            application: "Git",
            provider: "Git CLI",
            tags: ["git", "repository", "branch"]
        )
        let initialize = tool(
            name: "git.init",
            description: "Initialize an existing directory as a local Git repository.",
            application: "Git",
            provider: "Git CLI",
            tags: ["git", "repository", "initialize"]
        )

        XCTAssertEqual(
            search(
                "Save the prepared validation note as a local checkpoint in the disposable repository.",
                [commit, branch, initialize]
            ).first?.tool,
            "git.commit"
        )
    }

    func testSeparateLineOfWorkSemanticMetadataDiscoversBranchInsteadOfInitialization() {
        let branch = tool(
            name: "git.create_branch",
            description: "Create and check out a new local Git branch.",
            application: "Git",
            provider: "Git CLI",
            aliases: ["start a separate local line of work", "begin isolated work", "work on a local branch"],
            tags: ["git", "repository", "branch"]
        )
        let initialize = tool(
            name: "git.init",
            description: "Initialize an existing directory as a local Git repository.",
            application: "Git",
            provider: "Git CLI",
            tags: ["git", "repository", "initialize"]
        )

        XCTAssertEqual(
            search("Start a harmless local line of work in the disposable repository.", [branch, initialize]).first?.tool,
            "git.create_branch"
        )
    }

    func testReturnToMainSemanticMetadataDiscoversCheckoutInsteadOfPush() {
        let checkout = tool(
            name: "git.checkout",
            description: "Switch to an existing local Git branch.",
            application: "Git",
            provider: "Git CLI",
            aliases: ["return to the main line", "switch back to an existing branch", "go back to a branch"],
            tags: ["git", "repository", "branch"]
        )
        let push = tool(
            name: "git.push",
            description: "Push the current branch to its configured upstream.",
            application: "Git",
            provider: "Git CLI",
            tags: ["git", "repository", "push", "remote"]
        )

        XCTAssertEqual(
            search("Return the disposable repository to its main line.", [checkout, push]).first?.tool,
            "git.checkout"
        )
    }

    func testBringLatestRemoteChangeSemanticMetadataDiscoversPullInsteadOfPush() {
        let pull = tool(
            name: "git.pull",
            description: "Pull the configured upstream using fast-forward-only semantics.",
            application: "Git",
            provider: "Git CLI",
            aliases: ["bring the latest changes from a remote", "update a local branch from its remote", "receive backup remote changes"],
            tags: ["git", "repository", "pull", "remote"]
        )
        let push = tool(
            name: "git.push",
            description: "Push a local Git branch to its configured upstream.",
            application: "Git",
            provider: "Git CLI",
            tags: ["git", "repository", "push", "remote"]
        )

        XCTAssertEqual(
            search("Bring the latest generated change from the backup remote into the disposable repository.", [pull, push]).first?.tool,
            "git.pull"
        )
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

    func testDominantUnavailableCapabilityDoesNotFallBackToAnUnrelatedAction() {
        let calendar = NexToolSearchEngine.Document(
            tool: tool(
                name: "calendar.search_events",
                description: "Search events in a connected calendar.",
                application: "Calendar",
                provider: "Google Calendar",
                tags: ["calendar", "event", "schedule", "search"]
            ),
            isAvailable: false,
            unavailableReason: "Google is not connected."
        )
        let messages = NexToolSearchEngine.Document(
            tool: tool(
                name: "messages.search",
                description: "Search local Messages conversations.",
                application: "Messages",
                provider: "Messages database",
                tags: ["message", "conversation", "search"]
            )
        )

        XCTAssertTrue(
            engine.search(
                query: "Search my calendar for design reviews.",
                documents: [calendar, messages]
            ).candidates.isEmpty
        )
        XCTAssertEqual(
            engine.search(
                query: "Search my calendar for design reviews.",
                documents: [calendar, messages],
                availabilityPolicy: .includeUnavailable
            ).candidates.first?.tool,
            "calendar.search_events"
        )
    }

    func testOneCharacterTypoStillDiscoversRegisteredCapability() {
        let screenshot = tool(
            name: "browser.screenshot",
            description: "Capture a screenshot of the current browser page.",
            application: "Chrome",
            provider: "Managed Browser",
            tags: ["screenshot", "capture", "image"]
        )
        XCTAssertEqual(
            search("take a screenshit of the current page", [screenshot]).first?.tool,
            "browser.screenshot"
        )
    }

    func testDistinctActionIDsWithSharedMetadataRemainDiscoverable() {
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
        XCTAssertEqual(
            Set(search("send an email", [duplicate, first]).map(\.tool)),
            Set(["mail.compose", "mail.send"])
        )
    }

    func testExactRegisteredExampleOutranksBroadDomainVocabulary() {
        let workspaceSearch = tool(
            name: "vscode.search_workspace",
            description: "Search readable text files within an exact workspace directory.",
            application: "Visual Studio Code",
            provider: "VS Code CLI",
            examples: ["Search this workspace for NotchGeometry"],
            aliases: ["search workspace files"],
            tags: ["vscode", "code", "editor", "workspace"]
        )
        let remoteSearch = tool(
            name: "notion.search",
            description: "Search a connected Notion workspace.",
            application: "Notion",
            provider: "Notion Connector",
            aliases: ["search Notion workspace"],
            tags: ["notion", "workspace", "search"]
        )

        XCTAssertEqual(
            search("Search this workspace for NotchGeometry", [remoteSearch, workspaceSearch]).first?.tool,
            "vscode.search_workspace"
        )
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
        workflows: [String] = [],
        fields: [String: NexToolFieldSchema] = [:]
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
            ].merging(fields, uniquingKeysWith: { _, replacement in replacement })),
            application: application,
            provider: provider,
            examples: examples,
            aliases: aliases,
            tags: tags,
            supportedWorkflows: workflows
        ) { _, _ in .object([:]) }
    }
}
