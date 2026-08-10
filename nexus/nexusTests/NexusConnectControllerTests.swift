import CryptoKit
import Foundation
import XCTest
@testable import nexus

extension NexusGeometryTests {
    func testPairedNodeRosterSurvivesRestartAndKeepsSecretsPerDevice() throws {
        let store = NexusMemorySecretStore()
        let firstProcess = NexusPairedNodeStore(secretStore: store)
        let studioID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let imacID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let studioPairing = try NexusPairingMaterial(
            secret: Data(repeating: 1, count: 32),
            peerDeviceID: studioID,
            peerSigningPublicKey: Data(repeating: 11, count: 32)
        )
        let imacPairing = try NexusPairingMaterial(
            secret: Data(repeating: 2, count: 32),
            peerDeviceID: imacID,
            peerSigningPublicKey: Data(repeating: 22, count: 32)
        )
        try firstProcess.upsert(.init(
            id: studioID,
            pinnedPublicIdentityKey: studioPairing.peerSigningPublicKey!,
            displayName: "Mac Studio",
            endpoint: "studio.example.ts.net."
        ), pairing: studioPairing)
        try firstProcess.upsert(.init(
            id: imacID,
            pinnedPublicIdentityKey: imacPairing.peerSigningPublicKey!,
            displayName: "iMac",
            endpoint: "imac.example.ts.net."
        ), pairing: imacPairing)

        let restartedProcess = NexusPairedNodeStore(secretStore: store)
        let restored = try restartedProcess.prepareForLaunch()

        XCTAssertEqual(restored.map(\.id), [imacID, studioID])
        XCTAssertEqual(restored.map(\.status), [.reconnecting, .reconnecting])
        XCTAssertEqual(restored.first(where: { $0.id == studioID })?.endpoint, "studio.example.ts.net")
        XCTAssertEqual(try restartedProcess.pairing(for: studioID)?.secret, studioPairing.secret)
        XCTAssertEqual(try restartedProcess.pairing(for: imacID)?.secret, imacPairing.secret)
        XCTAssertNotEqual(
            try restartedProcess.pairing(for: studioID)?.secret,
            try restartedProcess.pairing(for: imacID)?.secret
        )
    }

    func testForgettingOneNodeRevokesOnlyThatDevice() throws {
        let store = NexusMemorySecretStore()
        let roster = NexusPairedNodeStore(secretStore: store)
        let studioID = UUID()
        let imacID = UUID()
        for (id, byte, name) in [(studioID, UInt8(1), "Studio"), (imacID, UInt8(2), "iMac")] {
            let pairing = try NexusPairingMaterial(
                secret: Data(repeating: byte, count: 32),
                peerDeviceID: id,
                peerSigningPublicKey: Data(repeating: byte + 10, count: 32)
            )
            try roster.upsert(.init(
                id: id,
                pinnedPublicIdentityKey: pairing.peerSigningPublicKey!,
                displayName: name,
                endpoint: "\(name.lowercased()).ts.net"
            ), pairing: pairing)
        }

        try roster.forget(nodeID: studioID)

        XCTAssertNil(try roster.pairing(for: studioID))
        XCTAssertNotNil(try roster.pairing(for: imacID))
        XCTAssertEqual(try roster.load().map(\.id), [imacID])
    }

    func testHostTrustPersistsMultipleClientsAndRevokesOnlyOne() throws {
        let secrets = NexusMemorySecretStore()
        let trust = NexusHostTrustStore(secretStore: secrets)
        let studioInvitation = try NexusPairingMaterial.fresh(pairingID: UUID())
        let imacInvitation = try NexusPairingMaterial.fresh(pairingID: UUID())
        try trust.registerInvitation(pairing: studioInvitation, displayName: "MacBook Air")
        try trust.registerInvitation(pairing: imacInvitation, displayName: "Backup MacBook")
        let firstClientID = UUID()
        let secondClientID = UUID()
        let firstKey = Data(repeating: 41, count: 32)
        let secondKey = Data(repeating: 42, count: 32)
        _ = try trust.authorize(
            pairingID: studioInvitation.pairingID!,
            clientDeviceID: firstClientID,
            signingPublicKey: firstKey
        )
        _ = try trust.authorize(
            pairingID: imacInvitation.pairingID!,
            clientDeviceID: secondClientID,
            signingPublicKey: secondKey
        )

        let restarted = NexusHostTrustStore(secretStore: secrets)
        XCTAssertEqual(try restarted.load().filter { $0.status == .authorized }.count, 2)
        XCTAssertEqual(
            try restarted.pairing(for: studioInvitation.pairingID!)?.peerDeviceID,
            firstClientID
        )
        XCTAssertEqual(
            try restarted.pairing(for: imacInvitation.pairingID!)?.peerDeviceID,
            secondClientID
        )

        try restarted.revoke(pairingID: studioInvitation.pairingID!)
        XCTAssertNil(try restarted.pairing(for: studioInvitation.pairingID!))
        XCTAssertNotNil(try restarted.pairing(for: imacInvitation.pairingID!))
        XCTAssertThrowsError(try restarted.authorize(
            pairingID: studioInvitation.pairingID!,
            clientDeviceID: firstClientID,
            signingPublicKey: firstKey
        ))
    }

    func testPairingSelectorIsAuthenticatedAndLegacyV2HelloStillVerifies() throws {
        let identity = NexusDeviceIdentity(
            deviceID: UUID(),
            signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation
        )
        let selected = try NexusPairingMaterial.fresh(pairingID: UUID())
        let selectedHello = try NexusHandshake.makeHello(
            identity: identity,
            role: .client,
            pairing: selected
        ).hello
        XCTAssertEqual(selectedHello.pairingID, selected.pairingID)
        XCTAssertNoThrow(try NexusHandshake.verify(
            selectedHello,
            pairing: selected,
            expectedRole: .client
        ))

        let earlyV2 = try NexusPairingMaterial.fresh()
        let earlyV2Hello = try NexusHandshake.makeHello(
            identity: identity,
            role: .client,
            pairing: earlyV2
        ).hello
        XCTAssertNil(earlyV2Hello.pairingID)
        XCTAssertNoThrow(try NexusHandshake.verify(
            earlyV2Hello,
            pairing: earlyV2,
            expectedRole: .client
        ))
    }

    func testProtocolNegotiationAllowsCompatibleAppVersionsAndLimitsFeatures() throws {
        let compatible = try NexusProtocolNegotiator.negotiate(
            localRange: .init(minimum: 1, maximum: 2),
            localFeatures: [.streamingInference, .perNodeInventory, .backgroundHost],
            remoteRange: .init(minimum: 1, maximum: 1),
            remoteFeatures: [.streamingInference, .perNodeInventory]
        )

        XCTAssertEqual(compatible.version, 1)
        XCTAssertEqual(compatible.features, [.streamingInference])
        XCTAssertThrowsError(try NexusProtocolNegotiator.negotiate(
            localRange: .init(minimum: 2, maximum: 2),
            remoteRange: .init(minimum: 1, maximum: 1),
            remoteFeatures: []
        )) { error in
            XCTAssertEqual(error as? NexusConnectError, .unsupportedProtocol)
        }
    }

    func testModelInventoryAndRoutingRemainCorrectPerNode() async throws {
        let studioID = UUID()
        let imacID = UUID()
        let studioModel = NexusModelDescriptor(runtime: .ollama, identifier: "studio-only:70b")
        let imacModel = NexusModelDescriptor(runtime: .ollama, identifier: "imac-only:32b")
        let studio = NexusPairedNode(
            id: studioID,
            pinnedPublicIdentityKey: Data(repeating: 1, count: 32),
            displayName: "Studio",
            endpoint: "studio.ts.net",
            modelInventory: [studioModel],
            status: .online,
            availableMemoryBytes: 96 * 1_073_741_824,
            availableDiskBytes: 1_000 * 1_073_741_824
        )
        let imac = NexusPairedNode(
            id: imacID,
            pinnedPublicIdentityKey: Data(repeating: 2, count: 32),
            displayName: "iMac",
            endpoint: "imac.ts.net",
            modelInventory: [imacModel],
            status: .online,
            availableMemoryBytes: 48 * 1_073_741_824,
            availableDiskBytes: 500 * 1_073_741_824
        )
        let local = NexusRoutingExecutorStub(answer: "local")
        let studioExecutor = NexusRoutingExecutorStub(answer: "studio")
        let imacExecutor = NexusRoutingExecutorStub(answer: "imac")
        let router = NexusMultiNodeWorkloadRouter(local: local)
        await router.synchronize(
            nodes: [studio, imac],
            executors: [studioID: studioExecutor, imacID: imacExecutor]
        )

        let studioOwner = await router.automaticNode(for: studioModel, minimumRAMGB: 64)
        let imacOwner = await router.automaticNode(for: imacModel, minimumRAMGB: 24)
        let newModelOwner = await router.automaticNode(
            for: .init(runtime: .ollama, identifier: "new:40b"),
            minimumRAMGB: 40
        )
        XCTAssertEqual(studioOwner, studioID)
        XCTAssertEqual(imacOwner, imacID)
        XCTAssertEqual(
            newModelOwner,
            studioID,
            "a new model should choose the capable node with the most free resources"
        )

        await router.setRoute(.pairedNode(imacID))
        let request = try NexusWorkloadRequest(
            kind: .inference,
            retrySafety: .idempotent,
            payload: NexusInferencePayload(
                runtime: .ollama,
                model: imacModel.identifier,
                messages: [.init(role: "user", content: "route")],
                temperature: nil,
                maximumTokens: nil
            )
        )
        let stream = try await router.events(for: request)
        var routedAnswer: String?
        for try await event in stream where event.kind == .result {
            routedAnswer = try event.decodePayload(NexusTextDeltaPayload.self).accumulated
        }
        XCTAssertEqual(routedAnswer, "imac")
        let studioCalls = await studioExecutor.callCount()
        let imacCalls = await imacExecutor.callCount()
        XCTAssertEqual(studioCalls, 0)
        XCTAssertEqual(imacCalls, 1)
    }

    @MainActor
    func testNX2PairingSurvivesControllerRestartWithoutAnotherCode() async throws {
        let defaultsName = "NexusConnectNX2Restart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = NexusMemorySecretStore()
        let hostIdentity = NexusDeviceIdentity(
            deviceID: UUID(),
            signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation
        )
        let generated = try NexusPairingCode.generateInvitation(
            identity: hostIdentity,
            displayName: "Vishay's iMac",
            endpoint: "vishays-imac.example.ts.net"
        )

        var firstController: NexusConnectController? = NexusConnectController(
            defaults: defaults,
            secretStore: store
        )
        firstController?.setRole(.client)
        firstController?.pairingCode = generated.code
        firstController?.applyPairingCode()
        XCTAssertEqual(firstController?.pairedNodes.map(\.id), [hostIdentity.deviceID])
        firstController?.shutdown()
        firstController = nil

        let restarted = NexusConnectController(defaults: defaults, secretStore: store)
        let restoreDeadline = Date().addingTimeInterval(1)
        while !restarted.isPaired && Date() < restoreDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(restarted.isPaired)
        XCTAssertEqual(restarted.pairedNodes.first?.displayName, "Vishay's iMac")
        XCTAssertEqual(restarted.pairedNodes.first?.status, .reconnecting)
        restarted.shutdown()
    }

    func testLaunchAgentConfigurationRunsAHeadlessPersistentHost() throws {
        let manager = NexusConnectHostManager(
            homeDirectory: URL(fileURLWithPath: "/tmp/nexus-host-test-home"),
            executableURL: URL(fileURLWithPath: "/Applications/Nexus.app/Contents/MacOS/nexus"),
            processRunner: { _, _ in }
        )
        let decoded = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: manager.launchAgentPropertyList(),
                options: [],
                format: nil
            ) as? [String: Any]
        )

        XCTAssertEqual(decoded["Label"] as? String, NexusConnectHostManager.label)
        XCTAssertEqual(decoded["KeepAlive"] as? Bool, true)
        XCTAssertEqual(decoded["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(
            decoded["ProgramArguments"] as? [String],
            ["/Applications/Nexus.app/Contents/MacOS/nexus", NexusConnectHostProcess.argument]
        )
    }

    @MainActor
    func testClosingHostUIDoesNotStopPersistentConnectHost() async throws {
        let suiteName = "NexusPersistentHostLifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = NexusPersistentHostManagerSpy()
        let controller = NexusConnectController(
            defaults: defaults,
            secretStore: NexusMemorySecretStore(),
            discovery: NexusRunningDiscoveryStub(),
            persistentHost: manager
        )
        controller.setRole(.studioHost)
        await controller.createPairingCode()
        controller.setEnabled(true)

        XCTAssertEqual(manager.installCount, 1)
        controller.shutdown()
        XCTAssertEqual(manager.installCount, 1, "UI shutdown must not own or terminate the host process")
    }

    func testPairingCodeRoundTripsAndDetectsDamage() throws {
        let generated = try NexusPairingCode.generate()
        let decoded = try NexusPairingCode.decode(generated.code)
        XCTAssertEqual(decoded.secret, generated.material.secret)
        XCTAssertNil(decoded.peerDeviceID)

        var damaged = generated.code
        let final = damaged.removeLast()
        damaged.append(final == "a" ? "b" : "a")
        XCTAssertThrowsError(try NexusPairingCode.decode(damaged)) {
            XCTAssertEqual($0 as? NexusConnectError, .authenticationFailed)
        }
    }

    @MainActor
    func testOnePairingCodeConfiguresClientAndHostWithoutStartingWhenDisabled() async throws {
        let suiteName = "NexusConnectControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = NexusMemorySecretStore()
        let host = NexusConnectController(
            defaults: defaults,
            secretStore: store,
            discovery: NexusRunningDiscoveryStub()
        )
        host.setRole(.studioHost)
        await host.createPairingCode()
        let code = host.pairingCode
        let invitation = try NexusPairingCode.decodeInvitation(code)
        XCTAssertEqual(invitation.endpoint, "test-studio.example.ts.net.")
        XCTAssertEqual(invitation.tailscaleNodeID, "host-tailnet-id")
        XCTAssertTrue(host.isPaired)
        XCTAssertEqual(host.state, .off)

        let clientDefaultsName = "\(suiteName).client"
        let clientDefaults = try XCTUnwrap(UserDefaults(suiteName: clientDefaultsName))
        defer { clientDefaults.removePersistentDomain(forName: clientDefaultsName) }
        let client = NexusConnectController(defaults: clientDefaults, secretStore: store)
        client.setRole(.client)
        client.pairingCode = code
        client.applyPairingCode()

        XCTAssertTrue(client.isPaired)
        XCTAssertEqual(client.pairedNodes.first?.endpoint, "test-studio.example.ts.net")
        XCTAssertEqual(client.pairedNodes.first?.tailscaleNodeID, "host-tailnet-id")
        XCTAssertFalse(client.enabled)
        XCTAssertEqual(client.state, .off)
        client.shutdown()
        host.shutdown()
    }
}

private final class NexusPersistentHostManagerSpy: NexusPersistentHostManaging, @unchecked Sendable {
    private(set) var installCount = 0

    func installAndStart() throws { installCount += 1 }

    func currentStatus() -> NexusConnectHostStatus? {
        .init(
            processID: ProcessInfo.processInfo.processIdentifier,
            nodeID: UUID(),
            state: "ready",
            detail: nil,
            appVersion: "test",
            protocolRange: .local,
            updatedAt: Date()
        )
    }
}

private struct NexusRunningDiscoveryStub: NexusNodeDiscovering {
    func snapshot() async throws -> NexusTailscaleSnapshot {
        .init(
            backendState: "Running",
            localNodeID: "host-tailnet-id",
            localNodeName: "Test Studio",
            localDNSName: "test-studio.example.ts.net.",
            localAddresses: ["100.72.31.42"],
            peers: []
        )
    }

    func routeSample(to peer: NexusTailscalePeer) async throws -> NexusTailscaleRouteSample {
        .init(route: .direct, roundTripMilliseconds: 1, description: "test")
    }
}

private actor NexusRoutingExecutorStub: NexusWorkloadExecuting {
    private let answer: String
    private var calls = 0

    init(answer: String) { self.answer = answer }

    func events(for request: NexusWorkloadRequest) async throws -> AsyncThrowingStream<NexusWorkloadEvent, Error> {
        calls += 1
        let answer = answer
        return AsyncThrowingStream { continuation in
            if let result = try? NexusWorkloadEvent(
                requestID: request.id,
                kind: .result,
                sequence: 0,
                isFinal: true,
                payload: NexusTextDeltaPayload(delta: answer, accumulated: answer)
            ) {
                continuation.yield(result)
            }
            continuation.finish()
        }
    }

    func cancel(requestID: UUID) async {}
    func callCount() -> Int { calls }
}
