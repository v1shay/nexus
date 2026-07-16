import Foundation

/// Connection state is deliberately persisted with the node record so Nexus can
/// explain what happened after a restart. A previously-online node is changed to
/// `reconnecting` at launch until a fresh authenticated health check succeeds.
enum NexusPairedNodeStatus: String, Codable, CaseIterable, Sendable {
    case online
    case offline
    case reconnecting
    case incompatible
    case revoked
}

enum NexusPairedDeviceRole: String, Codable, Sendable {
    case computeHost
    case client
}

struct NexusRuntimeAvailability: Codable, Equatable, Hashable, Sendable {
    let kind: NexusRuntimeKind
    let version: String?
    let isManagedByNexus: Bool

    init(kind: NexusRuntimeKind, version: String? = nil, isManagedByNexus: Bool = false) {
        self.kind = kind
        self.version = version
        self.isManagedByNexus = isManagedByNexus
    }
}

struct NexusProtocolVersionRange: Codable, Equatable, Sendable {
    let minimum: Int
    let maximum: Int

    init(minimum: Int, maximum: Int) {
        self.minimum = minimum
        self.maximum = maximum
    }

    var isValid: Bool { minimum > 0 && maximum >= minimum }

    func highestCommonVersion(with other: NexusProtocolVersionRange) -> Int? {
        let lower = max(minimum, other.minimum)
        let upper = min(maximum, other.maximum)
        return lower <= upper ? upper : nil
    }

    static let local = NexusProtocolVersionRange(
        minimum: NexusConnectProtocol.minimumVersion,
        maximum: NexusConnectProtocol.currentVersion
    )
}

/// Durable, non-secret metadata for one explicitly paired computer. The
/// per-device symmetric secret is stored separately under a node-specific
/// Keychain account by `NexusPairedNodeStore`.
struct NexusPairedNode: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var pinnedPublicIdentityKey: Data
    var displayName: String
    var endpoint: String
    var tailscaleNodeID: String?
    var deviceRole: NexusPairedDeviceRole
    var capabilities: Set<NexusCapability>
    var lastSuccessfulHealthCheck: Date?
    var appVersion: String?
    var protocolRange: NexusProtocolVersionRange
    var runtimes: Set<NexusRuntimeAvailability>
    var modelInventory: [NexusModelDescriptor]
    var status: NexusPairedNodeStatus
    var statusDetail: String?
    var totalMemoryBytes: UInt64?
    var availableMemoryBytes: UInt64?
    var availableDiskBytes: Int64?

    init(
        id: UUID,
        pinnedPublicIdentityKey: Data,
        displayName: String,
        endpoint: String,
        tailscaleNodeID: String? = nil,
        deviceRole: NexusPairedDeviceRole = .computeHost,
        capabilities: Set<NexusCapability> = [],
        lastSuccessfulHealthCheck: Date? = nil,
        appVersion: String? = nil,
        protocolRange: NexusProtocolVersionRange = .local,
        runtimes: Set<NexusRuntimeAvailability> = [],
        modelInventory: [NexusModelDescriptor] = [],
        status: NexusPairedNodeStatus = .reconnecting,
        statusDetail: String? = nil,
        totalMemoryBytes: UInt64? = nil,
        availableMemoryBytes: UInt64? = nil,
        availableDiskBytes: Int64? = nil
    ) {
        self.id = id
        self.pinnedPublicIdentityKey = pinnedPublicIdentityKey
        self.displayName = displayName
        self.endpoint = Self.normalizedEndpoint(endpoint)
        self.tailscaleNodeID = tailscaleNodeID
        self.deviceRole = deviceRole
        self.capabilities = capabilities
        self.lastSuccessfulHealthCheck = lastSuccessfulHealthCheck
        self.appVersion = appVersion
        self.protocolRange = protocolRange
        self.runtimes = runtimes
        self.modelInventory = modelInventory
        self.status = status
        self.statusDetail = statusDetail
        self.totalMemoryBytes = totalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.availableDiskBytes = availableDiskBytes
    }

    var isAvailable: Bool { status == .online }

    func hasModel(_ model: NexusModelDescriptor) -> Bool {
        modelInventory.contains(model)
    }

    mutating func markForLaunchReconnect() {
        guard status != .revoked, status != .incompatible else { return }
        status = .reconnecting
        statusDetail = "Waiting for an authenticated health check"
    }

    mutating func apply(
        health: NexusNodeHealth,
        endpoint: String? = nil,
        tailscaleNodeID: String? = nil,
        inventory: [NexusModelDescriptor]? = nil,
        runtimes: Set<NexusRuntimeAvailability>? = nil
    ) {
        displayName = health.nodeName
        if let endpoint { self.endpoint = Self.normalizedEndpoint(endpoint) }
        if let tailscaleNodeID { self.tailscaleNodeID = tailscaleNodeID }
        capabilities = health.capabilities
        lastSuccessfulHealthCheck = Date(timeIntervalSince1970: Double(health.timestampMilliseconds) / 1_000)
        appVersion = health.hostVersion
        protocolRange = .init(minimum: health.protocolMinimum, maximum: health.protocolMaximum)
        totalMemoryBytes = health.totalMemoryBytes
        availableMemoryBytes = health.availableMemoryBytes
        availableDiskBytes = health.availableDiskBytes
        if let inventory { modelInventory = inventory }
        if let runtimes { self.runtimes = runtimes }
        status = .online
        statusDetail = nil
    }

    private static func normalizedEndpoint(_ endpoint: String) -> String {
        endpoint.hasSuffix(".") ? String(endpoint.dropLast()) : endpoint
    }
}

enum NexusModelRoute: Codable, Equatable, Hashable, Identifiable, Sendable {
    case automatic
    case thisMac
    case pairedNode(UUID)

    var id: String {
        switch self {
        case .automatic: "automatic"
        case .thisMac: "local"
        case .pairedNode(let id): "node:\(id.uuidString.lowercased())"
        }
    }
}

enum NexusDownloadTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    case automatic
    case thisMac
    case pairedNode(UUID)

    var id: String {
        switch self {
        case .automatic: "automatic"
        case .thisMac: "local"
        case .pairedNode(let id): "node:\(id.uuidString.lowercased())"
        }
    }
}

/// Keychain-backed roster. Public metadata and secrets intentionally use
/// separate accounts so forgetting one node can revoke only that relationship.
final class NexusPairedNodeStore: @unchecked Sendable {
    enum Scope: String, Sendable {
        case client
        case host
    }

    private struct RosterEnvelope: Codable {
        var schemaVersion: Int
        var nodes: [NexusPairedNode]
    }

    private let secretStore: NexusSecretStore
    private let scope: Scope
    private let lock = NSRecursiveLock()

    init(secretStore: NexusSecretStore = NexusKeychainSecretStore(), scope: Scope = .client) {
        self.secretStore = secretStore
        self.scope = scope
    }

    func load() throws -> [NexusPairedNode] {
        try lock.withLock {
            guard let data = try secretStore.data(for: rosterAccount) else { return [] }
            let envelope = try NexusPayloadCoder.decoder.decode(RosterEnvelope.self, from: data)
            return envelope.nodes.sorted(by: Self.sortNodes)
        }
    }

    @discardableResult
    func prepareForLaunch() throws -> [NexusPairedNode] {
        try lock.withLock {
            var nodes = try load()
            nodes.indices.forEach { nodes[$0].markForLaunchReconnect() }
            try save(nodes)
            return nodes
        }
    }

    func upsert(_ node: NexusPairedNode, pairing: NexusPairingMaterial? = nil) throws {
        try lock.withLock {
            var nodes = try load()
            if let index = nodes.firstIndex(where: { $0.id == node.id }) {
                let existing = nodes[index]
                guard existing.pinnedPublicIdentityKey.isEmpty || node.pinnedPublicIdentityKey.isEmpty ||
                        existing.pinnedPublicIdentityKey == node.pinnedPublicIdentityKey else {
                    throw NexusConnectError.identityMismatch
                }
                nodes[index] = node
            } else {
                nodes.append(node)
            }
            if let pairing { try savePairing(pairing, for: node.id) }
            try save(nodes)
        }
    }

    func rename(nodeID: UUID, to displayName: String) throws {
        try mutate(nodeID: nodeID) { node in
            let cleaned = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            node.displayName = cleaned
        }
    }

    func update(nodeID: UUID, _ mutation: (inout NexusPairedNode) throws -> Void) throws {
        try mutate(nodeID: nodeID, mutation)
    }

    func pairing(for nodeID: UUID) throws -> NexusPairingMaterial? {
        try lock.withLock {
            guard let data = try secretStore.data(for: pairingAccount(nodeID)) else { return nil }
            return try NexusPayloadCoder.decoder.decode(NexusPairingMaterial.self, from: data)
        }
    }

    func savePairing(_ pairing: NexusPairingMaterial, for nodeID: UUID) throws {
        try lock.withLock {
            try secretStore.set(
                try NexusPayloadCoder.encoder.encode(pairing),
                for: pairingAccount(nodeID)
            )
        }
    }

    func forget(nodeID: UUID) throws {
        try lock.withLock {
            var nodes = try load()
            nodes.removeAll { $0.id == nodeID }
            try secretStore.delete(account: pairingAccount(nodeID))
            try save(nodes)
        }
    }

    /// Imports the already-working v1 single-peer relationship once the old
    /// pairing has pinned a concrete host identity. The legacy account remains
    /// intact until the new session succeeds, making migration rollback-safe.
    @discardableResult
    func migrateLegacyPairing(
        _ legacy: NexusPairingMaterial?,
        displayName: String = "Paired Mac",
        endpoint: String = ""
    ) throws -> NexusPairedNode? {
        try lock.withLock {
            guard try load().isEmpty,
                  let legacy,
                  let nodeID = legacy.peerDeviceID,
                  let key = legacy.peerSigningPublicKey else { return nil }
            let node = NexusPairedNode(
                id: nodeID,
                pinnedPublicIdentityKey: key,
                displayName: displayName,
                endpoint: endpoint
            )
            try upsert(node, pairing: legacy)
            return node
        }
    }

    private func mutate(nodeID: UUID, _ mutation: (inout NexusPairedNode) throws -> Void) throws {
        try lock.withLock {
            var nodes = try load()
            guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else {
                throw NexusConnectError.unavailable("paired device was not found")
            }
            try mutation(&nodes[index])
            try save(nodes)
        }
    }

    private func save(_ nodes: [NexusPairedNode]) throws {
        let envelope = RosterEnvelope(schemaVersion: 2, nodes: nodes.sorted(by: Self.sortNodes))
        try secretStore.set(try NexusPayloadCoder.encoder.encode(envelope), for: rosterAccount)
    }

    private var rosterAccount: String { "paired-node-roster.\(scope.rawValue).v2" }

    private func pairingAccount(_ nodeID: UUID) -> String {
        "paired-node.\(scope.rawValue).\(nodeID.uuidString.lowercased()).pairing.v2"
    }

    private static func sortNodes(_ lhs: NexusPairedNode, _ rhs: NexusPairedNode) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
    }
}

enum NexusAuthorizedClientStatus: String, Codable, Sendable {
    case pending
    case authorized
    case revoked
}

/// Non-secret host-side record for one client invitation. A pairing ID is not
/// authority by itself; the corresponding 256-bit secret lives in a separate
/// Keychain item and the client's public identity is pinned on first use.
struct NexusAuthorizedClient: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var clientDeviceID: UUID?
    var pinnedPublicIdentityKey: Data?
    var displayName: String
    var createdAt: Date
    var lastAuthenticatedAt: Date?
    var status: NexusAuthorizedClientStatus
}

final class NexusHostTrustStore: @unchecked Sendable {
    private struct Envelope: Codable {
        var schemaVersion: Int
        var clients: [NexusAuthorizedClient]
    }

    private let secretStore: NexusSecretStore
    private let lock = NSRecursiveLock()
    private let rosterAccount = "authorized-client-roster.host.v2"

    init(secretStore: NexusSecretStore = NexusKeychainSecretStore()) {
        self.secretStore = secretStore
    }

    func load() throws -> [NexusAuthorizedClient] {
        try lock.withLock {
            guard let data = try secretStore.data(for: rosterAccount) else { return [] }
            return try NexusPayloadCoder.decoder.decode(Envelope.self, from: data).clients
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    func registerInvitation(
        pairing: NexusPairingMaterial,
        displayName: String = "Pending device"
    ) throws {
        try lock.withLock {
            guard let pairingID = pairing.pairingID else {
                throw NexusConnectError.authenticationFailed
            }
            var clients = try load()
            let record = NexusAuthorizedClient(
                id: pairingID,
                clientDeviceID: pairing.peerDeviceID,
                pinnedPublicIdentityKey: pairing.peerSigningPublicKey,
                displayName: displayName,
                createdAt: Date(),
                lastAuthenticatedAt: nil,
                status: pairing.peerDeviceID == nil ? .pending : .authorized
            )
            if let index = clients.firstIndex(where: { $0.id == pairingID }) {
                guard clients[index].status != .revoked else {
                    throw NexusConnectError.authenticationFailed
                }
                clients[index] = record
            } else {
                clients.append(record)
            }
            try secretStore.set(
                try NexusPayloadCoder.encoder.encode(pairing),
                for: pairingAccount(pairingID)
            )
            try save(clients)
        }
    }

    func pairing(for pairingID: UUID) throws -> NexusPairingMaterial? {
        try lock.withLock {
            guard let record = try load().first(where: { $0.id == pairingID }),
                  record.status != .revoked,
                  let data = try secretStore.data(for: pairingAccount(pairingID)) else { return nil }
            let pairing = try NexusPayloadCoder.decoder.decode(NexusPairingMaterial.self, from: data)
            guard pairing.pairingID == pairingID else { throw NexusConnectError.identityMismatch }
            return pairing
        }
    }

    func activePairings() throws -> [NexusPairingMaterial] {
        try lock.withLock {
            try load().compactMap { client in
                guard client.status != .revoked,
                      let data = try secretStore.data(for: pairingAccount(client.id)) else { return nil }
                return try NexusPayloadCoder.decoder.decode(NexusPairingMaterial.self, from: data)
            }
        }
    }

    @discardableResult
    func authorize(
        pairingID: UUID,
        clientDeviceID: UUID,
        signingPublicKey: Data,
        defaultDisplayName: String = "Paired Mac"
    ) throws -> NexusPairingMaterial {
        try lock.withLock {
            guard var pairing = try pairing(for: pairingID) else {
                throw NexusConnectError.authenticationFailed
            }
            pairing = try pairing.pinning(
                peerDeviceID: clientDeviceID,
                peerSigningPublicKey: signingPublicKey
            )
            var clients = try load()
            guard let index = clients.firstIndex(where: { $0.id == pairingID }),
                  clients[index].status != .revoked else {
                throw NexusConnectError.authenticationFailed
            }
            if let pinnedID = clients[index].clientDeviceID, pinnedID != clientDeviceID {
                throw NexusConnectError.identityMismatch
            }
            if let pinnedKey = clients[index].pinnedPublicIdentityKey, pinnedKey != signingPublicKey {
                throw NexusConnectError.identityMismatch
            }
            clients[index].clientDeviceID = clientDeviceID
            clients[index].pinnedPublicIdentityKey = signingPublicKey
            if clients[index].displayName == "Pending device" {
                clients[index].displayName = defaultDisplayName
            }
            clients[index].lastAuthenticatedAt = Date()
            clients[index].status = .authorized
            try secretStore.set(
                try NexusPayloadCoder.encoder.encode(pairing),
                for: pairingAccount(pairingID)
            )
            try save(clients)
            return pairing
        }
    }

    func rename(pairingID: UUID, to name: String) throws {
        try mutate(pairingID: pairingID) { client in
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { client.displayName = cleaned }
        }
    }

    func revoke(pairingID: UUID) throws {
        try lock.withLock {
            try mutate(pairingID: pairingID) { $0.status = .revoked }
            try secretStore.delete(account: pairingAccount(pairingID))
        }
    }

    private func mutate(
        pairingID: UUID,
        _ mutation: (inout NexusAuthorizedClient) throws -> Void
    ) throws {
        try lock.withLock {
            var clients = try load()
            guard let index = clients.firstIndex(where: { $0.id == pairingID }) else {
                throw NexusConnectError.unavailable("authorized client was not found")
            }
            try mutation(&clients[index])
            try save(clients)
        }
    }

    private func save(_ clients: [NexusAuthorizedClient]) throws {
        try secretStore.set(
            try NexusPayloadCoder.encoder.encode(Envelope(schemaVersion: 2, clients: clients)),
            for: rosterAccount
        )
    }

    private func pairingAccount(_ pairingID: UUID) -> String {
        "authorized-client.host.\(pairingID.uuidString.lowercased()).pairing.v2"
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
