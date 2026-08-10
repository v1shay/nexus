import CryptoKit
import Foundation
import Security

protocol NexusSecretStore: Sendable {
    func data(for account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func delete(account: String) throws
}

/// Keeps automated UI/CLI verification hermetic.  It is intentionally a
/// *process-local* secret store: test launches must never read, write, or
/// trigger an ACL prompt for the user's login Keychain.  This is not a
/// production credential cache and it is never enabled in a normal launch.
enum NexusSecretStoreRuntime {
    static var usesEphemeralStore: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--nexus-ui-testing")
            || arguments.contains("--nexus-ui-smoke")
            || arguments.contains("--nexus-automation")
            || ProcessInfo.processInfo.environment["NEXUS_AUTOMATION"] == "1"
    }

    /// Deterministic answers belong only in the UI test profile. Command-line
    /// automation still executes real implementation paths.
    static var usesSyntheticResponse: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--nexus-ui-testing")
            || arguments.contains("--nexus-ui-smoke")
            || arguments.contains("--nexus-automation-ui")
    }
}

final class NexusKeychainSecretStore: NexusSecretStore, @unchecked Sendable {
    private let service: String
    private let ephemeralStore: NexusMemorySecretStore?
    private let allowsAuthenticationUI: Bool
    private let vault: NexusUnifiedKeychainVault

    init(
        service: String = "na.nexus.connect",
        useEphemeralStore: Bool = NexusSecretStoreRuntime.usesEphemeralStore,
        allowsAuthenticationUI: Bool = true
    ) {
        self.service = service
        self.vault = .shared
        self.ephemeralStore = useEphemeralStore
            ? NexusMemorySecretStore()
            : nil
        self.allowsAuthenticationUI = allowsAuthenticationUI
    }

    func data(for account: String) throws -> Data? {
        if let ephemeralStore { return try ephemeralStore.data(for: account) }
        if let data = try vault.data(
            service: service,
            account: account,
            allowsAuthenticationUI: allowsAuthenticationUI
        ) {
            return data
        }
        // Existing releases stored one Keychain item per service. Keep those
        // usable, then fold each one into the single Nexus vault the first
        // time it is accessed. New secrets never create another item.
        if let data = try legacyData(for: account) {
            try vault.set(data, service: service, account: account)
            return data
        }
        return nil
    }

    func set(_ data: Data, for account: String) throws {
        if let ephemeralStore {
            try ephemeralStore.set(data, for: account)
            return
        }
        try vault.set(data, service: service, account: account)
    }

    func delete(account: String) throws {
        if let ephemeralStore {
            try ephemeralStore.delete(account: account)
            return
        }
        try vault.delete(service: service, account: account)
        try? legacyDelete(account: account)
    }

    private func legacyData(for account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsAuthenticationUI {
            // A background daemon credential must never block the visible app
            // behind a stale Keychain ACL or an unseen authentication sheet.
            // Interactive user credentials retain the normal Keychain prompt.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NexusConnectError.unavailable("Keychain read failed (\(status))")
        }
        return data
    }

    private func legacyDelete(account: String) throws {
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

/// A single Keychain item for all Nexus-owned credentials. macOS still owns
/// authentication and may show its native dialog, but it happens against one
/// signed Nexus item instead of a separate item for every provider, connector,
/// pairing, and local worker credential. The value never leaves Keychain.
final class NexusUnifiedKeychainVault: @unchecked Sendable {
    static let shared = NexusUnifiedKeychainVault()

    private static let service = "na.nexus.secure-vault"
    private static let account = "secrets.v1"
    private static let legacyServices = [
        "na.nexus.connect",
        "na.nexus.model-provider",
        "na.nexus.managed-inference",
        "na.nexus.nex-cli",
        "na.nexus.connectors.registration",
        "na.nexus.connectors.oauth"
    ]
    private let lock = NSLock()

    private init() {}

    var isConfigured: Bool {
        lock.withLock { (try? read()) != nil }
    }

    /// Consolidates every currently-known Nexus service and account into the
    /// shared record. Legacy items are deliberately left untouched: the copy
    /// is verified before use and the originals remain a rollback path.
    @discardableResult
    func prepare() throws -> NexusKeychainMigrationReport {
        try lock.withLock {
            var values = try read() ?? [:]
            var copied = 0
            var skippedServices = 0
            for legacyService in Self.legacyServices {
                do {
                    for (account, data) in try legacyEntries(service: legacyService) {
                        let entryKey = key(legacyService, account)
                        guard values[entryKey] == nil else { continue }
                        values[entryKey] = data.base64EncodedString()
                        copied += 1
                    }
                } catch {
                    // One old ACL must not prevent the rest of the user's
                    // credentials from moving. The unchanged source item can
                    // still migrate later when macOS permits access.
                    skippedServices += 1
                }
            }
            try write(values)
            let verified = try read() ?? [:]
            guard verified == values else {
                throw NexusConnectError.unavailable("Nexus secure vault verification failed")
            }
            return .init(copiedEntries: copied, skippedServices: skippedServices)
        }
    }

    func data(
        service: String,
        account: String,
        allowsAuthenticationUI: Bool = true
    ) throws -> Data? {
        try lock.withLock {
            guard let values = try read(allowsAuthenticationUI: allowsAuthenticationUI),
                  let encoded = values[key(service, account)] else { return nil }
            guard let value = Data(base64Encoded: encoded) else {
                throw NexusConnectError.unavailable("Nexus secure vault contains unreadable data")
            }
            return value
        }
    }

    func set(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            var values = try read() ?? [:]
            values[key(service, account)] = data.base64EncodedString()
            try write(values)
        }
    }

    func delete(service: String, account: String) throws {
        try lock.withLock {
            guard var values = try read() else { return }
            values.removeValue(forKey: key(service, account))
            try write(values)
        }
    }

    private func key(_ service: String, _ account: String) -> String { "\(service)\u{1F}\(account)" }

    private func legacyEntries(service: String) throws -> [(String, Data)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw NexusConnectError.unavailable("Keychain migration read failed (\(status))")
        }
        let items: [[String: Any]]
        if let array = result as? [[String: Any]] { items = array }
        else if let item = result as? [String: Any] { items = [item] }
        else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { return nil }
            return (account, data)
        }
    }

    private func read(allowsAuthenticationUI: Bool = true) throws -> [String: String]? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsAuthenticationUI {
            // Daemons and launch-time restoration must report a stale ACL as
            // unavailable instead of blocking behind an invisible Keychain sheet.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NexusConnectError.unavailable("Nexus secure vault read failed (\(status))")
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func write(_ values: [String: String]) throws {
        let data = try JSONEncoder().encode(values)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw NexusConnectError.unavailable("Nexus secure vault update failed (\(status))")
        }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrSynchronizable as String] = false
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NexusConnectError.unavailable("Nexus secure vault setup failed (\(addStatus))")
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
    }
}

struct NexusKeychainMigrationReport: Sendable {
    let copiedEntries: Int
    let skippedServices: Int
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
    /// Identifies one host-issued invitation without exposing its secret. It is
    /// optional so protocol-v1 and early-v2 pairing records remain decodable.
    let pairingID: UUID?

    init(
        secret: Data,
        peerDeviceID: UUID? = nil,
        peerSigningPublicKey: Data? = nil,
        pairingID: UUID? = nil
    ) throws {
        guard secret.count == 32 else { throw NexusConnectError.authenticationFailed }
        self.secret = secret
        self.peerDeviceID = peerDeviceID
        self.peerSigningPublicKey = peerSigningPublicKey
        self.pairingID = pairingID
    }

    static func fresh(pairingID: UUID? = nil) throws -> NexusPairingMaterial {
        try NexusPairingMaterial(secret: Data(SymmetricKey(size: .bits256)), pairingID: pairingID)
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
            peerSigningPublicKey: peerSigningPublicKey,
            pairingID: pairingID
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

protocol NexusSessionCredentialProviding: Sendable {
    func loadOrCreateIdentity() throws -> NexusDeviceIdentity
    func loadPairing() throws -> NexusPairingMaterial?
    func savePairing(_ pairing: NexusPairingMaterial) throws
}

extension NexusIdentityVault: NexusSessionCredentialProviding {}

/// Uses one persistent client identity but a distinct pairing secret and pin
/// for every remote node.
struct NexusPairedNodeCredentials: NexusSessionCredentialProviding, Sendable {
    let identityVault: NexusIdentityVault
    let roster: NexusPairedNodeStore
    let nodeID: UUID

    func loadOrCreateIdentity() throws -> NexusDeviceIdentity {
        try identityVault.loadOrCreateIdentity()
    }

    func loadPairing() throws -> NexusPairingMaterial? {
        try roster.pairing(for: nodeID)
    }

    func savePairing(_ pairing: NexusPairingMaterial) throws {
        guard pairing.peerDeviceID == nil || pairing.peerDeviceID == nodeID else {
            throw NexusConnectError.identityMismatch
        }
        try roster.savePairing(pairing, for: nodeID)
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
    /// Optional to keep v1 hello messages decodable during rolling upgrades.
    let appVersion: String?
    let features: Set<NexusConnectFeature>?
    /// Protocol-v2 invitation selector. The signed value lets a host choose the
    /// correct per-client secret before authentication without revealing it.
    let pairingID: UUID?
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
        nonce: Data? = nil,
        appVersion: String = NexusAppMetadata.version,
        features: Set<NexusConnectFeature> = Set(NexusConnectFeature.allCases),
        protocolRange: NexusProtocolVersionRange = .local
    ) throws -> NexusPendingHandshake {
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.signingPrivateKey)
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let unsigned = NexusUnsignedHello(
            protocolMinimum: protocolRange.minimum,
            protocolMaximum: protocolRange.maximum,
            deviceID: identity.deviceID,
            role: role,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            ephemeralPublicKey: ephemeralKey.publicKey.rawRepresentation,
            nonce: nonce ?? randomBytes(count: 32),
            respondingToNonce: respondingToNonce,
            timestampMilliseconds: timestampMilliseconds,
            appVersion: appVersion,
            features: features.sorted { $0.rawValue < $1.rawValue },
            pairingID: pairing.pairingID
        )
        let unsignedData: Data
        if unsigned.pairingID == nil {
            unsignedData = try canonicalData(NexusPreMultiClientUnsignedHello(
                protocolMinimum: unsigned.protocolMinimum,
                protocolMaximum: unsigned.protocolMaximum,
                deviceID: unsigned.deviceID,
                role: unsigned.role,
                signingPublicKey: unsigned.signingPublicKey,
                ephemeralPublicKey: unsigned.ephemeralPublicKey,
                nonce: unsigned.nonce,
                respondingToNonce: unsigned.respondingToNonce,
                timestampMilliseconds: unsigned.timestampMilliseconds,
                appVersion: unsigned.appVersion,
                features: unsigned.features
            ))
        } else {
            unsignedData = try canonicalData(unsigned)
        }
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
                authenticationCode: authenticationCode,
                appVersion: unsigned.appVersion,
                features: Set(unsigned.features ?? []),
                pairingID: unsigned.pairingID
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
        let unsignedData: Data
        if hello.appVersion == nil, hello.features == nil {
            unsignedData = try canonicalData(hello.legacyUnsigned)
        } else if hello.pairingID == nil {
            // Early protocol-v2 builds signed the app/features fields but did
            // not yet include a pairing selector. Preserve that exact shape.
            unsignedData = try canonicalData(hello.preMultiClientUnsigned)
        } else {
            unsignedData = try canonicalData(hello.unsigned)
        }
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
    let appVersion: String?
    let features: [NexusConnectFeature]?
    let pairingID: UUID?
}

/// Exact v1 signed shape. Re-encoding a legacy hello with new optional fields
/// would change its signature even when those fields decode as nil.
private struct NexusLegacyUnsignedHello: Codable {
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

/// Exact signed shape emitted by protocol-v2 builds before multi-client host
/// trust was added.
private struct NexusPreMultiClientUnsignedHello: Codable {
    let protocolMinimum: Int
    let protocolMaximum: Int
    let deviceID: UUID
    let role: NexusNodeRole
    let signingPublicKey: Data
    let ephemeralPublicKey: Data
    let nonce: Data
    let respondingToNonce: Data?
    let timestampMilliseconds: Int64
    let appVersion: String?
    let features: [NexusConnectFeature]?
}

extension NexusHandshakeHello {
    var advertisedProtocolRange: NexusProtocolVersionRange {
        .init(minimum: protocolMinimum, maximum: protocolMaximum)
    }

    var advertisedFeatures: Set<NexusConnectFeature> {
        features ?? [.streamingInference, .resumableModelPull]
    }

    fileprivate var unsigned: NexusUnsignedHello {
        NexusUnsignedHello(
            protocolMinimum: protocolMinimum,
            protocolMaximum: protocolMaximum,
            deviceID: deviceID,
            role: role,
            signingPublicKey: signingPublicKey,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce,
            respondingToNonce: respondingToNonce,
            timestampMilliseconds: timestampMilliseconds,
            appVersion: appVersion,
            features: features?.sorted { $0.rawValue < $1.rawValue },
            pairingID: pairingID
        )
    }

    fileprivate var preMultiClientUnsigned: NexusPreMultiClientUnsignedHello {
        NexusPreMultiClientUnsignedHello(
            protocolMinimum: protocolMinimum,
            protocolMaximum: protocolMaximum,
            deviceID: deviceID,
            role: role,
            signingPublicKey: signingPublicKey,
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce,
            respondingToNonce: respondingToNonce,
            timestampMilliseconds: timestampMilliseconds,
            appVersion: appVersion,
            features: features?.sorted { $0.rawValue < $1.rawValue }
        )
    }

    fileprivate var legacyUnsigned: NexusLegacyUnsignedHello {
        NexusLegacyUnsignedHello(
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

enum NexusAppMetadata {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
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
