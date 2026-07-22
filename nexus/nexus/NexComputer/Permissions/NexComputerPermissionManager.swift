import AppKit
import ApplicationServices
import Contacts
import CoreGraphics
import EventKit
import Foundation
import Photos

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
        let id = requirement.id.lowercased()
        let state: NexComputerPermissionState
        if id == "accessibility" || id.hasPrefix("accessibility.") {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: request] as CFDictionary
            state = AXIsProcessTrustedWithOptions(options) ? .authorized : (request ? .denied : .notDetermined)
        } else if id == "contacts" || id.hasPrefix("contacts.") {
            state = await contactsState(request: request)
        } else if id == "photos" || id.hasPrefix("photos.") {
            state = await photosState(request: request)
        } else if id == "calendar" || id.hasPrefix("calendar.") {
            state = await calendarState(request: request)
        } else if id == "screen_recording" || id.hasPrefix("screen_recording.") {
            if CGPreflightScreenCaptureAccess() {
                state = .authorized
            } else if request {
                state = CGRequestScreenCaptureAccess() ? .authorized : .denied
            } else {
                state = .notDetermined
            }
        } else if id == "full_disk_access" || id.hasPrefix("full_disk_access.") {
            // macOS intentionally offers no public API that can grant or
            // reliably preflight Full Disk Access.
            state = .unsupported
        } else if id.hasPrefix("automation.") {
            let bundleIdentifier = String(requirement.id.dropFirst("automation.".count))
            state = automationState(bundleIdentifier: bundleIdentifier, request: request)
        } else {
            // Network, app-managed files, memory, and bounded code execution
            // are enforced by Nexus policy rather than a macOS TCC prompt.
            state = .authorized
        }
        return .init(
            requirementID: requirement.id,
            state: state,
            recovery: requirement.recovery ?? Self.defaultRecovery(for: requirement.id, state: state)
        )
    }

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

    private func automationState(
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
}
