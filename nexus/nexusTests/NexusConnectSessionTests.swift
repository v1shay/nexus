import Foundation
import Network
import XCTest
@testable import nexus

extension NexusGeometryTests {
    func testRemoteModelDownloadIsOwnedByHostAfterClientUIDisconnects() async throws {
        XCTAssertTrue(NexusConnectHostSession.survivesClientDisconnect(.modelPull))
        XCTAssertTrue(NexusConnectHostSession.survivesClientDisconnect(.download))
        XCTAssertFalse(NexusConnectHostSession.survivesClientDisconnect(.inference))

        let registry = NexusHostBackgroundJobRegistry()
        let requestID = UUID()
        let completion = expectation(description: "host-owned download completes")
        try await registry.start(requestID: requestID) {
            try? await Task.sleep(nanoseconds: 30_000_000)
            completion.fulfill()
        }

        // A host session's close path intentionally has no cancellation call
        // for this registry. The work therefore outlives its UI/client stream.
        let isRunning = await registry.contains(requestID: requestID)
        XCTAssertTrue(isRunning)
        await fulfillment(of: [completion], timeout: 1)
        try await Task.sleep(nanoseconds: 10_000_000)
        let isFinished = await registry.contains(requestID: requestID)
        XCTAssertFalse(isFinished)
    }

    func testEncryptedClientHostSessionStreamsConcurrentWorkloadEndToEnd() async throws {
        let secret = try NexusPairingMaterial(secret: Data(repeating: 42, count: 32))
        let store = NexusMemorySecretStore()
        let clientVault = NexusIdentityVault(store: store, role: .client)
        let hostVault = NexusIdentityVault(store: store, role: .studioHost)
        try clientVault.savePairing(secret)
        try hostVault.savePairing(secret)
        let pair = NexusInMemoryTransportPair()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let services = NexusHostServiceExecutor(
            nodeID: UUID(),
            nodeName: "Test Studio",
            policy: NexusExecutionPolicy(
                allowedCapabilities: Set(NexusCapability.allCases), roots: ["workspace": root], executables: [:]
            ),
            models: NexusSessionModelStub()
        )
        let host = NexusConnectHostSession(transport: pair.host, vault: hostVault, executor: services)
        let hostTask = Task { () -> String? in
            do { try await host.run(); return nil }
            catch { return String(describing: error) }
        }
        let client = NexusRemoteClientSession(vault: clientVault, transportFactory: { pair.client })
        let peer = Self.sessionTestPeer()

        let health: NexusNodeHealth
        do {
            health = try await client.connect(to: peer)
        } catch {
            let hostError = await hostTask.value
            XCTFail("client failed: \(error); host result: \(String(describing: hostError))")
            return
        }
        XCTAssertEqual(health.nodeName, "Test Studio")
        let request = try NexusWorkloadRequest(
            kind: .inference,
            priority: .interactive,
            retrySafety: .idempotent,
            payload: NexusInferencePayload(
                runtime: .ollama, model: "studio-model",
                messages: [.init(role: "user", content: "stream")],
                temperature: nil, maximumTokens: nil
            )
        )
        let stream = try await client.events(for: request)
        var tokens = ""
        for try await event in stream {
            if event.kind == .token { tokens += try event.decodePayload(NexusTextDeltaPayload.self).delta }
        }
        XCTAssertEqual(tokens, "remote stream")

        let pinnedClient = try XCTUnwrap(try clientVault.loadPairing())
        let pinnedHost = try XCTUnwrap(try hostVault.loadPairing())
        XCTAssertNotNil(pinnedClient.peerSigningPublicKey)
        XCTAssertNotNil(pinnedHost.peerSigningPublicKey)
        await client.disconnect()
        hostTask.cancel()
    }

    func testSessionRejectsDifferentPairingSecretBeforeAnyWorkloadRuns() async throws {
        let clientStore = NexusMemorySecretStore()
        let hostStore = NexusMemorySecretStore()
        let clientVault = NexusIdentityVault(store: clientStore, role: .client)
        let hostVault = NexusIdentityVault(store: hostStore, role: .studioHost)
        try clientVault.savePairing(try NexusPairingMaterial(secret: Data(repeating: 1, count: 32)))
        try hostVault.savePairing(try NexusPairingMaterial(secret: Data(repeating: 2, count: 32)))
        let pair = NexusInMemoryTransportPair()
        let services = NexusHostServiceExecutor(nodeID: UUID(), models: NexusSessionModelStub())
        let host = NexusConnectHostSession(transport: pair.host, vault: hostVault, executor: services)
        let hostTask = Task { () -> String? in
            do { try await host.run(); return nil }
            catch { return String(describing: error) }
        }
        let client = NexusRemoteClientSession(vault: clientVault, transportFactory: { pair.client })

        do {
            _ = try await client.connect(to: Self.sessionTestPeer())
            XCTFail("connection should reject a different secret")
        } catch {}
        let hostError = await hostTask.value
        XCTAssertTrue(hostError?.contains("authenticationFailed") == true)
    }

    func testAutomaticRouterFallsBackOnlyBeforeSafeIdempotentWorkBegins() async throws {
        let local = NexusExecutorStub(mode: .answer("local"))
        let unavailable = NexusExecutorStub(mode: .failBeforeResult)
        let router = NexusWorkloadRouter(local: local, remote: unavailable, preference: .automatic)
        let inference = try NexusWorkloadRequest(
            kind: .inference,
            retrySafety: .idempotent,
            payload: NexusInferencePayload(
                runtime: .ollama, model: "m", messages: [.init(role: "user", content: "hi")],
                temperature: nil, maximumTokens: nil
            )
        )

        let fallback = try await router.events(for: inference)
        var answer: String?
        for try await event in fallback where event.kind == .result {
            answer = try event.decodePayload(NexusTextDeltaPayload.self).accumulated
        }
        XCTAssertEqual(answer, "local")

        let unsafe = try NexusWorkloadRequest(
            kind: .modelPull,
            retrySafety: .resumable,
            payload: NexusModelPullPayload(runtime: .ollama, model: "huge:235b", quantization: nil)
        )
        let noFallback = try await router.events(for: unsafe)
        do {
            for try await _ in noFallback {}
            XCTFail("unsafe remote failure should surface")
        } catch {}
        let localCalls = await local.callCount()
        XCTAssertEqual(localCalls, 1)
    }

    func testTailnetListenerEndpointFilterAcceptsOnlyTailscaleAddressSpace() {
        XCTAssertTrue(NexusConnectHostListener.isTailnetEndpoint(
            .hostPort(host: "100.72.31.42", port: 49_718)
        ))
        XCTAssertTrue(NexusConnectHostListener.isTailnetEndpoint(
            .hostPort(host: "fd7a:115c:a1e0::1", port: 49_718)
        ))
        XCTAssertFalse(NexusConnectHostListener.isTailnetEndpoint(
            .hostPort(host: "192.168.1.10", port: 49_718)
        ))
        XCTAssertFalse(NexusConnectHostListener.isTailnetEndpoint(
            .hostPort(host: "8.8.8.8", port: 49_718)
        ))
    }

    private static func sessionTestPeer() -> NexusTailscalePeer {
        .init(
            id: "studio", nodeKey: "nodekey:studio", hostName: "Mac Studio",
            dnsName: "studio.ts.net.", operatingSystem: "macOS", addresses: ["100.72.31.42"],
            online: true, active: true, relayRegion: "sfo", currentEndpoint: nil,
            receivedBytes: 0, transmittedBytes: 0
        )
    }
}

private actor NexusMemoryPipe {
    private var buffered: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    func write(_ data: Data) throws {
        guard !closed else { throw NexusConnectError.unavailable("pipe closed") }
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: data)
        } else {
            buffered.append(data)
        }
    }

    func read() async throws -> Data {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if closed { throw NexusConnectError.unavailable("pipe closed") }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func close() {
        closed = true
        let active = waiters
        waiters.removeAll()
        for waiter in active { waiter.resume(throwing: NexusConnectError.unavailable("pipe closed")) }
    }
}

private final class NexusInMemoryTransport: NexusByteTransport, @unchecked Sendable {
    private let incoming: NexusMemoryPipe
    private let outgoing: NexusMemoryPipe

    init(incoming: NexusMemoryPipe, outgoing: NexusMemoryPipe) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    func connect(host: String, port: UInt16) async throws {}
    func send(_ data: Data) async throws { try await outgoing.write(data) }
    func receive() async throws -> Data { try await incoming.read() }
    func cancel() async {
        await incoming.close()
        await outgoing.close()
    }
}

private final class NexusInMemoryTransportPair: @unchecked Sendable {
    let client: NexusInMemoryTransport
    let host: NexusInMemoryTransport

    init() {
        let clientToHost = NexusMemoryPipe()
        let hostToClient = NexusMemoryPipe()
        client = NexusInMemoryTransport(incoming: hostToClient, outgoing: clientToHost)
        host = NexusInMemoryTransport(incoming: clientToHost, outgoing: hostToClient)
    }
}

private actor NexusSessionModelStub: NexusHostModelServing {
    func installedModels(runtime: NexusRuntimeKind?) async throws -> [NexusModelDescriptor] {
        [.init(runtime: .ollama, identifier: "studio-model")]
    }
    func pull(
        runtime: NexusRuntimeKind,
        model: String,
        quantization: String?,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws {}
    func streamChat(
        runtime: NexusRuntimeKind,
        model: String,
        messages: [NexusChatMessage],
        temperature: Double?,
        maximumTokens: Int?,
        onDelta: @escaping @Sendable (String, String) async -> Void
    ) async throws -> String {
        await onDelta("remote ", "remote ")
        await onDelta("stream", "remote stream")
        return "remote stream"
    }
}

private actor NexusExecutorStub: NexusWorkloadExecuting {
    enum Mode { case answer(String), failBeforeResult }
    private let mode: Mode
    private var calls = 0

    init(mode: Mode) { self.mode = mode }

    func events(for request: NexusWorkloadRequest) async throws -> AsyncThrowingStream<NexusWorkloadEvent, Error> {
        calls += 1
        return AsyncThrowingStream { continuation in
            Task {
                switch mode {
                case .answer(let answer):
                    continuation.yield(try! NexusWorkloadEvent(
                        requestID: request.id, kind: .result, sequence: 0, isFinal: false,
                        payload: NexusTextDeltaPayload(delta: answer, accumulated: answer)
                    ))
                    continuation.yield(try! NexusWorkloadEvent(
                        requestID: request.id, kind: .completed, sequence: 1, isFinal: true,
                        payload: NexusEmptyPayload()
                    ))
                    continuation.finish()
                case .failBeforeResult:
                    continuation.finish(throwing: NexusConnectError.unavailable("offline"))
                }
            }
        }
    }
    func cancel(requestID: UUID) async {}
    func callCount() -> Int { calls }
}
