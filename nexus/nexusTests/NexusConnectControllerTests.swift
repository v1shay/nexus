import Foundation
import XCTest
@testable import nexus

extension NexusGeometryTests {
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
