import XCTest
import PDFKit
@testable import nexus

final class NexComputerExtendedActionTests: XCTestCase {
    private struct AuthorizedPermissions: NexComputerPermissionChecking {
        func status(for requirement: NexComputerPermissionRequirement) async -> NexComputerPermissionStatus { .init(requirementID: requirement.id, state: .authorized, recovery: nil) }
        func request(for requirement: NexComputerPermissionRequirement) async -> NexComputerPermissionStatus { .init(requirementID: requirement.id, state: .authorized, recovery: nil) }
    }

    func testPhotosReturnsStructuredMetadataWithoutRealMutation() async throws {
        let provider = MockPhotosProvider()
        let tools = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexPhotosActionCatalog(provider: provider).register(on: registry)

        let result = try await tools.execute(name: "photos.search", arguments: ["favorites": .bool(true), "limit": .number(10)])
        guard case .object(let object) = result, case .array(let results)? = object["results"], case .object(let first)? = results.first else { return XCTFail("Expected structured photo results") }
        XCTAssertEqual(object["status"], .string("found"))
        XCTAssertEqual(first["id"], .string("photo-1"))
        let searchCount = await provider.searchCount
        XCTAssertEqual(searchCount, 1)
    }

    func testPhotosMutationIsConfirmationBound() async throws {
        let provider = MockPhotosProvider()
        let core = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: core, confirmationGateway: NexComputerConfirmationGateway(store: NexComputerPendingActionStore(fileURL: temporaryFile("photos-confirmation.json"))), permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexPhotosActionCatalog(provider: provider).register(on: registry)
        let result = try await core.execute(name: "photos.create_album", arguments: ["name": .string("Robotics")])
        guard case .object(let object) = result else { return XCTFail("Expected confirmation result") }
        XCTAssertEqual(object["status"], .string("confirmation_required"))
        let createdAlbums = await provider.createdAlbums
        XCTAssertTrue(createdAlbums.isEmpty)
    }

    func testPhotosPersonSearchFailsHonestly() async throws {
        let provider = MockPhotosProvider(personSearchSupported: false)
        do {
            _ = try await provider.search(.init(query: nil, startDate: nil, endDate: nil, album: nil, mediaType: nil, favoritesOnly: false, latitude: nil, longitude: nil, radiusKilometers: nil, person: "Sam", limit: 10))
            XCTFail("Expected unsupported person search")
        } catch let error as NexPhotosError {
            XCTAssertEqual(error, .unsupportedFilter("person"))
        }
    }

    func testVSCodeEditPreservesFileAndReturnsDiff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hello.swift")
        try "let greeting = \"hello\"\n".write(to: file, atomically: true, encoding: .utf8)
        let provider = NexVSCodeCLIProvider(executable: URL(fileURLWithPath: "/usr/bin/true"))
        let diff = try await provider.edit(file: file, oldText: "hello", newText: "hi", replaceAll: false)
        XCTAssertTrue(diff.contains("-let greeting = \"hello\""))
        XCTAssertTrue(diff.contains("+let greeting = \"hi\""))
        XCTAssertEqual(try String(contentsOf: file), "let greeting = \"hi\"\n")
    }

    func testVSCodeBroadEditRequiresExplicitReplaceAll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("values.txt")
        try "same\nsame\n".write(to: file, atomically: true, encoding: .utf8)
        let provider = NexVSCodeCLIProvider(executable: URL(fileURLWithPath: "/usr/bin/true"))
        do { _ = try await provider.edit(file: file, oldText: "same", newText: "new", replaceAll: false); XCTFail("Expected broad edit rejection") }
        catch is NexVSCodeError { }
    }

    func testCodexCatalogPreservesSpecializedActionFamily() async throws {
        let tools = NexToolRegistry(), computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexCodexActionCatalog(provider: MockCodexProvider()).register(on: computer)
        let definitions = await tools.definitions()
        let names = Set(definitions.map(\.name))
        XCTAssertTrue(Set(["codex.open", "codex.start_task", "codex.continue_task", "codex.get_status", "codex.cancel_task", "codex.open_session"]).isSubset(of: names))
        let prompt = try XCTUnwrap(definitions.first(where: { $0.name == "codex.continue_task" })?.schema.fields["prompt"])
        XCTAssertTrue(prompt.required)
        XCTAssertTrue(prompt.description?.contains("Complete non-empty instruction") == true)
    }

    func testCodexReportsOnlyChangesInsideTheRequestedWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("generated-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = NexGitHubCLIProvider()
        _ = try await git.git(["init", "-q"], repository: root)
        try "pre-existing unrelated change\n".write(
            to: root.appendingPathComponent("unrelated.txt"),
            atomically: true,
            encoding: .utf8
        )

        let provider = NexCodexCLIProvider(executable: URL(fileURLWithPath: "/usr/bin/true"))
        let snapshot = try await provider.run(
            prompt: "Report the workspace contents without changes.",
            workspace: workspace,
            sessionID: nil,
            progress: { _ in }
        )
        XCTAssertEqual(snapshot.status, "completed")
        XCTAssertTrue(snapshot.filesChanged.isEmpty)
    }

    func testCodexDoesNotExposeRawCommandOutputAsATestSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let fixture = root.appendingPathComponent("codex-fixture")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = #"{"type":"item.completed","item":{"aggregated_output":" M ../../nexus/nexusTests/Example.swift"}}"#
        try "#!/bin/sh\nprintf '%s\\n' '\(output)'\n".write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)

        let provider = NexCodexCLIProvider(executable: fixture)
        let snapshot = try await provider.run(
            prompt: "Report the workspace contents without changes.",
            workspace: workspace,
            sessionID: nil,
            progress: { _ in }
        )
        XCTAssertTrue(snapshot.testSummary.isEmpty)
    }

    func testCodexStartExposesAStableSessionThatCanBeCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let fixture = root.appendingPathComponent("codex-fixture")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "#!/bin/sh\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"stable-session\"}'\nsleep 30\n".write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)

        let provider = NexCodexCLIProvider(executable: fixture)
        let started = try await provider.start(
            prompt: "Wait without changing this generated workspace.",
            workspace: workspace,
            sessionID: nil,
            progress: { _ in }
        )
        XCTAssertEqual(started.sessionID, "stable-session")
        XCTAssertEqual(started.status, "running")
        try await provider.cancel(sessionID: started.sessionID)
        let cancelled = await provider.status(sessionID: started.sessionID)
        XCTAssertEqual(cancelled?.status, "cancelled")
    }

    func testObsidianWritesAreAtomicSearchableAndTraversalSafe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); let provider = NexObsidianFileProvider(root: root); try await provider.prepare(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await provider.create(relativePath: "20 Projects/Nexus.md", content: "---\ntags: [nexus]\nproject: Nexus\n---\n# Nexus\nNative notch agent.\n")
        let matches = try await provider.search(query: "notch", folder: "20 Projects", tag: "nexus", frontmatterKey: "project", frontmatterValue: "Nexus", createdAfter: nil, modifiedAfter: nil, limit: 10)
        XCTAssertEqual(matches.map(\.relativePath), ["20 Projects/Nexus.md"])
        let diff = try await provider.append(relativePath: "20 Projects/Nexus.md", content: "## Decision\nUse native Swift.")
        XCTAssertTrue(diff.contains("+Use native Swift."))
        do { _ = try await provider.read(relativePath: "../secret"); XCTFail("Expected traversal rejection") } catch { }
    }

    func testObsidianWriteActionsAreFilesystemToolsNotInternalMemoryWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexObsidianActionCatalog(provider: NexObsidianFileProvider(root: root)).register(on: computer)
        let definitions = await tools.definitions()
        for name in ["obsidian.create_note", "obsidian.append_note", "obsidian.update_note"] {
            XCTAssertEqual(definitions.first(where: { $0.name == name })?.permission, .files)
        }
    }

    func testGitStatusUsesArgvAndReturnsRepositoryState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let cli = NexGitHubCLIProvider(); _ = try await cli.git(["init", "-q"], repository: root); try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let result = try await cli.git(["status", "--porcelain=v1"], repository: root); XCTAssertTrue(result.stdout.contains("README.md"))
    }

    func testGitCatalogRegistersConfirmationBoundInitialization() async throws {
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexGitHubActionCatalog().register(on: computer)
        let definition = await tools.definitions().first(where: { $0.name == "git.init" })
        XCTAssertEqual(definition?.permission, .codeExecution)
        XCTAssertTrue(definition?.schema.fields["repository"]?.required == true)
    }

    func testGitHubRepositorySearchUsesFieldsSupportedByTheInstalledCLI() {
        let arguments = NexGitHubActionCatalog.githubSearchArguments(
            query: "Nexus agent",
            type: "repositories",
            limit: 10
        )
        XCTAssertEqual(arguments, ["search", "repos", "Nexus agent", "--limit", "10", "--json", "fullName,url,description"])
        XCTAssertFalse(arguments.contains("nameWithOwner,url,description"))
    }

    func testGitHubIssueCreationIsDiscoverableForANaturalRepositoryRequest() async throws {
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexGitHubActionCatalog().register(on: computer)
        let candidates = NexToolSearchEngine().search(
            query: "In v1shay/nexus, add a short issue describing a validation marker.",
            documents: await tools.definitions().map { NexToolSearchEngine.Document(tool: $0) }
        ).candidates
        XCTAssertEqual(candidates.first?.tool, "github.create_issue")
    }

    func testGitHubPublicRepositorySearchIsDiscoverableWithoutAConnector() async throws {
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexGitHubActionCatalog().register(on: computer)
        let candidates = NexToolSearchEngine().search(
            query: "Find public GitHub repositories related to the Nexus agent project.",
            documents: await tools.definitions().map { NexToolSearchEngine.Document(tool: $0) }
        ).candidates
        XCTAssertEqual(candidates.first?.tool, "github.search")
    }

    func testGitHubPullRequestCreationRequiresAnExplicitSourceBranch() async throws {
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexGitHubActionCatalog().register(on: computer)
        let definitions = await tools.definitions()
        let pullRequest = try XCTUnwrap(definitions.first { $0.name == "github.create_pull_request" })
        XCTAssertTrue(pullRequest.schema.fields["head"]?.required == true)
        XCTAssertTrue(pullRequest.schema.fields["head"]?.description?.contains("source branch") == true)
    }

    func testGitCatalogStagesOnlyExplicitFilesAndCanReadTheIndexDiff() async throws {
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexGitHubActionCatalog().register(on: computer)
        let definitions = await tools.definitions()
        let stage = definitions.first(where: { $0.name == "git.stage" })
        XCTAssertEqual(stage?.permission, .codeExecution)
        XCTAssertEqual(stage?.schema.fields["paths"]?.type, .stringArray)
        XCTAssertTrue(stage?.schema.fields["paths"]?.required == true)
        let diff = definitions.first(where: { $0.name == "git.diff" })
        XCTAssertEqual(diff?.schema.fields["staged"]?.type, .boolean)
        XCTAssertFalse(diff?.schema.fields["staged"]?.required ?? true)
    }

    func testGitCatalogCanConfigureAnExplicitRemoteAndEstablishFirstPushUpstream() async throws {
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexGitHubActionCatalog().register(on: computer)
        let definitions = await tools.definitions()
        let remote = definitions.first(where: { $0.name == "git.configure_remote" })
        XCTAssertEqual(remote?.permission, .codeExecution)
        XCTAssertTrue(remote?.schema.fields["name"]?.required == true)
        XCTAssertTrue(remote?.schema.fields["url"]?.required == true)
        let push = definitions.first(where: { $0.name == "git.push" })
        XCTAssertEqual(push?.permission, .codeExecution)
        XCTAssertFalse(push?.schema.fields["remote"]?.required ?? true)
        XCTAssertFalse(push?.schema.fields["branch"]?.required ?? true)
    }

    func testFinderAcceptsNaturalOverwriteAliasForAFileCollision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "new".write(to: source, atomically: true, encoding: .utf8)
        try "old".write(to: destination.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)

        let files = NexFinderFileService(allowedRoots: [root])
        let copied = try await files.copy(
            sourcePath: source.path,
            destinationDirectory: destination.path,
            collisionPolicy: .overwrite
        )
        XCTAssertEqual(try String(contentsOf: copied), "new")
        XCTAssertEqual(try String(contentsOf: source), "new")
    }

    func testSystemCatalogExposesExplicitFocusLimitation() async throws {
        let tools = NexToolRegistry(), computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions())); try await NexSystemActionCatalog().register(on: computer)
        let names = Set(await tools.definitions().map(\.name)); XCTAssertTrue(Set(["system.open_setting", "system.get_volume", "system.set_volume", "system.get_display_state", "system.toggle_focus_mode", "system.get_battery", "system.get_network_state"]).isSubset(of: names))
        let settings = try await computer.manifest(actionID: "system.open_setting")
        XCTAssertEqual(settings.inputSchema.fields["pane"]?.description, "The allowed macOS Settings pane that semantically matches the user's requested setting.")
        let available = try await computer.availability(actionID: "system.toggle_focus_mode"); XCTAssertFalse(available.isAvailable); XCTAssertTrue((available.reason ?? "").contains("Focus"))
    }

    func testXcodeCatalogRegistersBuildAndTestActions() async throws {
        let tools = NexToolRegistry(), computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions())); try await NexXcodeActionCatalog().register(on: computer); let names = Set(await tools.definitions().map(\.name)); XCTAssertTrue(Set(["xcode.open", "xcode.open_project", "xcode.build", "xcode.test", "xcode.run", "xcode.get_build_status", "xcode.open_file"]).isSubset(of: names))
    }

    func testPreviewCombinesPDFsInOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let first = PDFDocument(), second = PDFDocument(); first.insert(try fixturePDFPage(size: 10), at: 0); second.insert(try fixturePDFPage(size: 20), at: 0); let a = root.appendingPathComponent("a.pdf"), b = root.appendingPathComponent("b.pdf"); XCTAssertTrue(first.write(to: a)); XCTAssertTrue(second.write(to: b)); let output = root.appendingPathComponent("combined.pdf"); let result = try await NexPreviewProvider().combine(inputs: [a, b], output: output, overwrite: false); XCTAssertEqual(result.1, 2); XCTAssertEqual(PDFDocument(url: output)?.pageCount, 2)
    }

    func testApplicationCatalogProvidesDeterministicOpenOnly() async throws { let tools = NexToolRegistry(), computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions())); try await NexApplicationActionCatalog().register(on: computer); let names = Set(await tools.definitions().map(\.name)); XCTAssertEqual(names.intersection(["applications.list", "applications.open"]), ["applications.list", "applications.open"]) }
    func testAppResultsUseGlassPreviewWhileTerminalStaysDirect() {
        let finder = ToolActivity(
            actionID: "finder.search",
            toolName: "Finder Search",
            status: "Found a folder.",
            spokenStatus: "Found a folder.",
            icon: .systemSymbol("folder"),
            phase: .completed,
            result: .object(["status": .string("completed"), "paths": .array([.string("/tmp/Results")])])
        )
        XCTAssertTrue(finder.requiresExpandedPreview)

        let terminal = ToolActivity(
            actionID: "terminal.run",
            toolName: "Terminal Run",
            status: "Finished.",
            spokenStatus: "Finished.",
            icon: .systemSymbol("terminal"),
            phase: .completed,
            result: .object(["status": .string("completed")])
        )
        XCTAssertFalse(terminal.requiresExpandedPreview)
    }
    func testManagedBrowserRejectsInvalidStepPayloadBeforeProvisioning() async throws { do { _ = try await NexManagedBrowserProvider(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)).run(goal: "test", stepsJSON: "{}") { _ in }; XCTFail("Expected invalid steps") } catch let error as NexToolError { XCTAssertEqual(error.code, "invalid_browser_steps") } }

    func testBrowserScreenshotRequestDiscoversAgenticBrowserAction() async throws {
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexBrowserActionCatalog().register(on: computer)
        let search = NexToolSearchService(registry: tools)
        let result = await search.search(query: "On https://www.wikipedia.org/, take a full-page screenshot and tell me which languages are prominently displayed.")
        XCTAssertEqual(result.candidates.first?.tool, "browser.run_task")
    }

    func testBrowserWaitRequestDiscoversAgenticBrowserAction() async throws {
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexBrowserActionCatalog().register(on: computer)
        let search = NexToolSearchService(registry: tools)
        let result = await search.search(query: "On https://www.wikipedia.org, wait up to 30 seconds for an element to appear before continuing.")
        XCTAssertEqual(result.candidates.first?.tool, "browser.run_task")
    }

    func testPlayYouTubeRequestDiscoversVisibleManagedPlaybackTool() async throws {
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexBrowserActionCatalog().register(on: computer)
        let search = NexToolSearchService(registry: tools)
        let result = await search.search(query: "Play something for me in the Nexus browser and put it on screen.")
        XCTAssertEqual(result.candidates.first?.tool, "browser.play_youtube")
    }

    func testDirectYouTubeVoiceIntentAvoidsModelRouting() {
        XCTAssertEqual(NexusYouTubeVoiceIntent.request(in: "Play something for me"), .init(query: nil))
        XCTAssertEqual(NexusYouTubeVoiceIntent.request(in: "Play lo-fi beats on YouTube"), .init(query: "lo-fi beats"))
        XCTAssertNil(NexusYouTubeVoiceIntent.request(in: "Explain YouTube recommendations"))
    }

    func testSchoologyRequestDiscoversDedicatedLiveEvidenceTool() async throws {
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions()))
        try await NexBrowserActionCatalog().register(on: computer)
        let search = NexToolSearchService(registry: tools)
        let result = await search.search(query: "Check Schoology for my upcoming school assignments.")
        XCTAssertEqual(result.candidates.first?.tool, "browser.check_schoology")
    }

    func testYouTubePlaybackPlanUsesVisibleFirstResultAndNormalSkipControl() throws {
        let json = try NexBrowserActionCatalog.youtubePlaybackSteps(query: "lofi beats")
        let steps = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(steps.first?["action"] as? String, "navigate")
        XCTAssertTrue((steps.first?["url"] as? String)?.contains("search_query=lofi") == true)
        XCTAssertTrue(steps.contains { ($0["action"] as? String) == "bring_to_front" })
        XCTAssertTrue(steps.contains { ($0["action"] as? String) == "youtube_start_first_visible" })
        let skip = try XCTUnwrap(steps.first { ($0["action"] as? String) == "skip_youtube_ad" })
        XCTAssertEqual(skip["minimumWaitMs"] as? Int, 5_000)
        XCTAssertTrue(steps.contains { ($0["action"] as? String) == "youtube_fullscreen" })
        XCTAssertTrue(steps.contains { ($0["action"] as? String) == "hold_open" })
    }

    func testSchoologyPlanUsesFUHSDAndNeverEmbedsAUserAccount() throws {
        let json = try NexBrowserActionCatalog.schoologyCheckSteps(schoolEmail: nil)
        let steps = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let schoology = try XCTUnwrap(steps.first)
        XCTAssertEqual(schoology["action"] as? String, "schoology_check")
        XCTAssertEqual(schoology["url"] as? String, "https://fuhsd.schoology.com/")
        XCTAssertEqual(schoology["schoolEmail"] as? String, "")
    }

    func testManagedBrowserReadsPublicPageAndPersistsItsResult() async throws {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let node = "/opt/homebrew/bin/node"
        guard FileManager.default.isExecutableFile(atPath: chrome),
              FileManager.default.isExecutableFile(atPath: node) else {
            throw XCTSkip("Managed-browser runtime is not installed on this host.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexBrowserE2E-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await NexManagedBrowserProvider(root: root).run(
            goal: "Read the IANA reserved-domains page heading",
            stepsJSON: "[{\"action\":\"navigate\",\"url\":\"https://www.iana.org/domains/reserved\"},{\"action\":\"extract\",\"selector\":\"h1\"},{\"action\":\"screenshot\",\"name\":\"iana-reserved-domains\",\"fullPage\":false}]"
        ) { _ in }
        XCTAssertEqual(result.status, "completed")
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("IANA-managed Reserved Domains"))
        XCTAssertTrue(result.error.isEmpty)
        let screenshot = try XCTUnwrap(result.screenshots.first)
        XCTAssertTrue(screenshot.hasSuffix("iana-reserved-domains.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: screenshot))
        let reloaded = NexManagedBrowserProvider(root: root)
        let persisted = await reloaded.status(result.taskID)
        XCTAssertEqual(persisted?.taskID, result.taskID)
        XCTAssertEqual(persisted?.status, "completed")
        XCTAssertEqual(persisted?.text, result.text)
    }

    func testManagedBrowserStartsAndCancelsByStableTaskID() async throws {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let node = "/opt/homebrew/bin/node"
        guard FileManager.default.isExecutableFile(atPath: chrome),
              FileManager.default.isExecutableFile(atPath: node) else {
            throw XCTSkip("Managed-browser runtime is not installed on this host.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexBrowserCancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = NexManagedBrowserProvider(root: root)
        let started = try await provider.start(
            goal: "Wait for a nonexistent generated marker so this task can be cancelled.",
            stepsJSON: "[{\"action\":\"wait_for_element\",\"selector\":\"#nexus-cancel-proof\",\"timeout\":30000}]"
        ) { _ in }
        XCTAssertEqual(started.status, "running")
        let running = await provider.status(started.taskID)
        XCTAssertEqual(running?.status, "running")
        try await provider.cancel(started.taskID)
        try await Task.sleep(for: .milliseconds(500))
        let cancelled = await provider.status(started.taskID)
        XCTAssertEqual(cancelled?.status, "cancelled")
    }
    func testBrowserProfileImportCopiesOnlySafeState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chrome = root.appendingPathComponent("Chrome"), destination = root.appendingPathComponent("Nexus")
        let profile = chrome.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Bookmarks", "History", "Preferences", "Cookies", "Login Data"] {
            try name.write(to: profile.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let provider = NexManagedBrowserProvider(root: destination, chromeIsRunning: { false })
        let copied = try await provider.importProfile(chromeRoot: chrome)
        XCTAssertEqual(Set(copied), Set(["Bookmarks", "History", "Preferences"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Profile/Default/Cookies").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Profile/Default/Login Data").path))
    }
    func testConnectorCapabilityRegistrationHonorsScopesAndAvailability() async throws {
        let tools = NexToolRegistry(), computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions())), manager = NexConnectorManager(executor: MockConnectorExecutor())
        let doc = NexConnectorCapabilityDocument(provider: "google", account: "test@example.com", connected: true, grantedScopes: ["openid", "gmail.readonly"], capabilities: [.init(action: "google.account_info", available: true, missingScope: nil, providerLimitation: nil), .init(action: "gmail.search", available: true, missingScope: nil, providerLimitation: nil), .init(action: "gmail.send_draft", available: false, missingScope: "gmail.send", providerLimitation: nil)])
        try await manager.apply(doc, to: computer); let names = Set(await tools.definitions().map(\.name)); XCTAssertTrue(names.contains("google.account_info")); XCTAssertTrue(names.contains("gmail.search")); XCTAssertTrue(names.contains("gmail.send_draft")); let unavailable = await manager.unavailableCapabilities(provider: "google"); XCTAssertEqual(unavailable.first?.missingScope, "gmail.send")
        let unavailableResult = try await tools.execute(name: "gmail.read_thread", arguments: ["thread_id": .string("thread-1")])
        guard case .object(let object) = unavailableResult else { return XCTFail("Expected connection request") }
        XCTAssertEqual(object["status"], .string("connection_required"))
        let envelope = await NexComputerRuntime(registry: computer).execute(
            actionID: "gmail.read_thread",
            arguments: ["thread_id": .string("thread-1")]
        )
        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.data.object?["status"], .string("connection_required"))
        XCTAssertNotNil(envelope.data.object?["connectionId"]?.string)
    }

    func testConnectorManifestsDeclareNaturalCapabilityMetadataForDisconnectedDiscovery() async throws {
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(
            toolRegistry: tools,
            permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions())
        )
        let manager = NexConnectorManager(executor: MockConnectorExecutor())
        try await manager.apply(.disconnected(.google), to: computer)

        let definitions = await tools.definitions()
        let gmail = try XCTUnwrap(definitions.first { $0.name == "gmail.read_thread" })
        XCTAssertEqual(gmail.application, "Gmail")
        XCTAssertTrue(gmail.description.contains("email"))
        XCTAssertTrue(gmail.description.contains("thread"))
        let gmailSearch = try XCTUnwrap(definitions.first { $0.name == "gmail.search" })
        XCTAssertTrue(gmailSearch.aliases.contains { $0.contains("find") && $0.contains("email") })
        XCTAssertTrue(gmailSearch.schema.fields["query"]?.description?.contains("search criteria") == true)

        let search = NexToolSearchService(registry: tools, computerRegistry: computer)
        let email = await search.search(
            query: "Find the email thread about the project launch.",
            availabilityPolicy: .includeUnavailable
        ).candidates
        XCTAssertEqual(email.first?.tool, "gmail.search")
        XCTAssertEqual(email.first?.isAvailable, false)

        let compressedEmail = await search.search(
            query: "email thread project launch",
            availabilityPolicy: .includeUnavailable
        ).candidates
        XCTAssertEqual(compressedEmail.first?.tool, "gmail.search")

        let calendar = await search.search(
            query: "design reviews calendar",
            availabilityPolicy: .includeUnavailable
        ).candidates
        XCTAssertEqual(calendar.first?.tool, "calendar.search_events")
        XCTAssertEqual(calendar.first?.application, "Google Calendar")
    }

    func testDisconnectedConnectorIsOmittedFromPlanningButStillReturnsConnectionRecovery() async throws {
        let tools = NexToolRegistry()
        let computer = NexComputerRegistry(
            toolRegistry: tools,
            permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions())
        )
        let manager = NexConnectorManager(executor: MockConnectorExecutor())
        try await manager.apply(.disconnected(.github), to: computer)

        let availability = try await computer.availability(actionID: "github.search_repositories")
        XCTAssertFalse(availability.isAvailable)
        XCTAssertEqual(availability.recovery, "Connect Github before using github.search_repositories.")

        let search = NexToolSearchService(registry: tools, computerRegistry: computer)
        let candidates = await search.search(query: "Find public GitHub repositories", maximumResults: 8).candidates
        XCTAssertFalse(candidates.contains { $0.tool == "github.search_repositories" })

        let value = try await tools.execute(
            name: "github.search_repositories",
            arguments: ["query": .string("Nexus agent")]
        )
        XCTAssertEqual(value.object?["status"], .string("connection_required"))
        XCTAssertNotNil(value.object?["connectionId"]?.string)
    }

    func testOfficialConnectorExecutorUsesAccountBoundCredentialAndStructuredResult() async throws {
        let memory = NexusMemorySecretStore(), store = NexKeychainConnectorCredentialStore(secrets: memory)
        try store.save(.init(provider: .notion, account: "Nexus Workspace", accessToken: "notion-secret", refreshToken: nil, tokenType: "Bearer", scopes: ["notion.content.read"], expiresAt: .distantFuture, connectedAt: .now, lastSuccessfulUse: nil))
        let session = NexAuthenticatedConnectorSession(store: store, transport: MockOAuthTransport()) { provider in
            NexOAuthConfiguration(provider: provider, clientID: "fixture", authorizationURL: URL(string: "https://example.com/auth")!, tokenURL: URL(string: "https://example.com/token")!, verificationURL: URL(string: "https://example.com/me")!, callbackScheme: "na.nexus.oauth", scopeSeparator: " ", extraAuthorizationItems: [], extraTokenFields: [:])
        }
        let transport = MockConnectorAPITransport()
        let executor = NexOfficialConnectorExecutor(session: session, transport: transport)
        let value = try await executor.execute(provider: "notion", account: "Nexus Workspace", action: "notion.search", arguments: ["query": .string("Nexus"), "limit": .number(5)])
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.notion.com/v1/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer notion-secret")
        XCTAssertEqual(value.object?["status"], .string("completed"))
        XCTAssertFalse(String(describing: value).contains("notion-secret"))
    }

    func testCalendarInvitationResponsePatchesOnlyTheConnectedAttendee() async throws {
        let memory = NexusMemorySecretStore(), store = NexKeychainConnectorCredentialStore(secrets: memory)
        try store.save(.init(provider: .google, account: "test@example.com", accessToken: "calendar-secret", refreshToken: nil, tokenType: "Bearer", scopes: ["calendar.events"], expiresAt: .distantFuture, connectedAt: .now, lastSuccessfulUse: nil))
        let session = NexAuthenticatedConnectorSession(store: store, transport: MockOAuthTransport()) { provider in
            NexOAuthConfiguration(provider: provider, clientID: "fixture", authorizationURL: URL(string: "https://example.com/auth")!, tokenURL: URL(string: "https://example.com/token")!, verificationURL: URL(string: "https://example.com/me")!, callbackScheme: "na.nexus.oauth", scopeSeparator: " ", extraAuthorizationItems: [], extraTokenFields: [:])
        }
        let event = #"{"id":"event-1","attendees":[{"email":"test@example.com","responseStatus":"needsAction"},{"email":"other@example.com","responseStatus":"accepted"}]}"#.data(using: .utf8)!
        let updated = #"{"id":"event-1"}"#.data(using: .utf8)!
        let transport = MockConnectorAPITransport(responseBodies: [event, updated])
        let executor = NexOfficialConnectorExecutor(session: session, transport: transport)

        let value = try await executor.execute(
            provider: "google",
            account: "test@example.com",
            action: "calendar.respond_to_invitation",
            arguments: ["id": .string("event-1"), "response": .string("declined")]
        )

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.absoluteString, "https://www.googleapis.com/calendar/v3/calendars/primary/events/event-1")
        XCTAssertEqual(requests[1].httpMethod, "PATCH")
        let body = try XCTUnwrap(requests[1].httpBody)
        let patch = try JSONDecoder().decode(NexJSONValue.self, from: body)
        let attendees = try XCTUnwrap(patch.object?["attendees"]?.array)
        XCTAssertEqual(attendees[0].object?["email"], .string("test@example.com"))
        XCTAssertEqual(attendees[0].object?["responseStatus"], .string("declined"))
        XCTAssertEqual(attendees[1].object?["email"], .string("other@example.com"))
        XCTAssertEqual(attendees[1].object?["responseStatus"], .string("accepted"))
        XCTAssertEqual(value.object?["status"], .string("completed"))
    }

    func testStoredProviderScopesResolveToExactConnectorCapabilities() {
        let credential = NexConnectorCredential(provider: .google, account: "test@example.com", accessToken: "secret", refreshToken: nil, tokenType: "Bearer", scopes: ["openid", "https://www.googleapis.com/auth/gmail.modify"], expiresAt: .distantFuture, connectedAt: .now, lastSuccessfulUse: nil)
        let document = NexConnectorCapabilityDocument.connected(credential)
        XCTAssertTrue(document.grantedScopes.contains("gmail.readonly"))
        XCTAssertTrue(document.grantedScopes.contains("gmail.modify"))
        XCTAssertEqual(document.capabilities.first(where: { $0.action == "gmail.search" })?.available, true)
        XCTAssertEqual(document.capabilities.first(where: { $0.action == "calendar.list_events" })?.missingScope, "calendar.readonly")
        XCTAssertEqual(document.capabilities.first(where: { $0.action == "google.disconnect" })?.providerLimitation, "No safe official-API executor is available for this action.")
    }

    func testConnectorPendingRequestBindsArgumentsAndExpires() async throws {
        let file = temporaryFile("pending-connectors.json")
        let store = NexConnectorPendingRequestStore(fileURL: file, lifetime: 60)
        let request = try await store.create(provider: "notion", action: "notion.search", arguments: ["query": .string("Nexus")], now: Date(timeIntervalSince1970: 100))
        do { _ = try await store.consume(id: request.id, expectedArguments: ["query": .string("Other")], now: Date(timeIntervalSince1970: 110)); XCTFail("Expected changed argument rejection") } catch let error as NexToolError { XCTAssertEqual(error.code, "connection_arguments_changed") }
        let consumed = try await store.consume(id: request.id, expectedArguments: ["query": .string("Nexus")], now: Date(timeIntervalSince1970: 110))
        XCTAssertEqual(consumed.action, "notion.search")
        let expired = try await store.create(provider: "slack", action: "slack.search", arguments: ["query": .string("launch")], now: Date(timeIntervalSince1970: 200))
        do { _ = try await store.consume(id: expired.id, expectedArguments: nil, now: Date(timeIntervalSince1970: 300)); XCTFail("Expected expiry") } catch let error as NexToolError { XCTAssertEqual(error.code, "connection_request_expired") }
    }

    func testConnectorRequestResumesAfterTheExactProviderConnects() async throws {
        let tools = NexToolRegistry()
        let registry = NexComputerRegistry(
            toolRegistry: tools,
            permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions())
        )
        let store = NexConnectorPendingRequestStore(fileURL: temporaryFile("resume-connectors.json"), lifetime: 60)
        let manager = NexConnectorManager(executor: MockConnectorExecutor(), pendingStore: store)
        try await manager.apply(.disconnected(.slack), to: registry)

        let pending = await NexComputerRuntime(registry: registry).execute(
            actionID: "slack.list_channels",
            arguments: ["limit": .number(1)]
        )
        let connectionRaw = try XCTUnwrap(pending.data.object?["connectionId"]?.string)
        let connectionID = try XCTUnwrap(UUID(uuidString: connectionRaw))
        let connected = NexConnectorCapabilityDocument(
            provider: "slack",
            account: "fixture-workspace",
            connected: true,
            grantedScopes: ["slack.history"],
            capabilities: [
                .init(action: "slack.list_channels", available: true, missingScope: nil, providerLimitation: nil)
            ]
        )
        try await manager.apply(connected, to: registry)

        let resumed = try await manager.resumeRequest(
            id: connectionID,
            expectedArguments: ["limit": .number(1)]
        )
        XCTAssertEqual(resumed.0, "slack.list_channels")
        XCTAssertEqual(resumed.1["limit"], .number(1))
    }

    func testConnectorManagementReportsAndDisconnectsAccounts() throws {
        let memory = NexusMemorySecretStore(), store = NexKeychainConnectorCredentialStore(secrets: memory)
        try store.save(.init(provider: .notion, account: "Nexus Workspace", accessToken: "secret", refreshToken: nil, tokenType: "Bearer", scopes: ["notion.content.read"], expiresAt: nil, connectedAt: .now, lastSuccessfulUse: .now))
        let management = NexConnectorManagementService(store: store)
        let status = try management.status(provider: .notion)
        XCTAssertEqual(status.first?.account, "Nexus Workspace")
        XCTAssertTrue(status.first?.healthy == true)
        try management.disconnect(.notion)
        XCTAssertFalse(try management.status(provider: .notion).first?.connected == true)
    }

    func testConnectorSecurityRejectsWrongOriginAndRedactsSecrets() throws {
        XCTAssertNoThrow(try NexConnectorSecurityPolicy.validateCallback(URL(string: "na.nexus.oauth://oauth/callback?code=abc")!, expectedScheme: "na.nexus.oauth"))
        XCTAssertThrowsError(try NexConnectorSecurityPolicy.validateCallback(URL(string: "na.nexus.oauth://evil/callback?code=abc")!, expectedScheme: "na.nexus.oauth"))
        let loopbackRedirect = URL(string: "http://127.0.0.1:53123/oauth/callback")!
        XCTAssertNoThrow(try NexConnectorSecurityPolicy.validateLoopbackCallback(URL(string: "http://127.0.0.1:53123/oauth/callback?code=abc")!, expectedRedirect: loopbackRedirect))
        XCTAssertThrowsError(try NexConnectorSecurityPolicy.validateLoopbackCallback(URL(string: "http://127.0.0.1:53124/oauth/callback?code=abc")!, expectedRedirect: loopbackRedirect))
        XCTAssertThrowsError(try NexConnectorSecurityPolicy.validateLoopbackCallback(URL(string: "http://localhost:53123/oauth/callback?code=abc")!, expectedRedirect: loopbackRedirect))
        let credential = NexConnectorCredential(provider: .github, account: "vishay", accessToken: "access-secret", refreshToken: "refresh-secret", tokenType: "Bearer", scopes: ["repo"], expiresAt: nil, connectedAt: .now, lastSuccessfulUse: nil)
        let redacted = NexConnectorSecurityPolicy.redacted("Authorization: Bearer access-secret refresh_token=refresh-secret", credentials: [credential])
        XCTAssertFalse(redacted.contains("access-secret")); XCTAssertFalse(redacted.contains("refresh-secret"))
    }

    func testGoogleLoopbackReceiverAcceptsOnlyItsOneTimeCallback() async throws {
        let server = NexLoopbackOAuthCallbackServer()
        let redirect = try await server.start()
        let waiting = Task { try await server.waitForCallback() }
        var components = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: "fixture-state")]
        let (_, response) = try await URLSession.shared.data(from: try XCTUnwrap(components.url))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let callback = try await waiting.value
        XCTAssertEqual(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value, "fixture-code")
        XCTAssertNoThrow(try NexConnectorSecurityPolicy.validateLoopbackCallback(callback, expectedRedirect: redirect))
        server.stop()
    }

    func testConnectorSessionRefreshesRotatesAndRemovesRevokedCredentials() async throws {
        let memory = NexusMemorySecretStore(), store = NexKeychainConnectorCredentialStore(secrets: memory)
        try store.save(.init(provider: .google, account: "test@example.com", accessToken: "old", refreshToken: "refresh", tokenType: "Bearer", scopes: ["openid"], expiresAt: .distantPast, connectedAt: .now, lastSuccessfulUse: nil))
        let session = NexAuthenticatedConnectorSession(store: store, transport: MockOAuthTransport()) { provider in
            NexOAuthConfiguration(provider: provider, clientID: "fixture", authorizationURL: URL(string: "https://example.com/auth")!, tokenURL: URL(string: "https://example.com/token")!, verificationURL: URL(string: "https://example.com/me")!, callbackScheme: "na.nexus.oauth", scopeSeparator: " ", extraAuthorizationItems: [], extraTokenFields: [:])
        }
        let refreshed = try await session.validCredential(for: .google)
        XCTAssertEqual(refreshed.accessToken, "refreshed-access")
        XCTAssertEqual(try store.credential(for: .google)?.accessToken, "refreshed-access")
        try await session.markRevoked(.google)
        XCTAssertNil(try store.credential(for: .google))
    }

    @MainActor
    func testConnectorCredentialsPersistOnlyThroughSecretStore() throws {
        let memory = NexusMemorySecretStore()
        let store = NexKeychainConnectorCredentialStore(secrets: memory)
        let credential = NexConnectorCredential(provider: .google, account: "test@example.com", accessToken: "secret-access", refreshToken: "secret-refresh", tokenType: "Bearer", scopes: ["openid"], expiresAt: Date().addingTimeInterval(3_600), connectedAt: .now, lastSuccessfulUse: .now)
        try store.save(credential)
        let loaded = try XCTUnwrap(store.credential(for: .google))
        XCTAssertEqual(loaded.provider, credential.provider)
        XCTAssertEqual(loaded.account, credential.account)
        XCTAssertEqual(loaded.accessToken, credential.accessToken)
        XCTAssertEqual(loaded.refreshToken, credential.refreshToken)
        XCTAssertEqual(loaded.scopes, credential.scopes)
        let controller = NexConnectorAuthController(store: store, transport: MockOAuthTransport())
        XCTAssertEqual(controller.statuses[.google]?.account, "test@example.com")
        XCTAssertTrue(controller.statuses[.google]?.healthy == true)
        // A new controller represents an Xcode rebuild/relaunch.  It must
        // hydrate the same Keychain-backed record without starting OAuth.
        let relaunchedController = NexConnectorAuthController(store: store, transport: MockOAuthTransport())
        XCTAssertEqual(relaunchedController.statuses[.google]?.account, "test@example.com")
        XCTAssertTrue(relaunchedController.statuses[.google]?.connected == true)
        controller.disconnect(.google)
    }

    func testConnectorRegistrationSecretsAreSeparateFromAccountCredentials() throws {
        let memory = NexusMemorySecretStore()
        let registrations = NexConnectorRegistrationStore(secrets: memory)
        try memory.set(Data("notion-client-secret".utf8), for: "oauth.notion.client-secret.v1")
        try memory.set(Data("github-pem".utf8), for: "github.app.private-key.v1")
        try memory.set(Data("4371707".utf8), for: "github.app.id.v1")

        XCTAssertEqual(try registrations.clientSecret(for: .notion), "notion-client-secret")
        XCTAssertEqual(try registrations.githubAppPrivateKey(), Data("github-pem".utf8))
        XCTAssertEqual(try registrations.githubAppID(), "4371707")

        let credentials = NexKeychainConnectorCredentialStore(secrets: memory)
        XCTAssertNil(try credentials.credential(for: .notion))
    }

    func testDiscordIsNotAConnectableNexusAccount() throws {
        XCTAssertFalse(NexConnectorProvider.discord.supportsUserConnection)
        XCTAssertThrowsError(try NexOAuthConfiguration.configured(.discord)) { error in
            XCTAssertEqual(error as? NexConnectorAuthError, .providerUnavailable(.discord))
        }
    }

    @MainActor
    func testConnectorScopesBeginLeastPrivilege() {
        XCTAssertEqual(NexConnectorAuthController.minimumScopes(.google), ["openid"])
        XCTAssertEqual(NexConnectorAuthController.minimumScopes(.notion), ["notion.content.read"])
        XCTAssertFalse(NexConnectorAuthController.scopeOptions(.google).map(\.id).contains("https://mail.google.com/"))
    }

    func testProviderIconsUseRawUserAssetBytesWithoutATile() {
        guard case .image(let data, let fallback) = NexProviderIconCatalog.icon(for: "terminal.run") else {
            return XCTFail("Terminal should use the embedded user-supplied mark")
        }
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(fallback, "terminal")
        XCTAssertEqual(NexProviderIconCatalog.icon(for: "unregistered.tool"), .systemSymbol("wrench.and.screwdriver"))
    }

    func testCompletedEmailActivityBuildsStructuredConfirmablePreview() throws {
        let confirmationID = UUID()
        let activity = ToolActivity(
            actionID: "gmail.send_draft",
            toolName: "Gmail",
            status: "Ready to send",
            spokenStatus: "",
            icon: NexProviderIconCatalog.icon(for: "gmail.send_draft"),
            phase: .completed,
            arguments: [
                "email": .string("sam@example.com"),
                "title": .string("OpenAI credits"),
                "body": .string("Hi Sam, could we get more credits?")
            ],
            result: .object([
                "status": .string("confirmation_required"),
                "actionId": .string(confirmationID.uuidString),
                "display": .string("Review this message before sending")
            ])
        )
        XCTAssertTrue(activity.requiresExpandedPreview)
        let preview = NexTaskPreviewModel.make(activity: activity)
        XCTAssertEqual(preview.kind, .email)
        XCTAssertEqual(preview.confirmationID, confirmationID)
        XCTAssertEqual(preview.fields.first, .init(label: "To", value: "sam@example.com"))
        XCTAssertTrue(preview.fields.contains(.init(label: "Subject", value: "OpenAI credits")))
    }

    func testConnectionActivityBuildsConnectorPreview() throws {
        let connectionID = UUID()
        let activity = ToolActivity(
            actionID: "notion.search",
            toolName: "Notion",
            status: "Connect Notion",
            spokenStatus: "",
            icon: NexProviderIconCatalog.icon(for: "notion.search"),
            phase: .completed,
            arguments: ["query": .string("Nexus")],
            result: .object([
                "status": .string("connection_required"),
                "connectionId": .string(connectionID.uuidString),
                "display": .string("Connect Notion to continue")
            ])
        )
        let preview = NexTaskPreviewModel.make(activity: activity)
        XCTAssertEqual(preview.kind, .connector)
        XCTAssertEqual(preview.connectionID, connectionID)
    }

    func testMessagesDraftPreviewUsesActualRecipientBodyAndStableDraftID() throws {
        let draftID = UUID().uuidString
        let activity = ToolActivity(
            actionID: "messages.draft",
            toolName: "Messages",
            status: "Drafted message",
            spokenStatus: "",
            icon: .systemSymbol("message"),
            phase: .completed,
            arguments: ["recipient": .string("Alex"), "body": .string("You need to get the milk.")],
            result: .object([
                "status": .string("drafted"),
                "messageDraftId": .string(draftID),
                "recipient": .string("Alex"),
                "body": .string("You need to get the milk.")
            ])
        )
        let preview = NexTaskPreviewModel.make(activity: activity)
        XCTAssertEqual(preview.kind, .message)
        XCTAssertEqual(preview.messageDraftID, draftID)
        XCTAssertEqual(preview.messageRecipient, "Alex")
        XCTAssertEqual(preview.messageBody, "You need to get the milk.")
        XCTAssertTrue(preview.items.contains(.init(title: "You need to get the milk.", detail: "Draft", emphasis: true)))
    }

    func testFinderPreviewUsesPathsAndMakesFirstPathOpenable() throws {
        let path = "/tmp/Project/Brief.pdf"
        let activity = ToolActivity(
            actionID: "finder.search",
            toolName: "Finder",
            status: "Found one item",
            spokenStatus: "",
            icon: .systemSymbol("folder"),
            phase: .completed,
            arguments: ["root": .string("/tmp/Project")],
            result: .object(["status": .string("completed"), "display": .string("Found 1 item."), "paths": .array([.string(path)])])
        )
        let preview = NexTaskPreviewModel.make(activity: activity)
        XCTAssertEqual(preview.kind, .files)
        XCTAssertEqual(preview.targetURL?.path, path)
        XCTAssertEqual(preview.items.first?.title, "Brief.pdf")
    }

    func testCodexAndNexCLIPreserveSpecializedCompactLayouts() {
        let completed = NexToolLifecycleEvent(
            executionID: UUID(),
            toolName: "nex_cli_task",
            phase: .completed,
            message: "Done",
            progress: 1,
            errorCode: nil,
            occurredAt: .now,
            arguments: [:],
            result: .object(["status": .string("completed")])
        )
        XCTAssertFalse(ToolActivity.lifecycle(completed).requiresExpandedPreview)
        let codex = ToolActivity(toolName: "Codex", status: "Done", spokenStatus: "", icon: .systemSymbol("checkmark"), phase: .completed, result: .object(["status": .string("completed")]))
        XCTAssertFalse(codex.requiresExpandedPreview)
    }

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
    }

    private func fixturePDFPage(size: CGFloat) throws -> PDFPage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        image.unlockFocus()
        guard let page = PDFPage(image: image) else { throw NSError(domain: "NexTests", code: 1) }
        return page
    }
}

private actor MockCodexProvider: NexCodexProviding {
    func open() async throws {}
    func start(prompt: String, workspace: URL, sessionID: String?, progress: @escaping @Sendable (String) async -> Void) async throws -> NexCodexTaskSnapshot { await progress("Started"); return .init(sessionID: sessionID ?? "codex-session", status: "running", finalText: "", filesChanged: [], testSummary: "", error: nil) }
    func run(prompt: String, workspace: URL, sessionID: String?, progress: @escaping @Sendable (String) async -> Void) async throws -> NexCodexTaskSnapshot { await progress("Writing files"); return .init(sessionID: sessionID ?? "codex-session", status: "completed", finalText: "Done", filesChanged: ["App.swift"], testSummary: "1 passed", error: nil) }
    func status(sessionID: String) async -> NexCodexTaskSnapshot? { .init(sessionID: sessionID, status: "completed", finalText: "Done", filesChanged: [], testSummary: "", error: nil) }
    func cancel(sessionID: String) async throws {}
    func openSession(sessionID: String) async throws {}
}
private struct MockConnectorExecutor: NexConnectorExecuting { func execute(provider: String, account: String, action: String, arguments: [String: NexJSONValue]) async throws -> NexJSONValue { .object(["display": .string("Executed \(action)"), "status": .string("completed"), "provider": .string(provider), "action": .string(action), "id": .string("fixture"), "items": .array([]), "error": .string("")]) } }
private actor MockConnectorAPITransport: NexConnectorAPITransporting {
    private let defaultResponse = #"{"results":[{"id":"page-1","object":"page"}]}"#.data(using: .utf8)!
    private var responseBodies: [Data]
    private var capturedRequests: [URLRequest] = []
    init(responseBodies: [Data] = []) { self.responseBodies = responseBodies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequests.append(request)
        let data = responseBodies.isEmpty ? defaultResponse : responseBodies.removeFirst()
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func lastRequest() -> URLRequest? { capturedRequests.last }
    func requests() -> [URLRequest] { capturedRequests }
}
private struct MockOAuthTransport: NexOAuthTransporting {
    func exchange(configuration: NexOAuthConfiguration, code: String, verifier: String, callbackURL: URL, scopes: [String]) async throws -> NexConnectorCredential { .init(provider: configuration.provider, account: "test@example.com", accessToken: "access", refreshToken: "refresh", tokenType: "Bearer", scopes: scopes, expiresAt: .distantFuture, connectedAt: .now, lastSuccessfulUse: nil) }
    func verify(configuration: NexOAuthConfiguration, credential: NexConnectorCredential) async throws -> String { credential.account }
    func refresh(configuration: NexOAuthConfiguration, credential: NexConnectorCredential) async throws -> NexConnectorCredential { .init(provider: credential.provider, account: credential.account, accessToken: "refreshed-access", refreshToken: "rotated-refresh", tokenType: credential.tokenType, scopes: credential.scopes, expiresAt: .distantFuture, connectedAt: credential.connectedAt, lastSuccessfulUse: credential.lastSuccessfulUse) }
    func revoke(configuration: NexOAuthConfiguration, credential: NexConnectorCredential) async throws { }
}

private actor MockPhotosProvider: NexPhotosProviding {
    let personSearchSupported: Bool
    var searchCount = 0
    var createdAlbums: [String] = []
    init(personSearchSupported: Bool = true) { self.personSearchSupported = personSearchSupported }
    func open() async throws {}
    func search(_ request: NexPhotoSearchRequest) async throws -> [NexPhotoRecord] {
        if request.person != nil, !personSearchSupported { throw NexPhotosError.unsupportedFilter("person") }
        searchCount += 1
        return [.init(id: "photo-1", filename: "IMG_0001.HEIC", createdAt: Date(timeIntervalSince1970: 1_700_000_000), mediaType: "image", favorite: true, latitude: 37.77, longitude: -122.42, width: 4032, height: 3024, duration: 0)]
    }
    func openResult(id: String) async throws -> Bool { true }
    func export(ids: [String], destination: URL) async throws -> [URL] { ids.map { destination.appendingPathComponent("\($0).jpg") } }
    func createAlbum(name: String) async throws -> String { createdAlbums.append(name); return "album-1" }
    func add(ids: [String], toAlbumID albumID: String) async throws -> Int { ids.count }
}
