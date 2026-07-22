import XCTest
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
        let names = Set(await tools.definitions().map(\.name))
        XCTAssertTrue(Set(["codex.open", "codex.start_task", "codex.continue_task", "codex.get_status", "codex.cancel_task", "codex.open_session"]).isSubset(of: names))
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

    func testGitStatusUsesArgvAndReturnsRepositoryState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let cli = NexGitHubCLIProvider(); _ = try await cli.git(["init", "-q"], repository: root); try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let result = try await cli.git(["status", "--porcelain=v1"], repository: root); XCTAssertTrue(result.stdout.contains("README.md"))
    }

    func testSystemCatalogExposesExplicitFocusLimitation() async throws {
        let tools = NexToolRegistry(), computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions())); try await NexSystemActionCatalog().register(on: computer)
        let names = Set(await tools.definitions().map(\.name)); XCTAssertTrue(Set(["system.open_setting", "system.get_volume", "system.set_volume", "system.get_display_state", "system.toggle_focus_mode", "system.get_battery", "system.get_network_state"]).isSubset(of: names))
        let available = try await computer.availability(actionID: "system.toggle_focus_mode"); XCTAssertFalse(available.isAvailable); XCTAssertTrue((available.reason ?? "").contains("Focus"))
    }

    func testXcodeCatalogRegistersBuildAndTestActions() async throws {
        let tools = NexToolRegistry(), computer = NexComputerRegistry(toolRegistry: tools, permissionManager: NexComputerPermissionManager(backend: AuthorizedPermissions())); try await NexXcodeActionCatalog().register(on: computer); let names = Set(await tools.definitions().map(\.name)); XCTAssertTrue(Set(["xcode.open", "xcode.open_project", "xcode.build", "xcode.test", "xcode.run", "xcode.get_build_status", "xcode.open_file"]).isSubset(of: names))
    }

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
    }
}

private actor MockCodexProvider: NexCodexProviding {
    func open() async throws {}
    func run(prompt: String, workspace: URL, sessionID: String?, progress: @escaping @Sendable (String) async -> Void) async throws -> NexCodexTaskSnapshot { await progress("Writing files"); return .init(sessionID: sessionID ?? "codex-session", status: "completed", finalText: "Done", filesChanged: ["App.swift"], testSummary: "1 passed", error: nil) }
    func status(sessionID: String) async -> NexCodexTaskSnapshot? { .init(sessionID: sessionID, status: "completed", finalText: "Done", filesChanged: [], testSummary: "", error: nil) }
    func cancel(sessionID: String) async throws {}
    func openSession(sessionID: String) async throws {}
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
