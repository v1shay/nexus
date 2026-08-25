import Foundation

enum NexComputerPermissionState: String, Codable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined = "not_determined"
    case unsupported
}

struct NexComputerPermissionStatus: Equatable, Sendable {
    let requirementID: String
    let state: NexComputerPermissionState
    let recovery: String?

    var isAuthorized: Bool { state == .authorized }
}

protocol NexComputerPermissionChecking: Sendable {
    func status(for requirement: NexComputerPermissionRequirement) async -> NexComputerPermissionStatus
    func request(for requirement: NexComputerPermissionRequirement) async -> NexComputerPermissionStatus
}

struct NexComputerPermissionFailure: LocalizedError, Equatable, Sendable {
    let status: NexComputerPermissionStatus

    var errorDescription: String? {
        "Permission \(status.requirementID) is \(status.state.rawValue)."
    }
}

actor NexComputerPermissionManager {
    private let backend: any NexComputerPermissionChecking

    init(backend: any NexComputerPermissionChecking = NexComputerSystemPermissionBackend()) {
        self.backend = backend
    }

    /// Called only when an action is actually invoked. Nexus never asks for a
    /// batch of unrelated TCC grants during startup.
    func authorize(
        _ requirements: [NexComputerPermissionRequirement],
        requestIfNeeded: Bool = true
    ) async throws {
        for requirement in requirements {
            var status = await backend.status(for: requirement)
            if status.state == .notDetermined, requestIfNeeded {
                status = await backend.request(for: requirement)
            }
            guard status.isAuthorized else {
                throw NexComputerPermissionFailure(status: status)
            }
        }
    }

    func statuses(
        for requirements: [NexComputerPermissionRequirement]
    ) async -> [NexComputerPermissionStatus] {
        var result: [NexComputerPermissionStatus] = []
        for requirement in requirements {
            result.append(await backend.status(for: requirement))
        }
        return result
    }
}

/// Adapter retained for the computer-action manifest. It delegates every TCC
/// query and prompt to NexusPermissionCoordinator; tools never own a second
/// permission state machine.
final class NexComputerSystemPermissionBackend: NexComputerPermissionChecking, @unchecked Sendable {

    func status(for requirement: NexComputerPermissionRequirement) async -> NexComputerPermissionStatus {
        await resolve(requirement, request: false)
    }

    func request(for requirement: NexComputerPermissionRequirement) async -> NexComputerPermissionStatus {
        await resolve(requirement, request: true)
    }

    private func resolve(
        _ requirement: NexComputerPermissionRequirement,
        request: Bool
    ) async -> NexComputerPermissionStatus {
        let capability = NexusPermissionCapability.from(requirementID: requirement.id)
        let result = request
            ? await NexusPermissionCoordinator.shared.request(capability)
            : await NexusPermissionCoordinator.shared.check(capability)
        let state: NexComputerPermissionState
        switch result.liveState {
        case .authorized: state = .authorized
        case .denied: state = .denied
        case .restricted: state = .restricted
        case .unsupported: state = .unsupported
        case .notDetermined, .waitingForSystemSettings, .waitingForRestart: state = .notDetermined
        }
        return .init(
            requirementID: requirement.id,
            state: state,
            recovery: result.recovery ?? requirement.recovery
        )
    }

    @MainActor
    static func automationStatus(for bundleIdentifier: String) -> NexComputerPermissionState {
        guard !bundleIdentifier.isEmpty else { return .unsupported }
        let state = NexusPermissionCoordinator.shared.state(for: .automation(bundleIdentifier))
        switch state {
        case .verified: return .authorized
        case .needsAttention: return .denied
        case .notStarted, .explaining, .requesting, .waitingForSystemSettings, .waitingForRestart:
            return .notDetermined
        }
    }

#if false
    private func contactsState(request: Bool) async -> NexComputerPermissionState {
        let current = CNContactStore.authorizationStatus(for: .contacts)
        if current == .notDetermined, request {
            do { return try await CNContactStore().requestAccess(for: .contacts) ? .authorized : .denied }
            catch { return .denied }
        }
        return Self.map(current)
    }

    private func photosState(request: Bool) async -> NexComputerPermissionState {
        var current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .notDetermined, request {
            current = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        switch current {
        case .authorized, .limited: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unsupported
        }
    }

    private func calendarState(request: Bool) async -> NexComputerPermissionState {
        var current = EKEventStore.authorizationStatus(for: .event)
        if current == .notDetermined, request {
            do {
                _ = try await EKEventStore().requestFullAccessToEvents()
                current = EKEventStore.authorizationStatus(for: .event)
            } catch {
                return .denied
            }
        }
        switch current {
        case .fullAccess, .authorized, .writeOnly: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .unsupported
        }
    }

    /// Checks a target app's Automation grant without showing a macOS prompt.
    /// Background observers use this before they decide whether an AppleEvent
    /// is safe to send; explicit tool execution still goes through `request`
    /// above and may ask the user when a durable host is installed.
    static func automationStatus(for bundleIdentifier: String) -> NexComputerPermissionState {
        automationState(bundleIdentifier: bundleIdentifier, request: false)
    }

    private static func automationState(
        bundleIdentifier: String,
        request: Bool
    ) -> NexComputerPermissionState {
        guard !bundleIdentifier.isEmpty else { return .unsupported }
        var target = AEAddressDesc()
        let bytes = Array(bundleIdentifier.utf8)
        let creationStatus = bytes.withUnsafeBytes { buffer in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                buffer.baseAddress,
                buffer.count,
                &target
            )
        }
        guard creationStatus == noErr else { return .unsupported }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            request
        )
        if status == noErr { return .authorized }
        if status == errAEEventNotPermitted { return .denied }
        return request ? .denied : .notDetermined
    }

    private static func map(_ status: CNAuthorizationStatus) -> NexComputerPermissionState {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unsupported
        }
    }

    private static func defaultRecovery(
        for id: String,
        state: NexComputerPermissionState
    ) -> String? {
        guard state != .authorized else { return nil }
        if id.lowercased().hasPrefix("automation.") {
            return "Open System Settings > Privacy & Security > Automation and allow Nexus to control the requested app."
        }
        let label = id.replacingOccurrences(of: "_", with: " ").capitalized
        return "Open System Settings > Privacy & Security > \(label) and allow Nexus."
    }
#endif
}
