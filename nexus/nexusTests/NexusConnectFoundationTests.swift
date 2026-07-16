import CryptoKit
import XCTest
@testable import nexus

extension NexusGeometryTests {
    func testWorkloadPayloadRoundTripKeepsTypedInferenceData() throws {
        let payload = NexusInferencePayload(
            runtime: .ollama,
            model: "qwen3:30b",
            messages: [.init(role: "user", content: "Hello Studio")],
            temperature: 0.2,
            maximumTokens: 1_024
        )
        let request = try NexusWorkloadRequest(
            kind: .inference,
            priority: .interactive,
            retrySafety: .neverReplay,
            payload: payload
        )

        XCTAssertEqual(request.kind.capability, .inference)
        XCTAssertEqual(try request.decodePayload(NexusInferencePayload.self), payload)
    }

    func testFrameDecoderHandlesFragmentationAndCoalescing() throws {
        let first = try NexusFrameCodec.frame(Data("first".utf8))
        let second = try NexusFrameCodec.frame(Data("second".utf8))
        let stream = first + second
        var decoder = NexusFrameDecoder(maximumBytes: 64)

        XCTAssertEqual(try decoder.append(stream.prefix(3)), [])
        XCTAssertEqual(try decoder.append(stream.dropFirst(3).prefix(5)), [])
        XCTAssertEqual(try decoder.append(stream.dropFirst(8)), [Data("first".utf8), Data("second".utf8)])
        XCTAssertEqual(decoder.bufferedBytes, 0)
    }

    func testFrameDecoderRejectsOversizedLengthBeforeAllocatingPayload() throws {
        var length = UInt32(10_000).bigEndian
        let header = Data(bytes: &length, count: 4)
        var decoder = NexusFrameDecoder(maximumBytes: 128)

        XCTAssertThrowsError(try decoder.append(header)) { error in
            XCTAssertEqual(error as? NexusConnectError, .frameTooLarge(10_000))
        }
    }

    func testAuthenticatedHandshakePinsIdentityAndDerivesSameSessionKey() throws {
        let pairing = try NexusPairingMaterial(secret: Data(repeating: 7, count: 32))
        let clientIdentity = NexusDeviceIdentity(
            deviceID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation
        )
        let hostIdentity = NexusDeviceIdentity(
            deviceID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation
        )
        let now: Int64 = 1_700_000_000_000
        let client = try NexusHandshake.makeHello(
            identity: clientIdentity,
            role: .client,
            pairing: pairing,
            timestampMilliseconds: now,
            nonce: Data(repeating: 1, count: 32)
        )
        let host = try NexusHandshake.makeHello(
            identity: hostIdentity,
            role: .studioHost,
            pairing: pairing,
            respondingToNonce: client.hello.nonce,
            timestampMilliseconds: now,
            nonce: Data(repeating: 2, count: 32)
        )

        try NexusHandshake.verify(client.hello, pairing: pairing, expectedRole: .client, nowMilliseconds: now)
        try NexusHandshake.verify(
            host.hello,
            pairing: pairing,
            expectedRole: .studioHost,
            respondingToNonce: client.hello.nonce,
            nowMilliseconds: now
        )
        let pinned = try pairing.pinning(
            peerDeviceID: hostIdentity.deviceID,
            peerSigningPublicKey: hostIdentity.signingPublicKey
        )
        try NexusHandshake.verify(
            host.hello,
            pairing: pinned,
            expectedRole: .studioHost,
            respondingToNonce: client.hello.nonce,
            nowMilliseconds: now
        )

        let sessionID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let clientKey = try NexusHandshake.deriveSessionKey(
            local: client,
            remote: host.hello,
            pairing: pairing,
            clientNonce: client.hello.nonce,
            hostNonce: host.hello.nonce,
            sessionID: sessionID
        )
        let hostKey = try NexusHandshake.deriveSessionKey(
            local: host,
            remote: client.hello,
            pairing: pairing,
            clientNonce: client.hello.nonce,
            hostNonce: host.hello.nonce,
            sessionID: sessionID
        )
        XCTAssertEqual(Data(clientKey), Data(hostKey))
    }

    func testHandshakeRejectsWrongSecretExpiredHelloAndChangedIdentity() throws {
        let correct = try NexusPairingMaterial(secret: Data(repeating: 3, count: 32))
        let wrong = try NexusPairingMaterial(secret: Data(repeating: 4, count: 32))
        let identity = NexusDeviceIdentity(
            deviceID: UUID(),
            signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation
        )
        let hello = try NexusHandshake.makeHello(
            identity: identity,
            role: .studioHost,
            pairing: correct,
            timestampMilliseconds: 1_000_000,
            nonce: Data(repeating: 9, count: 32)
        ).hello

        XCTAssertThrowsError(
            try NexusHandshake.verify(hello, pairing: wrong, expectedRole: .studioHost, nowMilliseconds: 1_000_000)
        ) { XCTAssertEqual($0 as? NexusConnectError, .authenticationFailed) }
        XCTAssertThrowsError(
            try NexusHandshake.verify(hello, pairing: correct, expectedRole: .studioHost, nowMilliseconds: 2_000_000)
        ) { XCTAssertEqual($0 as? NexusConnectError, .handshakeExpired) }

        let changed = try correct.pinning(peerDeviceID: UUID(), peerSigningPublicKey: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(
            try NexusHandshake.verify(hello, pairing: changed, expectedRole: .studioHost, nowMilliseconds: 1_000_000)
        ) { XCTAssertEqual($0 as? NexusConnectError, .identityMismatch) }
    }

    func testSecureChannelEncryptsMessagesAndRejectsReplayOrTampering() throws {
        let sessionID = UUID()
        let key = SymmetricKey(size: .bits256)
        var client = NexusSecureChannel(
            sessionID: sessionID,
            key: key,
            outgoingDirection: .clientToHost,
            incomingDirection: .hostToClient
        )
        var host = NexusSecureChannel(
            sessionID: sessionID,
            key: key,
            outgoingDirection: .hostToClient,
            incomingDirection: .clientToHost
        )
        let message = try NexusConnectMessage(
            sessionID: sessionID,
            kind: .ping,
            payload: "ping"
        )
        let framed = try client.seal(message)
        let packet = framed.dropFirst(4)

        XCTAssertEqual(try host.open(Data(packet)), message)
        XCTAssertThrowsError(try host.open(Data(packet))) { error in
            XCTAssertEqual(error as? NexusConnectError, .replayDetected)
        }

        var secondHost = NexusSecureChannel(
            sessionID: sessionID,
            key: key,
            outgoingDirection: .hostToClient,
            incomingDirection: .clientToHost
        )
        var tampered = Data(packet)
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(try secondHost.open(tampered)) { error in
            XCTAssertEqual(error as? NexusConnectError, .authenticationFailed)
        }
    }

    func testIdentityVaultPersistsIdentityAndPairingWithoutUserDefaults() throws {
        let store = NexusMemorySecretStore()
        let vault = NexusIdentityVault(store: store, role: .client)
        let firstIdentity = try vault.loadOrCreateIdentity()
        let secondIdentity = try vault.loadOrCreateIdentity()
        XCTAssertEqual(firstIdentity, secondIdentity)

        let pairing = try NexusPairingMaterial(secret: Data(repeating: 5, count: 32))
        try vault.savePairing(pairing)
        XCTAssertEqual(try vault.loadPairing(), pairing)
        try vault.removePairing()
        XCTAssertNil(try vault.loadPairing())
    }

    func testPolicyBlocksTraversalShellsUnapprovedProcessesAndEnvironmentInjection() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let policy = NexusExecutionPolicy(
            allowedCapabilities: [.process, .fileRead],
            roots: ["workspace": temporaryRoot],
            executables: [
                "git": NexusExecutableRule(
                    executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                    allowedEnvironmentKeys: ["LANG"],
                    requiresApproval: true
                ),
                "zsh": NexusExecutableRule(
                    executableURL: URL(fileURLWithPath: "/bin/zsh"),
                    requiresApproval: false
                )
            ]
        )

        XCTAssertThrowsError(try policy.resolve(.init(rootID: "workspace", relativePath: "../secret"))) {
            XCTAssertEqual($0 as? NexusConnectError, .pathOutsideAllowedRoots)
        }
        let escape = temporaryRoot.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: escape,
            withDestinationURL: FileManager.default.temporaryDirectory.deletingLastPathComponent()
        )
        XCTAssertThrowsError(try policy.resolve(.init(rootID: "workspace", relativePath: "escape/private"))) {
            XCTAssertEqual($0 as? NexusConnectError, .pathOutsideAllowedRoots)
        }
        let base = NexusProcessPayload(
            executableID: "git",
            arguments: ["status"],
            environment: ["LANG": "en_US.UTF-8"],
            workingDirectory: .init(rootID: "workspace", relativePath: ""),
            timeoutSeconds: 30,
            maximumOutputBytes: 1_024,
            approvalToken: nil
        )
        XCTAssertThrowsError(try policy.validateProcess(base, approvalTokenIsValid: false)) {
            XCTAssertEqual($0 as? NexusConnectError, .policyDenied("interactive approval is required"))
        }
        XCTAssertNoThrow(try policy.validateProcess(base, approvalTokenIsValid: true))

        let environmentInjection = NexusProcessPayload(
            executableID: "git",
            arguments: ["status"],
            environment: ["DYLD_INSERT_LIBRARIES": "/tmp/evil"],
            workingDirectory: nil,
            timeoutSeconds: 30,
            maximumOutputBytes: 1_024,
            approvalToken: "approved"
        )
        XCTAssertThrowsError(try policy.validateProcess(environmentInjection, approvalTokenIsValid: true))

        let shell = NexusProcessPayload(
            executableID: "zsh",
            arguments: ["-c", "rm -rf /"],
            environment: [:],
            workingDirectory: nil,
            timeoutSeconds: 30,
            maximumOutputBytes: 1_024,
            approvalToken: nil
        )
        XCTAssertThrowsError(try policy.validateProcess(shell, approvalTokenIsValid: true)) {
            XCTAssertEqual($0 as? NexusConnectError, .policyDenied("shell interpreters are not available"))
        }
    }
}

private extension Data {
    init(_ key: SymmetricKey) {
        self = key.withUnsafeBytes { Data($0) }
    }
}
