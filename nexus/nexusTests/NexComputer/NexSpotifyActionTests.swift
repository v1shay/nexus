import XCTest
@testable import nexus

final class NexSpotifyActionTests: XCTestCase {
    private actor MockSpotify: NexSpotifyControlling {
        var searches: [String] = []
        var played: [String] = []
        var controls: [String] = []
        var volumes: [Int] = []
        func open() async throws {}
        func openSearch(query: String) async throws { searches.append(query) }
        func play(uri: String) async throws { played.append(uri) }
        func control(_ command: String) async throws { controls.append(command) }
        func setVolume(_ volume: Int) async throws { volumes.append(volume) }
        func currentTrack() async throws -> NexSpotifyPlaybackSnapshot {
            .init(title: "Summer", artist: "Calvin Harris", album: "Motion", uri: "spotify:track:fixture", state: "playing", volume: 42)
        }
    }

    private struct AuthorizedPermissions: NexComputerPermissionChecking {
        func status(for requirement: NexComputerPermissionRequirement) async -> NexComputerPermissionStatus {
            .init(requirementID: requirement.id, state: .authorized, recovery: nil)
        }
        func request(for requirement: NexComputerPermissionRequirement) async -> NexComputerPermissionStatus {
            .init(requirementID: requirement.id, state: .authorized, recovery: nil)
        }
    }

    func testNamePlaybackOpensSearchWithoutFabricatingResolution() async throws {
        let (core, mock) = try await fixture()
        let result = try await core.execute(name: "spotify.play", arguments: [
            "query": .string("Summer"), "artist": .string("Calvin Harris"), "type": .string("track"), "shuffle": .bool(false)
        ])
        guard case .object(let object) = result else { return XCTFail("Expected object") }
        XCTAssertEqual(object["status"], .string("resolution_required"))
        XCTAssertEqual(object["resolved"], .bool(false))
        let searches = await mock.searches
        let played = await mock.played
        XCTAssertEqual(searches, ["Summer Calvin Harris"])
        XCTAssertTrue(played.isEmpty)
    }

    func testExactSpotifyURIPlaysAndReturnsVerifiedTrack() async throws {
        let (core, mock) = try await fixture()
        let result = try await core.execute(name: "spotify.play", arguments: ["query": .string("spotify:track:fixture")])
        guard case .object(let object) = result else { return XCTFail("Expected object") }
        XCTAssertEqual(object["resolved"], .bool(true))
        XCTAssertEqual(object["title"], .string("Summer"))
        let played = await mock.played
        XCTAssertEqual(played, ["spotify:track:fixture"])
    }

    func testPlaybackControlsAndExactVolumeUseDesktopController() async throws {
        let (core, mock) = try await fixture()
        _ = try await core.execute(name: "spotify.control", arguments: ["command": .string("next")])
        _ = try await core.execute(name: "spotify.set_volume", arguments: ["volume": .number(35)])
        let controls = await mock.controls
        let volumes = await mock.volumes
        XCTAssertEqual(controls, ["next"])
        XCTAssertEqual(volumes, [35])
    }

    func testAllRequiredSpotifyActionsRegisterWithSemanticMetadata() async throws {
        let (core, _) = try await fixture()
        let names = Set(await core.definitions().map(\.name))
        XCTAssertTrue(Set(["spotify.open", "spotify.search", "spotify.play", "spotify.control", "spotify.get_current_track", "spotify.set_volume"]).isSubset(of: names))
    }

    private func fixture() async throws -> (NexToolRegistry, MockSpotify) {
        let core = NexToolRegistry()
        let mock = MockSpotify()
        let permissions = NexComputerPermissionManager(backend: AuthorizedPermissions())
        let computer = NexComputerRegistry(toolRegistry: core, permissionManager: permissions)
        try await NexSpotifyActionCatalog(controller: mock).register(on: computer)
        return (core, mock)
    }
}
