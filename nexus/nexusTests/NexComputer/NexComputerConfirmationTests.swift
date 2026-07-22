import XCTest
@testable import nexus

final class NexComputerConfirmationTests: XCTestCase {
    private actor Counter {
        private var count = 0
        func increment() { count += 1 }
        func value() -> Int { count }
    }

    private struct PermissionBackend: NexComputerPermissionChecking {
        let state: NexComputerPermissionState
        let recovery: String?

        func status(for requirement: NexComputerPermissionRequirement) async -> NexComputerPermissionStatus {
            .init(requirementID: requirement.id, state: state, recovery: recovery)
        }

        func request(for requirement: NexComputerPermissionRequirement) async -> NexComputerPermissionStatus {
            .init(requirementID: requirement.id, state: state, recovery: recovery)
        }
    }

    func testHighRiskActionRequiresBoundConfirmationAndExecutesExactlyOnce() async throws {
        let fixture = try temporaryFixture()
        let counter = Counter()
        let gateway = NexComputerConfirmationGateway(store: fixture.store)
        let core = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: core, confirmationGateway: gateway)
        try await registry.register(manifest: manifest(risk: .high, confirmation: .never)) { arguments, _ in
            await counter.increment()
            return .object(["display": .string("Sent \(arguments["recipient"]?.string ?? "")")])
        }

        let arguments: [String: NexJSONValue] = ["recipient": .string("vishay@example.com")]
        let first = try await core.execute(name: "fixture.send", arguments: arguments)
        let second = try await core.execute(name: "fixture.send", arguments: arguments)
        let beforeConfirmation = await counter.value()
        XCTAssertEqual(beforeConfirmation, 0)
        let firstID = try confirmationID(first)
        XCTAssertEqual(try confirmationID(second), firstID, "Repeated identical requests must reuse one pending action")

        _ = try await core.execute(
            name: "confirm_action",
            arguments: ["actionId": .string(firstID.uuidString)]
        )
        let afterConfirmation = await counter.value()
        XCTAssertEqual(afterConfirmation, 1)

        do {
            _ = try await core.execute(
                name: "confirm_action",
                arguments: ["actionId": .string(firstID.uuidString)]
            )
            XCTFail("Consumed approval must never replay")
        } catch let error as NexComputerConfirmationError {
            guard case .alreadyConsumed(let id, .completed) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(id, firstID)
        }
        let afterReplay = await counter.value()
        XCTAssertEqual(afterReplay, 1)
    }

    func testConfirmationRejectsModifiedPayloadAndExpires() async throws {
        let fixture = try temporaryFixture()
        let gateway = NexComputerConfirmationGateway(store: fixture.store, lifetime: 10)
        let start = Date(timeIntervalSince1970: 1_000)
        let original: [String: NexJSONValue] = ["recipient": .string("first@example.com")]
        let pending = try await gateway.request(manifest: manifest(), arguments: original, now: start)

        await XCTAssertThrowsErrorAsync {
            _ = try await gateway.authorize(
                id: pending.id,
                expectedManifest: manifest(),
                expectedArguments: ["recipient": .string("changed@example.com")],
                now: start.addingTimeInterval(1)
            )
        } verify: { error in
            XCTAssertEqual(error as? NexComputerConfirmationError, .payloadChanged(pending.id))
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await gateway.authorize(id: pending.id, now: start.addingTimeInterval(11))
        } verify: { error in
            XCTAssertEqual(error as? NexComputerConfirmationError, .expired(pending.id))
        }
    }

    func testPendingActionSurvivesRestartAndExecutingActionCannotReplay() async throws {
        let fixture = try temporaryFixture()
        let gateway = NexComputerConfirmationGateway(store: fixture.store)
        let pending = try await gateway.request(
            manifest: manifest(),
            arguments: ["recipient": .string("saved@example.com")]
        )

        let reloadedStore = NexComputerPendingActionStore(fileURL: fixture.url)
        let reloadedGateway = NexComputerConfirmationGateway(store: reloadedStore)
        let recoveredIDs = try await reloadedGateway.recoverable().map(\.id)
        XCTAssertEqual(recoveredIDs, [pending.id])

        _ = try await reloadedGateway.authorize(id: pending.id)
        let afterInterruptedRestart = NexComputerPendingActionStore(fileURL: fixture.url)
        let interruptedRecoverable = try await NexComputerConfirmationGateway(store: afterInterruptedRestart).recoverable()
        XCTAssertTrue(interruptedRecoverable.isEmpty)
        let interruptedStatus = await afterInterruptedRestart.record(id: pending.id)?.status
        XCTAssertEqual(interruptedStatus, .interrupted)
    }

    func testCancellationConsumesPendingActionWithoutExecuting() async throws {
        let fixture = try temporaryFixture()
        let counter = Counter()
        let gateway = NexComputerConfirmationGateway(store: fixture.store)
        let core = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: core, confirmationGateway: gateway)
        try await registry.register(manifest: manifest()) { _, _ in
            await counter.increment()
            return .object(["display": .string("Should not happen")])
        }
        let result = try await core.execute(
            name: "fixture.send",
            arguments: ["recipient": .string("cancel@example.com")]
        )
        let id = try confirmationID(result)
        _ = try await core.execute(name: "cancel_action", arguments: ["actionId": .string(id.uuidString)])
        let cancellationCount = await counter.value()
        let cancellationStatus = await fixture.store.record(id: id)?.status
        XCTAssertEqual(cancellationCount, 0)
        XCTAssertEqual(cancellationStatus, .cancelled)
    }

    func testPermissionDenialReturnsRecoveryAndDryRunStaysSideEffectFree() async throws {
        let fixture = try temporaryFixture()
        let counter = Counter()
        let permissions = NexComputerPermissionManager(
            backend: PermissionBackend(
                state: .denied,
                recovery: "Enable Calendar access in System Settings."
            )
        )
        let core = NexToolRegistry()
        let registry = NexComputerRegistry(
            toolRegistry: core,
            confirmationGateway: NexComputerConfirmationGateway(store: fixture.store),
            permissionManager: permissions
        )
        let runtime = NexComputerRuntime(registry: registry)
        try await registry.register(manifest: manifest(
            requiredPermissions: [.init(id: "calendar", permission: .automation)]
        )) { _, _ in
            await counter.increment()
            return .object(["display": .string("Should not execute")])
        }

        let denied = await runtime.execute(
            actionID: "fixture.send",
            arguments: ["recipient": .string("calendar@example.com")]
        )
        XCTAssertEqual(denied.status, .permissionRequired)
        XCTAssertEqual(denied.error?.permission, "calendar")
        XCTAssertEqual(denied.error?.recovery, "Enable Calendar access in System Settings.")
        let deniedCount = await counter.value()
        XCTAssertEqual(deniedCount, 0)

        let dryRun = await runtime.execute(
            actionID: "fixture.send",
            arguments: ["recipient": .string("calendar@example.com")],
            options: .init(dryRun: true)
        )
        XCTAssertEqual(dryRun.status, .dryRun)
        let dryRunCount = await counter.value()
        XCTAssertEqual(dryRunCount, 0)
    }

    private func manifest(
        risk: NexComputerRiskClass = .high,
        confirmation: NexComputerConfirmationPolicy = .always,
        requiredPermissions: [NexComputerPermissionRequirement] = []
    ) -> NexComputerActionManifest {
        NexComputerActionManifest(
            actionID: "fixture.send",
            application: "Fixture Mail",
            provider: "Fixture",
            description: "Send one message to the specified recipient.",
            examples: ["Send the fixture message"],
            aliases: ["send message"],
            tags: ["message", "send"],
            inputSchema: .init(fields: ["recipient": .init(.string, required: true)]),
            outputSchema: .init(fields: ["display": .init(.string, required: true)]),
            implementationMethod: .nativeAPI,
            requiredPermissions: requiredPermissions,
            registryPermission: .automation,
            riskClass: risk,
            confirmationPolicy: confirmation,
            availabilityCheck: .always,
            timeoutSeconds: 1,
            supportsCancellation: true,
            dryRunBehavior: .supported("Would send one fixture message."),
            previewRenderer: "fixture.message",
            tests: ["confirmation"]
        )
    }

    private func temporaryFixture() throws -> (url: URL, store: NexComputerPendingActionStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexComputerConfirmationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("pending-actions.json")
        return (url, NexComputerPendingActionStore(fileURL: url))
    }

    private func confirmationID(_ value: NexJSONValue) throws -> UUID {
        guard case .object(let object) = value,
              object["status"] == .string("confirmation_required"),
              let raw = object["actionId"]?.string,
              let id = UUID(uuidString: raw) else {
            throw XCTSkip("Expected a confirmation_required response")
        }
        return id
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        verify(error)
    }
}
