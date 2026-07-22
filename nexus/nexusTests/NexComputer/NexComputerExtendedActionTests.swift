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

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
    }
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
