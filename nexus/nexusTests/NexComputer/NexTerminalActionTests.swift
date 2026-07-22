import XCTest
@testable import nexus

final class NexTerminalActionTests: XCTestCase {
    func testHarmlessCommandCapturesStdoutWorkingDirectoryAndExitStatus() async throws {
        let directory = try temporaryDirectory()
        let manager = NexTerminalSessionManager(allowedWorkingRoots: [directory])
        let snapshot = try await manager.run(
            executable: "/bin/echo",
            arguments: ["hello nexus"],
            workingDirectory: directory.path,
            environmentEntries: ["NO_COLOR=1"],
            progress: { _, _ in }
        )

        XCTAssertEqual(snapshot.workingDirectory, directory.path)
        XCTAssertEqual(snapshot.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello nexus")
        XCTAssertEqual(snapshot.stderr, "")
        XCTAssertEqual(snapshot.exitStatus, 0)
        XCTAssertFalse(snapshot.isRunning)
    }

    func testStderrIsSeparateAndNonzeroExitIsPreserved() async throws {
        let directory = try temporaryDirectory()
        let manager = NexTerminalSessionManager(allowedWorkingRoots: [directory])
        let snapshot = try await manager.run(
            executable: "/bin/ls",
            arguments: ["definitely-not-present"],
            workingDirectory: directory.path,
            environmentEntries: [],
            progress: { _, _ in }
        )

        XCTAssertEqual(snapshot.stdout, "")
        XCTAssertTrue(snapshot.stderr.contains("definitely-not-present"))
        XCTAssertNotEqual(snapshot.exitStatus, 0)
    }

    func testShellSyntaxAndUnapprovedEnvironmentAreRejected() async throws {
        let directory = try temporaryDirectory()
        let manager = NexTerminalSessionManager(allowedWorkingRoots: [directory])

        await XCTAssertThrowsTerminalError {
            _ = try await manager.run(
                executable: "/bin/echo",
                arguments: ["safe; touch escaped"],
                workingDirectory: directory.path,
                environmentEntries: [],
                progress: { _, _ in }
            )
        } verify: { error in
            guard case .shellSyntaxRejected = error else { return XCTFail("Unexpected error: \(error)") }
        }

        await XCTAssertThrowsTerminalError {
            _ = try await manager.run(
                executable: "/bin/echo",
                arguments: ["safe"],
                workingDirectory: directory.path,
                environmentEntries: ["API_TOKEN=secret"],
                progress: { _, _ in }
            )
        } verify: { error in
            XCTAssertEqual(error, .environmentKeyNotAllowed("API_TOKEN"))
        }
    }

    func testInteractivePromptReturnsSessionAndAcceptsBoundedResponse() async throws {
        let directory = try temporaryDirectory()
        let manager = NexTerminalSessionManager(allowedWorkingRoots: [directory])
        let prompted = try await manager.run(
            executable: "/usr/bin/python3",
            arguments: ["-c", "print(input('Continue? [y/n] '))"],
            workingDirectory: directory.path,
            environmentEntries: [],
            progress: { _, _ in }
        )

        XCTAssertTrue(prompted.isRunning)
        XCTAssertEqual(prompted.promptState, .yesNo)
        try await manager.respond(sessionID: prompted.id, response: "yes")
        let completed = try await waitForCompletion(manager: manager, id: prompted.id)
        XCTAssertEqual(completed.exitStatus, 0)
        XCTAssertTrue(completed.stdout.contains("yes"))
    }

    func testRegisteredRunCommandUsesConfirmationGatewayBeforeProcessStarts() async throws {
        let directory = try temporaryDirectory()
        let pendingURL = directory.appendingPathComponent("pending.json")
        let gateway = NexComputerConfirmationGateway(store: NexComputerPendingActionStore(fileURL: pendingURL))
        let core = NexToolRegistry()
        let computer = NexComputerRegistry(toolRegistry: core, confirmationGateway: gateway)
        let catalog = NexTerminalActionCatalog(
            sessions: NexTerminalSessionManager(allowedWorkingRoots: [directory])
        )
        try await catalog.register(on: computer)

        let arguments: [String: NexJSONValue] = [
            "executable": .string("/bin/echo"),
            "arguments": .array([.string("confirmed")]),
            "workingDirectory": .string(directory.path)
        ]
        let pending = try await core.execute(name: "terminal.run_command", arguments: arguments)
        guard case .object(let pendingObject) = pending,
              pendingObject["status"] == .string("confirmation_required"),
              let rawID = pendingObject["actionId"]?.string else {
            return XCTFail("Expected confirmation_required")
        }

        let completed = try await core.execute(
            name: "confirm_action",
            arguments: ["actionId": .string(rawID)]
        )
        guard case .object(let result) = completed else { return XCTFail("Expected terminal result") }
        XCTAssertEqual(result["exitStatus"], .number(0))
        XCTAssertTrue(result["stdout"]?.string?.contains("confirmed") == true)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexTerminalActionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func waitForCompletion(
        manager: NexTerminalSessionManager,
        id: UUID
    ) async throws -> NexTerminalSessionSnapshot {
        for _ in 0..<100 {
            guard let snapshot = await manager.snapshot(sessionID: id) else { throw NexTerminalError.sessionNotFound(id) }
            if !snapshot.isRunning { return snapshot }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Terminal session did not complete")
        throw NexTerminalError.sessionNotRunning(id)
    }
}

private func XCTAssertThrowsTerminalError<T>(
    _ expression: () async throws -> T,
    verify: (NexTerminalError) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected NexTerminalError", file: file, line: line)
    } catch let error as NexTerminalError {
        verify(error)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
