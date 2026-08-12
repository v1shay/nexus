import XCTest
@testable import nexus

@MainActor
final class NexusPermissionCoordinatorTests: XCTestCase {
    private final class MockSystem: NexusPermissionSystemAPI, @unchecked Sendable {
        var statuses: [NexusPermissionCapability: NexusPermissionLiveState] = [:]
        var requests: [NexusPermissionCapability: NexusPermissionLiveState] = [:]
        private(set) var requested: [NexusPermissionCapability] = []

        func status(for capability: NexusPermissionCapability) async -> NexusPermissionLiveState {
            statuses[capability] ?? .notDetermined
        }

        func request(for capability: NexusPermissionCapability) async -> NexusPermissionLiveState {
            requested.append(capability)
            return requests[capability] ?? .notDetermined
        }
    }

    private func temporarySessionURL() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("PermissionSetup.json")
    }

    private nonisolated static func durableIdentity(_ requirement: String = "stable-development-requirement") -> NexusPermissionSigningIdentity {
        .init(bundleIdentifier: "na.nexus", requirementHash: requirement, hasCertificate: true, certificateSubject: "Apple Development: Nexus Tests", diagnostic: nil)
    }

    func testAccessibilityPromptStaysWaitingUntilLaterLiveVerification() async {
        let system = MockSystem()
        system.requests[.accessibility] = .waitingForSystemSettings
        let coordinator = NexusPermissionCoordinator(system: system, identityProvider: { Self.durableIdentity() }, fileURL: temporarySessionURL())

        await coordinator.beginSetup(selectedCapabilities: [.accessibility])
        let requested = await coordinator.request(.accessibility)

        XCTAssertEqual(requested.setupState, .waitingForSystemSettings)
        XCTAssertNotEqual(requested.setupState, .needsAttention)
        XCTAssertEqual(system.requested, [.accessibility])
    }

    func testSessionResumesAfterRestartAndPreservesLiveGrant() async {
        let url = temporarySessionURL()
        let firstSystem = MockSystem()
        firstSystem.requests[.screenRecording] = .waitingForRestart
        let first = NexusPermissionCoordinator(system: firstSystem, identityProvider: { Self.durableIdentity() }, fileURL: url)

        await first.beginSetup(selectedCapabilities: [.screenRecording])
        _ = await first.request(.screenRecording)
        XCTAssertTrue(first.prepareControlledRestart())

        let restartedSystem = MockSystem()
        restartedSystem.statuses[.screenRecording] = .authorized
        let restarted = NexusPermissionCoordinator(system: restartedSystem, identityProvider: { Self.durableIdentity() }, fileURL: url)
        await restarted.resumeAtLaunch()

        XCTAssertEqual(restarted.state(for: .screenRecording), .verified)
        XCTAssertFalse(restarted.session?.resumeAfterRestart ?? true)
    }

    func testSigningLineageMismatchFailsWithoutPrompting() async {
        let url = temporarySessionURL()
        let system = MockSystem()
        let first = NexusPermissionCoordinator(system: system, identityProvider: { Self.durableIdentity("first") }, fileURL: url)
        await first.beginSetup(selectedCapabilities: [.microphone])

        let changed = NexusPermissionCoordinator(system: system, identityProvider: { Self.durableIdentity("different") }, fileURL: url)
        let result = await changed.request(.microphone)

        XCTAssertEqual(result.setupState, .needsAttention)
        XCTAssertTrue(changed.diagnostic.contains("signing lineage changed"))
        XCTAssertEqual(system.requested, [])
    }

    func testLaunchRemovesLegacyMessagesAutomationWithoutRemovingFullDiskAccess() async {
        let system = MockSystem()
        system.statuses[.protectedResource("messages")] = .authorized
        let coordinator = NexusPermissionCoordinator(
            system: system,
            identityProvider: { Self.durableIdentity() },
            fileURL: temporarySessionURL()
        )
        await coordinator.beginSetup(selectedCapabilities: [
            .automation("com.apple.MobileSMS"),
            .protectedResource("messages")
        ])
        await coordinator.resumeAtLaunch()

        XCTAssertFalse(coordinator.setupCapabilities.contains(.automation("com.apple.MobileSMS")))
        XCTAssertEqual(coordinator.state(for: .protectedResource("messages")), .verified)
    }

    func testExistingSessionPreservesLiveGrantWhenRuntimeIdentityInspectionFails() async {
        let url = temporarySessionURL()
        let first = NexusPermissionCoordinator(
            system: MockSystem(),
            identityProvider: { Self.durableIdentity() },
            fileURL: url
        )
        await first.beginSetup(selectedCapabilities: [.microphone])

        let restartedSystem = MockSystem()
        restartedSystem.statuses[.microphone] = .authorized
        let restarted = NexusPermissionCoordinator(
            system: restartedSystem,
            identityProvider: {
                .init(
                    bundleIdentifier: "na.nexus",
                    requirementHash: "",
                    hasCertificate: false,
                    certificateSubject: "",
                    diagnostic: "Runtime certificate inspection unavailable."
                )
            },
            fileURL: url
        )

        await restarted.resumeAtLaunch()

        XCTAssertEqual(restarted.state(for: .microphone), .verified)
        XCTAssertEqual(restarted.diagnostic, "")
    }

    func testExistingSessionCanStillRequestAfterRuntimeIdentityInspectionFails() async {
        let url = temporarySessionURL()
        let first = NexusPermissionCoordinator(
            system: MockSystem(),
            identityProvider: { Self.durableIdentity() },
            fileURL: url
        )
        await first.beginSetup(selectedCapabilities: [.microphone])

        let restartedSystem = MockSystem()
        restartedSystem.requests[.microphone] = .authorized
        let restarted = NexusPermissionCoordinator(
            system: restartedSystem,
            identityProvider: {
                .init(bundleIdentifier: "na.nexus", requirementHash: "", hasCertificate: false, certificateSubject: "", diagnostic: "Runtime certificate inspection unavailable.")
            },
            fileURL: url
        )

        let result = await restarted.request(.microphone)

        XCTAssertEqual(result.setupState, .verified)
        XCTAssertEqual(restartedSystem.requested, [.microphone])
    }

    func testPersistentCertificateIdentitiesAreDurableAndAdHocIsRejected() {
        XCTAssertTrue(NexusPermissionSigningIdentity(bundleIdentifier: "na.nexus", requirementHash: "development", hasCertificate: true, certificateSubject: "Apple Development: Nexus", diagnostic: nil).isDurable)
        XCTAssertTrue(NexusPermissionSigningIdentity(bundleIdentifier: "na.nexus", requirementHash: "production", hasCertificate: true, certificateSubject: "Developer ID Application: Nexus", diagnostic: nil).isDurable)
        XCTAssertTrue(NexusPermissionSigningIdentity(bundleIdentifier: "na.nexus", requirementHash: "local", hasCertificate: true, certificateSubject: "system local code signing", diagnostic: nil).isDurable)
        XCTAssertFalse(NexusPermissionSigningIdentity(bundleIdentifier: "na.nexus", requirementHash: "", hasCertificate: false, certificateSubject: "", diagnostic: nil).isDurable)
    }

}
