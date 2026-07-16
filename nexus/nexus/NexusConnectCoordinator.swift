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
