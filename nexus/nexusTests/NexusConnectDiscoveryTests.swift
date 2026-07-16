import Foundation
import XCTest
@testable import nexus

extension NexusGeometryTests {
    func testTailscaleDiscoverySelectsOnlineStudioAndToleratesUnknownJSONFields() async throws {
        let json = #"""
        {
          "BackendState": "Running",
          "FutureSchemaField": {"ignored": true},
          "Self": {"HostName": "air", "OS": "macOS"},
          "Peer": {
            "nodekey:laptop": {
              "ID": "laptop", "HostName": "other macbook", "DNSName": "other.tail.ts.net.",
              "OS": "macOS", "TailscaleIPs": ["100.64.0.2"], "Online": true
            },
            "nodekey:studio": {
              "ID": "studio", "HostName": "Vishay's Mac Studio", "DNSName": "studio.tail.ts.net.",
              "OS": "macOS", "TailscaleIPs": ["100.64.0.3"], "Online": true,
              "Active": true, "Relay": "sfo", "UnknownPeerField": 42
            },
            "nodekey:offline-studio": {
              "ID": "offline", "HostName": "old Mac Studio", "DNSName": "old.tail.ts.net.",
              "OS": "macOS", "TailscaleIPs": ["100.64.0.4"], "Online": false
            }
          }
        }
        """#.data(using: .utf8)!
        let discovery = NexusTailscaleDiscovery(
            runner: NexusCommandRunnerStub(statusData: json),
            executableOverride: URL(fileURLWithPath: "/usr/bin/true")
        )

        let selected = try await discovery.discoverStudio(preferredNodeID: nil)

        XCTAssertEqual(selected.id, "studio")
        XCTAssertEqual(selected.connectionHost, "studio.tail.ts.net")
        XCTAssertTrue(selected.active)
    }

    func testTailscaleDiscoveryHonorsPinnedPeerBeforeNameHeuristics() async throws {
        let json = #"""
        {"BackendState":"Running","Peer":{
          "nodekey:studio":{"ID":"studio","HostName":"Mac Studio","DNSName":"studio.ts.net.","OS":"macOS","Online":true},
          "nodekey:pinned":{"ID":"pinned","HostName":"Compute Node","DNSName":"compute.ts.net.","OS":"macOS","Online":true}
        }}
        """#.data(using: .utf8)!
        let discovery = NexusTailscaleDiscovery(
            runner: NexusCommandRunnerStub(statusData: json),
            executableOverride: URL(fileURLWithPath: "/usr/bin/true")
        )

        let selected = try await discovery.discoverStudio(preferredNodeID: "pinned")

        XCTAssertEqual(selected.id, "pinned")
    }

    func testTailscaleRouteParserDistinguishesDirectPeerRelayAndDERP() {
        let direct = NexusTailscaleDiscovery.parsePingOutput(
            "pong from studio (100.72.31.42) via 192.168.1.8:41641 in 11ms"
        )
        let peerRelay = NexusTailscaleDiscovery.parsePingOutput(
            "pong from studio via peer-relay(node) in 22.5ms"
        )
        let derp = NexusTailscaleDiscovery.parsePingOutput(
            "pong from studio via DERP(sfo) in 45ms"
        )

        XCTAssertEqual(direct.route, .direct)
        XCTAssertEqual(direct.roundTripMilliseconds, 11)
        XCTAssertEqual(peerRelay.route, .peerRelay)
        XCTAssertEqual(peerRelay.roundTripMilliseconds, 22.5)
        XCTAssertEqual(derp.route, .derp)
    }

    func testReconnectBackoffIsBoundedAndBandwidthPolicyAdaptsToRoute() {
        let reconnect = NexusReconnectPolicy(
            initialDelaySeconds: 1,
            maximumDelaySeconds: 8,
            multiplier: 2,
            jitterFraction: 0.2
        )
        XCTAssertEqual(reconnect.delaySeconds(attempt: 0, randomUnit: 0.5), 1)
        XCTAssertEqual(reconnect.delaySeconds(attempt: 3, randomUnit: 0.5), 8)
        XCTAssertEqual(reconnect.delaySeconds(attempt: 20, randomUnit: 1), 9.6, accuracy: 0.0001)

        let direct = NexusBandwidthPolicy.policy(for: .init(
            route: .direct,
            roundTripMilliseconds: 10,
            uploadBytesPerSecond: 100_000_000,
            downloadBytesPerSecond: 100_000_000,
            recentFailureRate: 0
        ))
        let relayed = NexusBandwidthPolicy.policy(for: .init(
            route: .derp,
            roundTripMilliseconds: 90,
            uploadBytesPerSecond: nil,
            downloadBytesPerSecond: nil,
            recentFailureRate: 0.1
        ))
        XCTAssertGreaterThan(direct.transferConcurrency, relayed.transferConcurrency)
        XCTAssertGreaterThan(direct.preferredChunkBytes, relayed.preferredChunkBytes)
    }

    func testQualityMonitorUsesEWMAAndTracksFailures() async {
        let monitor = NexusQualityMonitor(smoothingFactor: 0.5)
        await monitor.recordRoute(.init(route: .direct, roundTripMilliseconds: 10, description: "direct"))
        await monitor.recordRoute(.init(route: .direct, roundTripMilliseconds: 30, description: "direct"))
        await monitor.recordTransfer(bytes: 1_000, durationSeconds: 1, upload: false)
        await monitor.recordTransfer(bytes: 3_000, durationSeconds: 1, upload: false)
        await monitor.recordRequest(success: true)
        await monitor.recordRequest(success: false)
        let quality = await monitor.snapshot()

        XCTAssertEqual(quality.roundTripMilliseconds, 20)
        XCTAssertEqual(quality.downloadBytesPerSecond, 2_000)
        XCTAssertEqual(quality.recentFailureRate, 0.5)
    }

    @MainActor
    func testCoordinatorIsDormantUntilEnabledAndPairedThenHealthChecks() async throws {
        let peer = NexusTailscalePeer(
            id: "studio", nodeKey: "nodekey:studio", hostName: "Mac Studio",
            dnsName: "studio.ts.net.", operatingSystem: "macOS", addresses: ["100.64.0.3"],
            online: true, active: true, relayRegion: "sfo", currentEndpoint: nil,
            receivedBytes: 0, transmittedBytes: 0
        )
        let discovery = NexusStudioDiscoveryStub(peer: peer)
        let session = NexusRemoteSessionStub(health: Self.connectTestHealth())
        let coordinator = NexusConnectCoordinator(
            discovery: discovery,
            sessionFactory: { session },
            reconnectPolicy: .init(initialDelaySeconds: 0.01, maximumDelaySeconds: 0.02, multiplier: 2, jitterFraction: 0),
            healthIntervalSeconds: 0.05,
            pairingIsAvailable: { true }
        )

        coordinator.start(enabled: false)
        XCTAssertEqual(coordinator.state, .disabled)
        let disabledDiscoveryCount = await discovery.discoveryCount()
        XCTAssertEqual(disabledDiscoveryCount, 0)

        coordinator.start(enabled: true, preferredNodeID: "studio")
        try await Task.sleep(nanoseconds: 140_000_000)
        guard case .ready(let connectedPeer, _, _) = coordinator.state else {
            return XCTFail("expected ready, got \(coordinator.state)")
        }
        XCTAssertEqual(connectedPeer.id, "studio")
        let healthCheckCount = await session.healthCount()
        XCTAssertGreaterThanOrEqual(healthCheckCount, 1)
        coordinator.stop()
        XCTAssertEqual(coordinator.state, .disabled)
    }

    @MainActor
    func testCoordinatorDoesNotTouchNetworkWithoutPairing() async {
        let discovery = NexusStudioDiscoveryStub(peer: nil)
        let coordinator = NexusConnectCoordinator(
            discovery: discovery,
            sessionFactory: { NexusRemoteSessionStub(health: Self.connectTestHealth()) },
            pairingIsAvailable: { false }
        )

        coordinator.start(enabled: true)

        guard case .offline(let message) = coordinator.state else {
            return XCTFail("unpaired coordinator should stay offline")
        }
        XCTAssertTrue(message.contains("Pair"))
        let discoveryCount = await discovery.discoveryCount()
        XCTAssertEqual(discoveryCount, 0)
    }

    private static func connectTestHealth() -> NexusNodeHealth {
        .init(
            nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            nodeName: "Studio", hostVersion: "1", protocolMinimum: 1, protocolMaximum: 1,
            capabilities: [.health, .inference], uptimeSeconds: 60,
            totalMemoryBytes: 64 * 1_024 * 1_024 * 1_024,
            availableMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
            availableDiskBytes: 1_000_000_000, queueDepth: 0, activeJobs: 0,
            loadAverage: [0.5, 0.4, 0.3], modelInventoryDigest: Data(),
            timestampMilliseconds: NexusClock.nowMilliseconds()
        )
    }
}

private struct NexusCommandRunnerStub: NexusCommandRunning {
    let statusData: Data

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        timeoutSeconds: TimeInterval,
        maximumOutputBytes: Int
    ) async throws -> NexusCommandResult {
        .init(standardOutput: statusData, standardError: Data(), exitCode: 0)
    }
}

private actor NexusStudioDiscoveryStub: NexusStudioDiscovering {
    private let peer: NexusTailscalePeer?
    private var count = 0

    init(peer: NexusTailscalePeer?) { self.peer = peer }

    func discoverStudio(preferredNodeID: String?) async throws -> NexusTailscalePeer {
        count += 1
        guard let peer else { throw NexusConnectError.unavailable("offline") }
        return peer
    }

    func routeSample(to peer: NexusTailscalePeer) async throws -> NexusTailscaleRouteSample {
        .init(route: .direct, roundTripMilliseconds: 4, description: "direct")
    }

    func discoveryCount() -> Int { count }
}

private actor NexusRemoteSessionStub: NexusRemoteSession {
    private let currentHealth: NexusNodeHealth
    private var checks = 0

    init(health: NexusNodeHealth) { currentHealth = health }

    func connect(to peer: NexusTailscalePeer) async throws -> NexusNodeHealth { currentHealth }
    func health() async throws -> NexusNodeHealth {
        checks += 1
        return currentHealth
    }
    func disconnect() async {}
    func healthCount() -> Int { checks }
}
