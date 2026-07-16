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
    func testOnePairingCodeConfiguresClientAndHostWithoutStartingWhenDisabled() throws {
        let suiteName = "NexusConnectControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = NexusMemorySecretStore()
        let host = NexusConnectController(defaults: defaults, secretStore: store)
        host.setRole(.studioHost)
        host.createPairingCode()
        let code = host.pairingCode
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
        XCTAssertFalse(client.enabled)
        XCTAssertEqual(client.state, .off)
        client.shutdown()
        host.shutdown()
    }
}
