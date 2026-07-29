import CryptoKit
import Foundation
import XCTest
@testable import nexus

extension NexusGeometryTests {
    func testRuntimeInventoryDiagnosticsRemainBackwardCompatible() throws {
        let legacy = #"{"runtimes":[],"defaultRuntime":null}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NexusRuntimeInventoryPayload.self, from: legacy)

        XCTAssertTrue(decoded.runtimes.isEmpty)
        XCTAssertNil(decoded.defaultRuntime)
        XCTAssertNil(decoded.detectedRuntimeNames)

        let current = NexusRuntimeInventoryPayload(
            runtimes: [.init(kind: .ollama, isManagedByNexus: false)],
            defaultRuntime: .ollama,
            detectedRuntimeNames: ["ollama", "mlx"]
        )
        let roundTrip = try JSONDecoder().decode(
            NexusRuntimeInventoryPayload.self,
            from: JSONEncoder().encode(current)
        )
        XCTAssertEqual(roundTrip, current)
    }

    func testHostStreamsInferenceAndCompletesWithTypedEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = NexusHostModelStub()
        let host = NexusHostServiceExecutor(
            nodeID: UUID(),
            policy: Self.hostTestPolicy(root: root),
            models: models,
            index: NexusTextIndex(persistenceURL: root.appendingPathComponent("index.json"))
        )
        let request = try NexusWorkloadRequest(
            kind: .inference,
            priority: .interactive,
            retrySafety: .idempotent,
            payload: NexusInferencePayload(
                runtime: .ollama,
                model: "large:120b",
                messages: [.init(role: "user", content: "hello")],
                temperature: nil,
                maximumTokens: nil
            )
        )
        let events = NexusEventCollector()

        await host.execute(request) { await events.append($0) }

        let collected = await events.values()
        XCTAssertEqual(collected.map(\.kind), [.accepted, .token, .token, .result, .completed])
        XCTAssertEqual(collected.map(\.sequence), [0, 1, 2, 3, 4])
        XCTAssertTrue(collected.last?.isFinal == true)
        let answer = try collected[3].decodePayload(NexusTextDeltaPayload.self)
        XCTAssertEqual(answer.accumulated, "Hello from Studio")
    }

    func testHostResumableFileWriteReadIndexAndSearchStayInsideAllowedRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = NexusHostServiceExecutor(
            nodeID: UUID(),
            policy: Self.hostTestPolicy(root: root),
            models: NexusHostModelStub(),
            index: NexusTextIndex(persistenceURL: root.appendingPathComponent(".index/index.json"))
        )
        let transferID = UUID()
        let first = Data("Nexus remote ".utf8)
        let second = Data("indexing works".utf8)
        let all = first + second
        let reference = NexusFileReference(rootID: "workspace", relativePath: "notes/test.md")

        for (offset, data, final) in [(Int64(0), first, false), (Int64(first.count), second, true)] {
            let payload = NexusFileWritePayload(
                file: reference,
                transferID: transferID,
                offset: offset,
                data: data,
                chunkSHA256: Data(SHA256.hash(data: data)),
                finalSize: final ? Int64(all.count) : nil,
                finalSHA256: final ? Data(SHA256.hash(data: all)) : nil
            )
            let request = try NexusWorkloadRequest(kind: .fileWrite, retrySafety: .resumable, payload: payload)
            await host.execute(request) { _ in }
        }

        let readEvents = NexusEventCollector()
        let read = try NexusWorkloadRequest(
            kind: .fileRead,
            retrySafety: .idempotent,
            payload: NexusFileReadPayload(file: reference, offset: 0, maximumLength: 1_024)
        )
        await host.execute(read) { await readEvents.append($0) }
        let readResultEvent = await readEvents.first(kind: .result)
        let fileResult = try XCTUnwrap(readResultEvent).decodePayload(NexusFileDataPayload.self)
        XCTAssertEqual(fileResult.data, all)
        XCTAssertTrue(fileResult.endOfFile)

        let indexRequest = try NexusWorkloadRequest(
            kind: .index,
            retrySafety: .idempotent,
            payload: NexusIndexPayload(rootID: "workspace", relativePaths: ["notes"], replaceExisting: true)
        )
        await host.execute(indexRequest) { _ in }
        let searchEvents = NexusEventCollector()
        let searchRequest = try NexusWorkloadRequest(
            kind: .searchIndex,
            retrySafety: .idempotent,
            payload: NexusIndexSearchPayload(query: "remote indexing", limit: 10)
        )
        await host.execute(searchRequest) { await searchEvents.append($0) }
        let searchResultEvent = await searchEvents.first(kind: .result)
        let searchResult = try XCTUnwrap(searchResultEvent).decodePayload(NexusIndexSearchResultsPayload.self)
        XCTAssertEqual(searchResult.results.first?.file, reference)
    }

    func testHostModelPullStreamsProgressAndAcceptsVeryLargeModelIdentifiers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = NexusHostModelStub()
        let host = NexusHostServiceExecutor(
            nodeID: UUID(), policy: Self.hostTestPolicy(root: root), models: models
        )
        let events = NexusEventCollector()
        let request = try NexusWorkloadRequest(
            kind: .modelPull,
            retrySafety: .resumable,
            payload: NexusModelPullPayload(runtime: .ollama, model: "qwen3:235b", quantization: nil)
        )

        await host.execute(request) { await events.append($0) }

        let collected = await events.values()
        XCTAssertTrue(collected.contains(where: { $0.kind == .progress }))
        XCTAssertTrue(collected.contains(where: { $0.kind == .result }))
        let pulledModel = await models.lastPulledModel()
        XCTAssertEqual(pulledModel, "qwen3:235b")
    }

    func testRuntimeProvisioningRequiresConfirmationAndReturnsHostInventory() async throws {
        let models = NexusHostModelStub()
        let host = NexusHostServiceExecutor(nodeID: UUID(), models: models)

        let denied = try NexusWorkloadRequest(
            kind: .runtimeProvision,
            retrySafety: .resumable,
            payload: NexusRuntimeProvisionPayload(preferredRuntime: .ollama, userConfirmed: false)
        )
        let deniedEvents = NexusEventCollector()
        await host.execute(denied) { await deniedEvents.append($0) }
        let deniedFailure = await deniedEvents.first(kind: .failed)
        let deniedInventory = try await models.runtimeInventory()
        XCTAssertNotNil(deniedFailure)
        XCTAssertTrue(deniedInventory.runtimes.isEmpty)

        let confirmed = try NexusWorkloadRequest(
            kind: .runtimeProvision,
            retrySafety: .resumable,
            payload: NexusRuntimeProvisionPayload(preferredRuntime: .ollama, userConfirmed: true)
        )
        let confirmedEvents = NexusEventCollector()
        await host.execute(confirmed) { await confirmedEvents.append($0) }
        let confirmedResult = await confirmedEvents.first(kind: .result)
        let result = try XCTUnwrap(confirmedResult).decodePayload(NexusRuntimeInventoryPayload.self)
        XCTAssertEqual(result.defaultRuntime, .ollama)
        XCTAssertEqual(result.runtimes, [.init(kind: .ollama, isManagedByNexus: true)])
    }

    func testRemoteModelDeleteMutatesOnlyThatHostsInventory() async throws {
        let models = NexusHostModelStub()
        let host = NexusHostServiceExecutor(nodeID: UUID(), models: models)
        let request = try NexusWorkloadRequest(
            kind: .modelDelete,
            retrySafety: .neverReplay,
            payload: NexusModelDeletePayload(runtime: .ollama, model: "large:120b")
        )
        let events = NexusEventCollector()
        await host.execute(request) { await events.append($0) }

        let completed = await events.first(kind: .completed)
        let remaining = try await models.installedModels(runtime: .ollama)
        XCTAssertNotNil(completed)
        XCTAssertFalse(remaining.contains {
            $0.identifier == "large:120b"
        })
    }

    func testHostProcessApprovalIsSingleUseAndShellRemainsDenied() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = NexusExecutionPolicy(
            allowedCapabilities: [.process],
            roots: ["workspace": root],
            executables: [
                "true": .init(executableURL: URL(fileURLWithPath: "/usr/bin/true"), requiresApproval: true),
                "zsh": .init(executableURL: URL(fileURLWithPath: "/bin/zsh"), requiresApproval: false)
            ]
        )
        let host = NexusHostServiceExecutor(nodeID: UUID(), policy: policy, models: NexusHostModelStub())
        let token = await host.issueProcessApproval()
        let approved = NexusProcessPayload(
            executableID: "true", arguments: [], environment: [:], workingDirectory: nil,
            timeoutSeconds: 5, maximumOutputBytes: 1_024, approvalToken: token
        )

        let firstEvents = NexusEventCollector()
        await host.execute(try NexusWorkloadRequest(kind: .process, retrySafety: .neverReplay, payload: approved)) {
            await firstEvents.append($0)
        }
        let completedEvent = await firstEvents.first(kind: .completed)
        XCTAssertNotNil(completedEvent)

        let replayEvents = NexusEventCollector()
        await host.execute(try NexusWorkloadRequest(kind: .process, retrySafety: .neverReplay, payload: approved)) {
            await replayEvents.append($0)
        }
        let replayFailure = await replayEvents.first(kind: .failed)
        XCTAssertNotNil(replayFailure)

        let shell = NexusProcessPayload(
            executableID: "zsh", arguments: ["-c", "whoami"], environment: [:], workingDirectory: nil,
            timeoutSeconds: 5, maximumOutputBytes: 1_024, approvalToken: nil
        )
        let shellEvents = NexusEventCollector()
        await host.execute(try NexusWorkloadRequest(kind: .process, retrySafety: .neverReplay, payload: shell)) {
            await shellEvents.append($0)
        }
        let shellFailure = await shellEvents.first(kind: .failed)
        XCTAssertNotNil(shellFailure)
    }

    private static func hostTestPolicy(root: URL) -> NexusExecutionPolicy {
        NexusExecutionPolicy(
            allowedCapabilities: Set(NexusCapability.allCases),
            roots: ["workspace": root],
            executables: [:]
        )
    }
}

private actor NexusEventCollector {
    private var events: [NexusWorkloadEvent] = []
    func append(_ event: NexusWorkloadEvent) { events.append(event) }
    func values() -> [NexusWorkloadEvent] { events }
    func first(kind: NexusWorkloadEventKind) -> NexusWorkloadEvent? { events.first { $0.kind == kind } }
}

private actor NexusHostModelStub: NexusHostModelServing {
    private var installed = [NexusModelDescriptor(runtime: .ollama, identifier: "large:120b")]
    private var pulledModel: String?
    private var runtimes: Set<NexusRuntimeAvailability> = []

    func installedModels(runtime: NexusRuntimeKind?) async throws -> [NexusModelDescriptor] {
        installed.filter { runtime == nil || $0.runtime == runtime }
    }

    func pull(
        runtime: NexusRuntimeKind,
        model: String,
        quantization: String?,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws {
        pulledModel = model
        await progress(.init(completedBytes: 50, totalBytes: 100, status: "pulling"))
        installed.append(.init(runtime: runtime, identifier: model))
        await progress(.init(completedBytes: 100, totalBytes: 100, status: "success"))
    }

    func streamChat(
        runtime: NexusRuntimeKind,
        model: String,
        messages: [NexusChatMessage],
        temperature: Double?,
        maximumTokens: Int?,
        onDelta: @escaping @Sendable (String, String) async -> Void
    ) async throws -> String {
        await onDelta("Hello ", "Hello ")
        await onDelta("from Studio", "Hello from Studio")
        return "Hello from Studio"
    }

    func runtimeInventory() async throws -> NexusRuntimeInventoryPayload {
        .init(runtimes: runtimes, defaultRuntime: runtimes.first?.kind)
    }

    func provisionDefaultRuntime(
        preferred: NexusRuntimeKind?,
        userConfirmed: Bool
    ) async throws -> NexusRuntimeInventoryPayload {
        guard userConfirmed else {
            throw NexusConnectError.policyDenied("confirmation required")
        }
        runtimes = [.init(kind: preferred ?? .ollama, isManagedByNexus: true)]
        return try await runtimeInventory()
    }

    func delete(runtime: NexusRuntimeKind, model: String) async throws {
        installed.removeAll { $0.runtime == runtime && $0.identifier == model }
    }

    func lastPulledModel() -> String? { pulledModel }
}
