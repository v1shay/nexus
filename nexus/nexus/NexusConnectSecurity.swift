import CryptoKit
import Foundation
import Security

protocol NexusSecretStore: Sendable {
    func data(for account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func delete(account: String) throws
}

final class NexusKeychainSecretStore: NexusSecretStore, @unchecked Sendable {
    private let service: String

    init(service: String = "na.nexus.connect") {
        self.service = service
    }

    func data(for account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NexusConnectError.unavailable("Keychain read failed (\(status))")
        }
        return data
    }

    func set(_ data: Data, for account: String) throws {
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw NexusConnectError.unavailable("Keychain update failed (\(updateStatus))")
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NexusConnectError.unavailable("Keychain write failed (\(addStatus))")
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NexusConnectError.unavailable("Keychain delete failed (\(status))")
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class NexusMemorySecretStore: NexusSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for account: String) throws -> Data? {
        lock.withLock { values[account] }
    }

    func set(_ data: Data, for account: String) throws {
        lock.withLock { values[account] = data }
    }

    func delete(account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}

struct NexusDeviceIdentity: Codable, Equatable, Sendable {
    let deviceID: UUID
    let signingPrivateKey: Data

    var signingPublicKey: Data {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey).publicKey.rawRepresentation) ?? Data()
    }
}

struct NexusPairingMaterial: Codable, Equatable, Sendable {
    let secret: Data
    let peerDeviceID: UUID?
    let peerSigningPublicKey: Data?

    init(secret: Data, peerDeviceID: UUID? = nil, peerSigningPublicKey: Data? = nil) throws {
        guard secret.count == 32 else { throw NexusConnectError.authenticationFailed }
        self.secret = secret
        self.peerDeviceID = peerDeviceID
        self.peerSigningPublicKey = peerSigningPublicKey
    }

    static func fresh() throws -> NexusPairingMaterial {
        try NexusPairingMaterial(secret: Data(SymmetricKey(size: .bits256)))
    }

    func pinning(peerDeviceID: UUID, peerSigningPublicKey: Data) throws -> NexusPairingMaterial {
        if let pinnedID = self.peerDeviceID, pinnedID != peerDeviceID {
            throw NexusConnectError.identityMismatch
        }
        if let pinnedKey = self.peerSigningPublicKey, pinnedKey != peerSigningPublicKey {
            throw NexusConnectError.identityMismatch
        }
        return try NexusPairingMaterial(
            secret: secret,
            peerDeviceID: peerDeviceID,
            peerSigningPublicKey: peerSigningPublicKey
        )
    }
}

struct NexusIdentityVault: Sendable {
    private let store: NexusSecretStore
    private let identityAccount: String
    private let pairingAccount: String

    init(
        store: NexusSecretStore = NexusKeychainSecretStore(),
        role: NexusNodeRole
    ) {
        self.store = store
        identityAccount = "\(role.rawValue).identity.v1"
        pairingAccount = "\(role.rawValue).pairing.v1"
    }

    func loadOrCreateIdentity() throws -> NexusDeviceIdentity {
        if let data = try store.data(for: identityAccount) {
            return try NexusPayloadCoder.decoder.decode(NexusDeviceIdentity.self, from: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        let identity = NexusDeviceIdentity(deviceID: UUID(), signingPrivateKey: key.rawRepresentation)
        try store.set(try NexusPayloadCoder.encoder.encode(identity), for: identityAccount)
        return identity
    }

    func loadPairing() throws -> NexusPairingMaterial? {
        guard let data = try store.data(for: pairingAccount) else { return nil }
        return try NexusPayloadCoder.decoder.decode(NexusPairingMaterial.self, from: data)
    }

    func savePairing(_ pairing: NexusPairingMaterial) throws {
        try store.set(try NexusPayloadCoder.encoder.encode(pairing), for: pairingAccount)
    }

    func removePairing() throws {
        try store.delete(account: pairingAccount)
    }
}

struct NexusHandshakeHello: Codable, Equatable, Sendable {
    let protocolMinimum: Int
    let protocolMaximum: Int
    let deviceID: UUID
    let role: NexusNodeRole
    let signingPublicKey: Data
    let ephemeralPublicKey: Data
    let nonce: Data
    let respondingToNonce: Data?
    let timestampMilliseconds: Int64
    let signature: Data
    let authenticationCode: Data
}

struct NexusPendingHandshake: @unchecked Sendable {
    let hello: NexusHandshakeHello
    fileprivate let ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey
}

enum NexusHandshake {
    static let maximumClockSkewMilliseconds: Int64 = 120_000

    static func makeHello(
        identity: NexusDeviceIdentity,
        role: NexusNodeRole,
        pairing: NexusPairingMaterial,
        respondingToNonce: Data? = nil,
        timestampMilliseconds: Int64 = NexusClock.nowMilliseconds(),
        nonce: Data? = nil
    ) throws -> NexusPendingHandshake {
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.signingPrivateKey)
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let unsigned = NexusUnsignedHello(
            protocolMinimum: NexusConnectProtocol.minimumVersion,
            protocolMaximum: NexusConnectProtocol.currentVersion,
            deviceID: identity.deviceID,
            role: role,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            ephemeralPublicKey: ephemeralKey.publicKey.rawRepresentation,
            nonce: nonce ?? randomBytes(count: 32),
            respondingToNonce: respondingToNonce,
            timestampMilliseconds: timestampMilliseconds
        )
        let unsignedData = try canonicalData(unsigned)
        let signature = try signingKey.signature(for: unsignedData)
        let authenticationCode = Data(
            HMAC<SHA256>.authenticationCode(
                for: unsignedData + signature,
                using: SymmetricKey(data: pairing.secret)
            )
        )
        return NexusPendingHandshake(
            hello: NexusHandshakeHello(
                protocolMinimum: unsigned.protocolMinimum,
                protocolMaximum: unsigned.protocolMaximum,
                deviceID: unsigned.deviceID,
                role: unsigned.role,
                signingPublicKey: unsigned.signingPublicKey,
                ephemeralPublicKey: unsigned.ephemeralPublicKey,
                nonce: unsigned.nonce,
                respondingToNonce: unsigned.respondingToNonce,
                timestampMilliseconds: unsigned.timestampMilliseconds,
                signature: signature,
                authenticationCode: authenticationCode
            ),
            ephemeralPrivateKey: ephemeralKey
        )
    }

    static func verify(
        _ hello: NexusHandshakeHello,
        pairing: NexusPairingMaterial,
        expectedRole: NexusNodeRole,
        respondingToNonce: Data? = nil,
        nowMilliseconds: Int64 = NexusClock.nowMilliseconds()
    ) throws {
        guard hello.role == expectedRole,
              hello.protocolMaximum >= NexusConnectProtocol.minimumVersion,
              hello.protocolMinimum <= NexusConnectProtocol.currentVersion else {
            throw NexusConnectError.unsupportedProtocol
        }
        guard abs(nowMilliseconds - hello.timestampMilliseconds) <= maximumClockSkewMilliseconds else {
            throw NexusConnectError.handshakeExpired
        }
        guard hello.nonce.count == 32,
              hello.ephemeralPublicKey.count == 32,
              hello.signingPublicKey.count == 32,
              hello.respondingToNonce == respondingToNonce else {
            throw NexusConnectError.authenticationFailed
        }
        if let peerID = pairing.peerDeviceID, peerID != hello.deviceID {
            throw NexusConnectError.identityMismatch
        }
        if let peerKey = pairing.peerSigningPublicKey, peerKey != hello.signingPublicKey {
            throw NexusConnectError.identityMismatch
        }
        let unsignedData = try canonicalData(hello.unsigned)
        let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: hello.signingPublicKey)
        guard signingKey.isValidSignature(hello.signature, for: unsignedData) else {
            throw NexusConnectError.authenticationFailed
        }
        let isValidCode = HMAC<SHA256>.isValidAuthenticationCode(
            hello.authenticationCode,
            authenticating: unsignedData + hello.signature,
            using: SymmetricKey(data: pairing.secret)
        )
        guard isValidCode else { throw NexusConnectError.authenticationFailed }
    }

    static func deriveSessionKey(
        local: NexusPendingHandshake,
        remote: NexusHandshakeHello,
        pairing: NexusPairingMaterial,
        clientNonce: Data,
        hostNonce: Data,
        sessionID: UUID
    ) throws -> SymmetricKey {
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote.ephemeralPublicKey)
        let sharedSecret = try local.ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let context = clientNonce + hostNonce + Data(sessionID.uuidString.lowercased().utf8)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: pairing.secret,
            sharedInfo: context,
            outputByteCount: 32
        )
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        try NexusPayloadCoder.encoder.encode(value)
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed")
        return Data(bytes)
    }
}

private struct NexusUnsignedHello: Codable {
    let protocolMinimum: Int
    let protocolMaximum: Int
    let deviceID: UUID
    let role: NexusNodeRole
    let signingPublicKey: Data
    let ephemeralPublicKey: Data
    let nonce: Data
    let respondingToNonce: Data?
    let timestampMilliseconds: Int64
}

private extension NexusHandshakeHello {
    var unsigned: NexusUnsignedHello {
        NexusUnsignedHello(
            protocolMinimum: protocolMinimum,
            protocolMaximum: protocolMaximum,
            deviceID: deviceID,
            role: role,
            signingPublicKey: signingPublicKey,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce,
            respondingToNonce: respondingToNonce,
            timestampMilliseconds: timestampMilliseconds
        )
    }
}

private extension Data {
    init(_ key: SymmetricKey) {
        self = key.withUnsafeBytes { Data($0) }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
