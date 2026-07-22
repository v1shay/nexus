import XCTest
@testable import nexus

final class NexFinderActionTests: XCTestCase {
    func testSearchFiltersFilenameExtensionContentSizeAndLimit() async throws {
        let root = try fixtureRoot()
        try Data("Nexus alpha project".utf8).write(to: root.appendingPathComponent("Alpha.md"))
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("Beta.md"))
        try Data("Nexus alpha project".utf8).write(to: root.appendingPathComponent("Alpha.txt"))
        let service = NexFinderFileService(allowedRoots: [root])

        let matches = try await service.search(.init(
            rootPath: root.path,
            nameContains: "alpha",
            fileExtension: "md",
            contentContains: "nexus",
            modifiedAfter: nil,
            modifiedBefore: nil,
            minimumSize: 5,
            maximumSize: 100,
            limit: 1
        ))
        XCTAssertEqual(matches.map(\.lastPathComponent), ["Alpha.md"])
    }

    func testSymlinkEscapeAndTraversalAreRejected() async throws {
        let root = try fixtureRoot()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("NexFinderOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let service = NexFinderFileService(allowedRoots: [root])

        do {
            _ = try await service.validatedExistingURL(path: link.appendingPathComponent("secret.txt").path)
            XCTFail("Symlink escape should fail")
        } catch let error as NexFinderError {
            guard case .pathOutsideAllowedRoots = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCreateCopyMoveRenameCollisionPoliciesAndTrashUseOnlyFixture() async throws {
        let root = try fixtureRoot()
        let source = root.appendingPathComponent("source.txt")
        try Data("fixture".utf8).write(to: source)
        let fakeTrash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let service = NexFinderFileService(allowedRoots: [root], trashDirectoryOverride: fakeTrash)
        let destination = try await service.createFolder(parentPath: root.path, name: "Destination", collisionPolicy: .error)
        let copied = try await service.copy(sourcePath: source.path, destinationDirectory: destination.path, collisionPolicy: .error)
        let kept = try await service.copy(sourcePath: source.path, destinationDirectory: destination.path, collisionPolicy: .keepBoth)
        XCTAssertNotEqual(copied, kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))

        let renamed = try await service.rename(path: copied.path, newName: "renamed.txt", collisionPolicy: .error)
        XCTAssertEqual(renamed.lastPathComponent, "renamed.txt")
        let moved = try await service.move(sourcePath: renamed.path, destinationDirectory: root.path, collisionPolicy: .error)
        XCTAssertEqual(moved.deletingLastPathComponent().path, root.path)
        _ = try await service.trash(path: moved.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
    }

    func testMutationManifestRequiresConfirmationAndExactPayload() async throws {
        let root = try fixtureRoot()
        let gateway = NexComputerConfirmationGateway(store: NexComputerPendingActionStore(fileURL: root.appendingPathComponent("pending.json")))
        let core = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: core, confirmationGateway: gateway)
        let catalog = NexFinderActionCatalog(files: NexFinderFileService(allowedRoots: [root]))
        try await catalog.register(on: registry)

        let pending = try await core.execute(name: "finder.create_folder", arguments: [
            "parent": .string(root.path), "name": .string("Confirmed"), "collisionPolicy": .string("error")
        ])
        guard case .object(let object) = pending,
              object["status"] == .string("confirmation_required"),
              let actionID = object["actionId"]?.string else { return XCTFail("Expected confirmation") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Confirmed").path))

        _ = try await core.execute(name: "confirm_action", arguments: ["actionId": .string(actionID)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Confirmed").path))
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NexFinderActionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
