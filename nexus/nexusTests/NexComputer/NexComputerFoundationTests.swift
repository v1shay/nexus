import XCTest
@testable import nexus

final class NexComputerFoundationTests: XCTestCase {
    private actor Counter {
        private var value = 0

        func increment() -> Int {
            value += 1
            return value
        }

        func current() -> Int { value }
    }

    func testManifestIsVersionedCodableAndRejectsLowLevelActionIDs() throws {
        let manifest = makeManifest()
        try manifest.validate()

        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(NexComputerActionManifest.self, from: encoded)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.implementationMethod.priority, 1)

        let invalid = makeManifest(actionID: "click")
        XCTAssertThrowsError(try invalid.validate()) { error in
            XCTAssertEqual(error as? NexComputerManifestError, .invalidActionID("click"))
        }

        let coordinateFallback = makeManifest(
            implementationMethod: .coordinateAutomationUnsupported,
            availabilityCheck: .always
        )
        XCTAssertThrowsError(try coordinateFallback.validate()) { error in
            XCTAssertEqual(
                error as? NexComputerManifestError,
                .coordinateAutomationMustRemainUnsupported
            )
        }
    }

    func testRegistrationUsesExistingToolRegistryAndDryRunHasNoSideEffect() async throws {
        let core = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: core)
        let runtime = NexComputerRuntime(registry: registry)
        let counter = Counter()

        try await registry.register(manifest: makeManifest()) { arguments, _ in
            _ = await counter.increment()
            return .object([
                "display": .string("Opened the fixture."),
                "value": arguments["query"] ?? .null
            ])
        }

        let registeredNames = await core.definitions().map(\.name)
        XCTAssertEqual(registeredNames, ["fixture.open"])
        let result = await runtime.execute(
            actionID: "fixture.open",
            arguments: ["query": .string("private value")],
            options: .init(dryRun: true)
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.status, .dryRun)
        XCTAssertEqual(result.action, "fixture.open")
        let dryRunExecutions = await counter.current()
        XCTAssertEqual(dryRunExecutions, 0)
        guard case .object(let data) = result.data else { return XCTFail("Expected dry-run object") }
        XCTAssertEqual(data["implementation"], .string("native_api"))
        XCTAssertEqual(data["risk"], .string("low"))
    }

    func testRuntimeValidatesOutputAndReturnsStructuredErrors() async throws {
        let core = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: core)
        let runtime = NexComputerRuntime(registry: registry)

        try await registry.register(manifest: makeManifest()) { _, _ in
            .object(["unexpected": .string("not declared")])
        }

        let result = await runtime.execute(
            actionID: "fixture.open",
            arguments: ["query": .string("fixture")]
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error?.code, "INVALID_OUTPUT")
        XCTAssertEqual(
            result.error?.recovery,
            "Update the executor to match its declared output schema."
        )
    }

    func testAvailabilityFailureIsActionableAndNeverRunsHandler() async throws {
        let core = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: core)
        let runtime = NexComputerRuntime(registry: registry)
        let counter = Counter()

        try await registry.register(
            manifest: makeManifest(availabilityCheck: .custom("fixture.ready")),
            availability: {
                .unavailable(
                    "Fixture is offline.",
                    recovery: "Start the fixture service and retry."
                )
            }
        ) { _, _ in
            _ = await counter.increment()
            return .object(["display": .string("Should not execute")])
        }

        let result = await runtime.execute(
            actionID: "fixture.open",
            arguments: ["query": .string("fixture")]
        )
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertEqual(result.error?.code, "UNAVAILABLE")
        XCTAssertEqual(result.error?.recovery, "Start the fixture service and retry.")
        let unavailableExecutions = await counter.current()
        XCTAssertEqual(unavailableExecutions, 0)
    }

    func testRuntimeTimesOutAndCancelsCancellationAwareExecutor() async throws {
        let core = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: core)
        let runtime = NexComputerRuntime(registry: registry)

        try await registry.register(manifest: makeManifest(timeoutSeconds: 0.1)) { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return .object(["display": .string("Too late")])
        }

        let started = Date()
        let result = await runtime.execute(
            actionID: "fixture.open",
            arguments: ["query": .string("fixture")]
        )
        XCTAssertEqual(result.status, .timedOut)
        XCTAssertEqual(result.error?.code, "TIMED_OUT")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testExplicitCancellationUsesStableExecutionID() async throws {
        let core = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: core)
        let runtime = NexComputerRuntime(registry: registry)
        let executionID = UUID()

        try await registry.register(manifest: makeManifest(timeoutSeconds: 2)) { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return .object(["display": .string("Too late")])
        }

        let execution = Task {
            await runtime.execute(
                actionID: "fixture.open",
                arguments: ["query": .string("fixture")],
                executionID: executionID
            )
        }
        try await Task.sleep(nanoseconds: 25_000_000)
        let cancelled = await runtime.cancel(executionID: executionID)
        XCTAssertTrue(cancelled)
        let result = await execution.value
        XCTAssertEqual(result.executionID, executionID)
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.error?.code, "CANCELLED")
    }

    func testRetryPolicyRetriesOnlyDeclaredTransientFailure() async throws {
        let core = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: core)
        let runtime = NexComputerRuntime(registry: registry)
        let counter = Counter()
        let retry = NexComputerRetryPolicy(
            maximumAttempts: 2,
            initialBackoffMilliseconds: 1,
            maximumBackoffMilliseconds: 2,
            retryableErrorCodes: ["TRANSIENT"]
        )

        try await registry.register(manifest: makeManifest(retryPolicy: retry)) { _, _ in
            let attempt = await counter.increment()
            if attempt == 1 {
                throw NexComputerActionFailure(
                    code: "TRANSIENT",
                    message: "Fixture was briefly busy.",
                    retryable: true
                )
            }
            return .object(["display": .string("Opened after retry")])
        }

        let result = await runtime.execute(
            actionID: "fixture.open",
            arguments: ["query": .string("fixture")]
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.status, .completed)
        let attempts = await counter.current()
        XCTAssertEqual(attempts, 2)
    }

    func testActionLogRecordsKeysButNeverArgumentValues() async throws {
        let core = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: core)
        let logger = NexComputerActionLogger()
        let runtime = NexComputerRuntime(registry: registry, logger: logger)

        try await registry.register(manifest: makeManifest()) { _, _ in
            .object(["display": .string("Opened safely")])
        }
        _ = await runtime.execute(
            actionID: "fixture.open",
            arguments: ["query": .string("super-secret-value")]
        )

        let entries = await runtime.recentLogEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].argumentKeys, ["query"])
        let encoded = String(data: try JSONEncoder().encode(entries), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("super-secret-value"))
    }

    private func makeManifest(
        actionID: String = "fixture.open",
        implementationMethod: NexComputerImplementationMethod = .nativeAPI,
        availabilityCheck: NexComputerAvailabilityCheck = .always,
        timeoutSeconds: Double = 1,
        retryPolicy: NexComputerRetryPolicy = .none
    ) -> NexComputerActionManifest {
        NexComputerActionManifest(
            actionID: actionID,
            application: "Fixture",
            provider: "Nexus Tests",
            description: "Open a harmless test fixture by semantic query.",
            examples: ["Open my fixture"],
            aliases: ["fixture launch"],
            tags: ["fixture", "open"],
            inputSchema: .init(fields: [
                "query": .init(.string, required: true)
            ]),
            outputSchema: .init(fields: [
                "display": .init(.string, required: true),
                "value": .init(.string),
                "warnings": .init(.stringArray)
            ]),
            implementationMethod: implementationMethod,
            registryPermission: .automation,
            riskClass: .low,
            confirmationPolicy: .never,
            availabilityCheck: availabilityCheck,
            timeoutSeconds: timeoutSeconds,
            supportsCancellation: true,
            retryPolicy: retryPolicy,
            dryRunBehavior: .supported("Would open the harmless fixture."),
            previewRenderer: "fixture.preview",
            tests: ["NexComputerFoundationTests"]
        )
    }
}
