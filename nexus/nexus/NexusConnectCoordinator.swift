import Combine
import Foundation

struct NexusReconnectPolicy: Equatable, Sendable {
    let initialDelaySeconds: Double
    let maximumDelaySeconds: Double
    let multiplier: Double
    let jitterFraction: Double

    static let standard = NexusReconnectPolicy(
        initialDelaySeconds: 0.5,
        maximumDelaySeconds: 30,
        multiplier: 2,
        jitterFraction: 0.2
    )

    func delaySeconds(attempt: Int, randomUnit: Double = Double.random(in: 0...1)) -> Double {
        let exponent = pow(multiplier, Double(max(0, attempt)))
        let base = min(maximumDelaySeconds, initialDelaySeconds * exponent)
        let centeredJitter = (min(1, max(0, randomUnit)) * 2) - 1
        return max(0, base * (1 + centeredJitter * jitterFraction))
    }
}

struct NexusBandwidthPolicy: Equatable, Sendable {
    let interactiveConcurrency: Int
    let transferConcurrency: Int
    let preferredChunkBytes: Int

    static func policy(for quality: NexusConnectionQuality) -> NexusBandwidthPolicy {
        let download = quality.downloadBytesPerSecond ?? 0
        switch quality.route {
        case .direct where download >= 80 * 1_024 * 1_024:
            return .init(interactiveConcurrency: 8, transferConcurrency: 4, preferredChunkBytes: 4 * 1_024 * 1_024)
        case .direct:
            return .init(interactiveConcurrency: 6, transferConcurrency: 2, preferredChunkBytes: 1 * 1_024 * 1_024)
        case .peerRelay:
            return .init(interactiveConcurrency: 4, transferConcurrency: 2, preferredChunkBytes: 512 * 1_024)
        case .derp, .unknown:
            return .init(interactiveConcurrency: 3, transferConcurrency: 1, preferredChunkBytes: 256 * 1_024)
        }
    }
}

actor NexusQualityMonitor {
    private let smoothingFactor: Double
    private var route: NexusConnectionRoute = .unknown
    private var roundTripMilliseconds: Double?
    private var uploadBytesPerSecond: Double?
    private var downloadBytesPerSecond: Double?
    private var samples = 0
    private var failures = 0

    init(smoothingFactor: Double = 0.25) {
        self.smoothingFactor = min(1, max(0.01, smoothingFactor))
    }

    func recordRoute(_ sample: NexusTailscaleRouteSample) {
        route = sample.route
        if let rtt = sample.roundTripMilliseconds {
            roundTripMilliseconds = smooth(old: roundTripMilliseconds, new: rtt)
        }
    }

    func recordTransfer(bytes: Int64, durationSeconds: Double, upload: Bool) {
        guard bytes >= 0, durationSeconds > 0 else { return }
        let rate = Double(bytes) / durationSeconds
        if upload {
            uploadBytesPerSecond = smooth(old: uploadBytesPerSecond, new: rate)
        } else {
            downloadBytesPerSecond = smooth(old: downloadBytesPerSecond, new: rate)
        }
    }

    func recordRequest(success: Bool) {
        samples += 1
        if !success { failures += 1 }
        if samples > 100 {
            samples = max(1, samples / 2)
            failures /= 2
        }
    }

    func snapshot() -> NexusConnectionQuality {
        .init(
            route: route,
            roundTripMilliseconds: roundTripMilliseconds,
            uploadBytesPerSecond: uploadBytesPerSecond,
            downloadBytesPerSecond: downloadBytesPerSecond,
            recentFailureRate: samples == 0 ? 0 : Double(failures) / Double(samples)
        )
    }

    private func smooth(old: Double?, new: Double) -> Double {
        guard let old else { return new }
        return old + smoothingFactor * (new - old)
    }
}

enum NexusConnectLifecycleState: Equatable, Sendable {
    case disabled
    case discovering
    case connecting(NexusTailscalePeer)
    case authenticating(NexusTailscalePeer)
    case ready(peer: NexusTailscalePeer, health: NexusNodeHealth, quality: NexusConnectionQuality)
    case reconnecting(message: String, attempt: Int)
    case offline(message: String)

    var canUseRemote: Bool {
        if case .ready = self { return true }
        return false
    }
}

protocol NexusRemoteSession: Sendable {
    func connect(to peer: NexusTailscalePeer) async throws -> NexusNodeHealth
    func health() async throws -> NexusNodeHealth
    func disconnect() async
}

protocol NexusManagedRemoteSession: NexusRemoteSession, NexusWorkloadExecuting {
    func supports(_ feature: NexusConnectFeature) async -> Bool
}

extension NexusManagedRemoteSession {
    func supports(_ feature: NexusConnectFeature) async -> Bool { false }
}

extension NexusRemoteClientSession: NexusManagedRemoteSession {}

/// Maintains an independent authenticated session and reconnect loop for every
/// saved node. The legacy single-Studio coordinator remains below only for v1
/// API compatibility; new app code uses this roster coordinator.
@MainActor
final class NexusPairedNodeCoordinator: ObservableObject {
    typealias SessionFactory = @Sendable (NexusPairedNode) -> any NexusManagedRemoteSession

    @Published private(set) var nodes: [NexusPairedNode] = []

    private let discovery: any NexusNodeDiscovering
    private let roster: NexusPairedNodeStore
    private let sessionFactory: SessionFactory
    private let reconnectPolicy: NexusReconnectPolicy
    private let healthIntervalNanoseconds: UInt64
    private var sessions: [UUID: any NexusManagedRemoteSession] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var enabled = false

    init(
        discovery: any NexusNodeDiscovering,
        roster: NexusPairedNodeStore,
        reconnectPolicy: NexusReconnectPolicy = .standard,
        healthIntervalSeconds: TimeInterval = 5,
        sessionFactory: @escaping SessionFactory
    ) {
        self.discovery = discovery
        self.roster = roster
        self.reconnectPolicy = reconnectPolicy
        self.healthIntervalNanoseconds = UInt64(max(0.05, healthIntervalSeconds) * 1_000_000_000)
        self.sessionFactory = sessionFactory
    }

    func start(nodes initialNodes: [NexusPairedNode]) {
        enabled = true
        let desiredIDs = Set(initialNodes.map(\.id))
        for id in tasks.keys where !desiredIDs.contains(id) {
            tasks.removeValue(forKey: id)?.cancel()
            if let session = sessions.removeValue(forKey: id) {
                Task { await session.disconnect() }
            }
        }
        nodes = initialNodes
        for node in initialNodes where tasks[node.id] == nil {
            startLoop(for: node)
        }
    }

    func reconnect(nodeID: UUID) {
        guard enabled, let node = nodes.first(where: { $0.id == nodeID }) else { return }
        tasks.removeValue(forKey: nodeID)?.cancel()
        if let session = sessions.removeValue(forKey: nodeID) {
            Task { await session.disconnect() }
        }
        update(nodeID) {
            $0.status = .reconnecting
            $0.statusDetail = "Reconnect requested"
        }
        startLoop(for: node)
    }

    func forget(nodeID: UUID) {
        tasks.removeValue(forKey: nodeID)?.cancel()
        if let session = sessions.removeValue(forKey: nodeID) {
            Task { await session.disconnect() }
        }
        nodes.removeAll { $0.id == nodeID }
    }

    func stop() {
        enabled = false
        let activeTasks = tasks.values
        let activeSessions = sessions.values
        tasks.removeAll()
        sessions.removeAll()
        activeTasks.forEach { $0.cancel() }
        for session in activeSessions { Task { await session.disconnect() } }
    }

    func executor(for nodeID: UUID) -> (any NexusWorkloadExecuting)? {
        guard nodes.first(where: { $0.id == nodeID })?.status == .online else { return nil }
        return sessions[nodeID]
    }

    private func startLoop(for node: NexusPairedNode) {
        let session = sessionFactory(node)
        sessions[node.id] = session
        tasks[node.id] = Task { [weak self] in
            await self?.run(nodeID: node.id, session: session)
        }
    }

    private func run(nodeID: UUID, session: any NexusManagedRemoteSession) async {
        var attempt = 0
        while enabled, !Task.isCancelled {
            do {
                update(nodeID) {
                    $0.status = .reconnecting
                    $0.statusDetail = attempt == 0 ? "Connecting…" : "Reconnect attempt \(attempt + 1)"
                }
                let savedNode = try currentNode(nodeID)
                let snapshot = try await discovery.snapshot()
                let peer = try snapshot.exactPeer(for: savedNode)
                let health = try await session.connect(to: peer)
                guard health.nodeID == nodeID else { throw NexusConnectError.identityMismatch }
                let remoteRange = NexusProtocolVersionRange(
                    minimum: health.protocolMinimum,
                    maximum: health.protocolMaximum
                )
                guard NexusProtocolVersionRange.local.highestCommonVersion(with: remoteRange) != nil else {
                    throw NexusConnectError.unsupportedProtocol
                }
                let quality = await connectionQuality(for: peer)
                let inventory = try await loadInventory(from: session)
                let runtimes = await session.supports(.runtimeProvisioning)
                    ? try await loadRuntimes(from: session)
                    : []
                applyOnline(
                    nodeID: nodeID,
                    health: health,
                    peer: peer,
                    quality: quality,
                    inventory: inventory,
                    runtimes: runtimes
                )
                attempt = 0

                while enabled, !Task.isCancelled {
                    try await Task.sleep(nanoseconds: healthIntervalNanoseconds)
                    let latest = try await session.health()
                    guard latest.nodeID == nodeID else { throw NexusConnectError.identityMismatch }
                    applyOnline(
                        nodeID: nodeID,
                        health: latest,
                        peer: peer,
                        quality: quality,
                        inventory: nil,
                        runtimes: nil
                    )
                }
            } catch is CancellationError {
                return
            } catch NexusConnectError.identityMismatch {
                await session.disconnect()
                update(nodeID) {
                    $0.status = .incompatible
                    $0.statusDetail = "Security identity mismatch. Forget and pair this device again."
                }
                return
            } catch NexusConnectError.unsupportedProtocol {
                await session.disconnect()
                update(nodeID) {
                    $0.status = .incompatible
                    $0.statusDetail = "No compatible Nexus Connect protocol. Upgrade this Mac or the remote host."
                }
                return
            } catch {
                await session.disconnect()
                guard enabled, !Task.isCancelled else { return }
                let delay = reconnectPolicy.delaySeconds(attempt: attempt)
                attempt += 1
                update(nodeID) {
                    $0.status = .offline
                    $0.statusDetail = "\(error.localizedDescription) · retrying in \(Int(ceil(delay)))s"
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    private func loadInventory(from session: any NexusManagedRemoteSession) async throws -> [NexusModelDescriptor] {
        let request = try NexusWorkloadRequest(
            kind: .modelList,
            retrySafety: .idempotent,
            payload: NexusModelListPayload(runtime: nil)
        )
        let stream = try await session.events(for: request)
        for try await event in stream where event.kind == .result {
            return try event.decodePayload(NexusModelInventoryPayload.self).models
        }
        return []
    }

    private func loadRuntimes(from session: any NexusManagedRemoteSession) async throws -> Set<NexusRuntimeAvailability> {
        let request = try NexusWorkloadRequest(
            kind: .runtimeStatus,
            retrySafety: .idempotent,
            payload: NexusEmptyPayload()
        )
        let stream = try await session.events(for: request)
        for try await event in stream where event.kind == .result {
            return try event.decodePayload(NexusRuntimeInventoryPayload.self).runtimes
        }
        return []
    }

    private func connectionQuality(for peer: NexusTailscalePeer) async -> NexusConnectionQuality {
        let route = try? await discovery.routeSample(to: peer)
        return .init(
            route: route?.route ?? .unknown,
            roundTripMilliseconds: route?.roundTripMilliseconds,
            uploadBytesPerSecond: nil,
            downloadBytesPerSecond: nil,
            recentFailureRate: 0
        )
    }

    private func applyOnline(
        nodeID: UUID,
        health: NexusNodeHealth,
        peer: NexusTailscalePeer,
        quality: NexusConnectionQuality,
        inventory: [NexusModelDescriptor]?,
        runtimes: Set<NexusRuntimeAvailability>?
    ) {
        update(nodeID) {
            $0.apply(
                health: health,
                endpoint: peer.connectionHost,
                tailscaleNodeID: peer.id,
                inventory: inventory,
                runtimes: runtimes
            )
            $0.statusDetail = quality.roundTripMilliseconds.map { "\(Int($0.rounded())) ms" }
        }
    }

    private func currentNode(_ id: UUID) throws -> NexusPairedNode {
        guard let node = nodes.first(where: { $0.id == id }) else {
            throw NexusConnectError.unavailable("paired device was forgotten")
        }
        return node
    }

    private func update(_ id: UUID, mutation: (inout NexusPairedNode) -> Void) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        mutation(&nodes[index])
        try? roster.upsert(nodes[index])
    }
}

@MainActor
final class NexusConnectCoordinator: ObservableObject {
    @Published private(set) var state: NexusConnectLifecycleState = .disabled

    private let discovery: any NexusStudioDiscovering
    private let sessionFactory: @Sendable () -> any NexusRemoteSession
    private let qualityMonitor: NexusQualityMonitor
    private let reconnectPolicy: NexusReconnectPolicy
    private let healthIntervalNanoseconds: UInt64
    private let pairingIsAvailable: @Sendable () -> Bool
    private var lifecycleTask: Task<Void, Never>?
    private var activeSession: (any NexusRemoteSession)?
    private var enabled = false
    private var preferredNodeID: String?

    init(
        discovery: any NexusStudioDiscovering,
        sessionFactory: @escaping @Sendable () -> any NexusRemoteSession,
        qualityMonitor: NexusQualityMonitor = NexusQualityMonitor(),
        reconnectPolicy: NexusReconnectPolicy = .standard,
        healthIntervalSeconds: TimeInterval = 5,
        pairingIsAvailable: @escaping @Sendable () -> Bool
    ) {
        self.discovery = discovery
        self.sessionFactory = sessionFactory
        self.qualityMonitor = qualityMonitor
        self.reconnectPolicy = reconnectPolicy
        self.healthIntervalNanoseconds = UInt64(max(0.05, healthIntervalSeconds) * 1_000_000_000)
        self.pairingIsAvailable = pairingIsAvailable
    }

    func start(enabled: Bool, preferredNodeID: String? = nil) {
        self.enabled = enabled
        self.preferredNodeID = preferredNodeID
        lifecycleTask?.cancel()
        lifecycleTask = nil

        guard enabled else {
            state = .disabled
            Task { await activeSession?.disconnect() }
            activeSession = nil
            return
        }
        guard pairingIsAvailable() else {
            state = .offline(message: "Pair this Mac with the Studio before enabling Nexus Connect.")
            return
        }
        lifecycleTask = Task { [weak self] in await self?.runLifecycle() }
    }

    func stop() {
        start(enabled: false)
    }

    private func runLifecycle() async {
        var attempt = 0
        while enabled, !Task.isCancelled {
            do {
                state = .discovering
                let peer = try await discovery.discoverStudio(preferredNodeID: preferredNodeID)
                guard enabled, !Task.isCancelled else { return }
                state = .connecting(peer)
                let session = sessionFactory()
                activeSession = session
                state = .authenticating(peer)
                let health = try await session.connect(to: peer)
                let route = try? await discovery.routeSample(to: peer)
                if let route { await qualityMonitor.recordRoute(route) }
                await qualityMonitor.recordRequest(success: true)
                state = .ready(peer: peer, health: health, quality: await qualityMonitor.snapshot())
                attempt = 0

                while enabled, !Task.isCancelled {
                    try await Task.sleep(nanoseconds: healthIntervalNanoseconds)
                    let started = Date()
                    let latestHealth = try await session.health()
                    let elapsed = Date().timeIntervalSince(started) * 1_000
                    await qualityMonitor.recordRoute(.init(route: (await qualityMonitor.snapshot()).route, roundTripMilliseconds: elapsed, description: "Nexus health"))
                    await qualityMonitor.recordRequest(success: true)
                    state = .ready(peer: peer, health: latestHealth, quality: await qualityMonitor.snapshot())
                }
            } catch is CancellationError {
                return
            } catch {
                await qualityMonitor.recordRequest(success: false)
                await activeSession?.disconnect()
                activeSession = nil
                guard enabled, !Task.isCancelled else { return }
                state = .reconnecting(message: error.localizedDescription, attempt: attempt + 1)
                let delay = reconnectPolicy.delaySeconds(attempt: attempt)
                attempt += 1
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
        if enabled { state = .offline(message: "Mac Studio is offline; Nexus is using this Mac.") }
    }
}
