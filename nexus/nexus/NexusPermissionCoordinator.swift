import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Contacts
import CoreGraphics
import CryptoKit
import EventKit
import Foundation
import Photos
import ScreenCaptureKit
import Security
import Speech
import SQLite3

/// The user-facing capability, rather than a raw TCC service. Automation is
/// deliberately per target: macOS does not provide a safe universal grant.
enum NexusPermissionCapability: Hashable, Codable, Sendable, Identifiable {
    case microphone
    case speechRecognition
    case accessibility
    case screenRecording
    case automation(String)
    case protectedResource(String)
    case contacts
    case calendar
    case photos
    case connector(String)

    var id: String {
        switch self {
        case .microphone: "microphone"
        case .speechRecognition: "speech_recognition"
        case .accessibility: "accessibility"
        case .screenRecording: "screen_recording"
        case .automation(let target): "automation.\(target)"
        case .protectedResource(let resource): "protected_resource.\(resource)"
        case .contacts: "contacts"
        case .calendar: "calendar"
        case .photos: "photos"
        case .connector(let name): "connector.\(name)"
        }
    }

    var displayName: String {
        switch self {
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .automation(let target): "Automation: \(target)"
        case .protectedResource(let resource): "Full Disk Access: \(resource.capitalized)"
        case .contacts: "Contacts"
        case .calendar: "Calendar"
        case .photos: "Photos"
        case .connector(let name): "Connector: \(name)"
        }
    }

    static let coreSetup: [Self] = [.microphone, .speechRecognition, .accessibility, .screenRecording]

    /// These are the only applications for which Nexus currently ships an
    /// Apple-event tool. macOS grants Automation per target, not globally, so
    /// an installed target gets an independent, reviewable onboarding step.
    private static let knownAutomationTargetBundleIDs = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.apple.finder",
        "com.apple.Terminal",
        "com.spotify.client"
    ]

    @MainActor
    static func defaultOnboardingCapabilities() -> [Self] {
        var capabilities = coreSetup
        capabilities += knownAutomationTargetBundleIDs.compactMap { identifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) == nil
                ? nil
                : .automation(identifier)
        }

        // Messages history is read through its local database. Do not make
        // Messages Apple Events a setup blocker: some managed Macs disallow
        // that Automation target entirely, while Full Disk Access still
        // enables safe read-only search and triage of the local history.
        // Full Disk Access has no app-request API, so include it only when a
        // concrete Nexus feature exists to be live-tested.
        let messagesDatabase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path
        if FileManager.default.fileExists(atPath: messagesDatabase) {
            capabilities.append(.protectedResource("messages"))
        }
        return capabilities
    }

    static func from(requirementID: String) -> Self {
        let identifier = requirementID.lowercased()
        if identifier == "accessibility" || identifier.hasPrefix("accessibility.") { return .accessibility }
        if identifier == "screen_recording" || identifier.hasPrefix("screen_recording.") { return .screenRecording }
        if identifier == "contacts" || identifier.hasPrefix("contacts.") { return .contacts }
        if identifier == "calendar" || identifier.hasPrefix("calendar.") { return .calendar }
        if identifier == "photos" || identifier.hasPrefix("photos.") { return .photos }
        if identifier.hasPrefix("automation.") { return .automation(String(requirementID.dropFirst("automation.".count))) }
        if identifier.hasPrefix("full_disk_access.") { return .protectedResource(String(requirementID.dropFirst("full_disk_access.".count))) }
        return .connector(requirementID)
    }
}

enum NexusPermissionSetupState: String, Codable, Sendable {
    case notStarted
    case explaining
    case requesting
    case waitingForSystemSettings
    case waitingForRestart
    case verified
    case needsAttention
}

struct NexusPermissionSetupSession: Codable, Sendable {
    var selectedCapabilities: [NexusPermissionCapability]
    var states: [NexusPermissionCapability: NexusPermissionSetupState]
    var currentCapability: NexusPermissionCapability?
    var resumeAfterRestart: Bool
    var signingRequirementHash: String
    var updatedAt: Date

    init(
        selectedCapabilities: [NexusPermissionCapability],
        signingRequirementHash: String,
        states: [NexusPermissionCapability: NexusPermissionSetupState] = [:],
        currentCapability: NexusPermissionCapability? = nil,
        resumeAfterRestart: Bool = false
    ) {
        self.selectedCapabilities = selectedCapabilities
        self.states = states
        self.currentCapability = currentCapability
        self.resumeAfterRestart = resumeAfterRestart
        self.signingRequirementHash = signingRequirementHash
        self.updatedAt = Date()
    }
}

enum NexusPermissionLiveState: Sendable, Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case waitingForSystemSettings
    case waitingForRestart
    case unsupported
}

struct NexusPermissionCheck: Sendable, Equatable {
    let capability: NexusPermissionCapability
    let liveState: NexusPermissionLiveState
    let setupState: NexusPermissionSetupState
    let recovery: String?

    var isAuthorized: Bool { liveState == .authorized && setupState == .verified }
}

struct NexusPermissionSigningIdentity: Sendable, Equatable {
    let bundleIdentifier: String
    let requirementHash: String
    let hasCertificate: Bool
    let certificateSubject: String
    let diagnostic: String?

    var isDurable: Bool {
        bundleIdentifier == "na.nexus"
            && !requirementHash.isEmpty
            && hasCertificate
    }

    static func current() -> Self {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        var dynamicCode: SecCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess, let dynamicCode else {
            return .init(bundleIdentifier: bundleIdentifier, requirementHash: "", hasCertificate: false, certificateSubject: "", diagnostic: "Nexus could not inspect its code signature.")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess, let staticCode else {
            return .init(bundleIdentifier: bundleIdentifier, requirementHash: "", hasCertificate: false, certificateSubject: "", diagnostic: "Nexus could not inspect its static code signature.")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else {
            return .init(bundleIdentifier: bundleIdentifier, requirementHash: "", hasCertificate: false, certificateSubject: "", diagnostic: "Nexus has no durable designated requirement. Use Apple Development or Developer ID signing, not ad-hoc signing.")
        }
        var requirementData: CFData?
        guard SecRequirementCopyData(requirement, [], &requirementData) == errSecSuccess, let requirementData else {
            return .init(bundleIdentifier: bundleIdentifier, requirementHash: "", hasCertificate: false, certificateSubject: "", diagnostic: "Nexus could not read its designated requirement.")
        }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        let certificates = (information as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let hasCertificate = status == errSecSuccess && !(certificates?.isEmpty ?? true)
        let certificateSubject = certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? ""
        let hash = SHA256.hash(data: requirementData as Data).map { String(format: "%02x", $0) }.joined()
        let diagnostic: String?
        if bundleIdentifier != "na.nexus" {
            diagnostic = "Nexus permission setup requires bundle identifier na.nexus."
        } else if !hasCertificate {
            diagnostic = "Nexus is ad-hoc or unidentified signed. Permission onboarding requires a certificate-backed Nexus signing lineage (Apple Development, Developer ID, or Xcode's persistent local development identity)."
        } else {
            diagnostic = nil
        }
        return .init(bundleIdentifier: bundleIdentifier, requirementHash: hash, hasCertificate: hasCertificate, certificateSubject: certificateSubject, diagnostic: diagnostic)
    }

}

protocol NexusPermissionSystemAPI: Sendable {
    func status(for capability: NexusPermissionCapability) async -> NexusPermissionLiveState
    func request(for capability: NexusPermissionCapability) async -> NexusPermissionLiveState
}

/// The only code in Nexus that talks to macOS permission APIs. Every caller
/// receives a durable capability state through `NexusPermissionCoordinator`.
final class NexusPermissionSystem: NexusPermissionSystemAPI, @unchecked Sendable {
    func status(for capability: NexusPermissionCapability) async -> NexusPermissionLiveState {
        switch capability {
        case .microphone: Self.microphoneState()
        case .speechRecognition: Self.speechState()
        case .accessibility: AXIsProcessTrusted() ? .authorized : .notDetermined
        case .screenRecording: await Self.screenCaptureState()
        case .automation(let target): await Self.automationState(target: target, request: false)
        case .protectedResource(let resource): Self.protectedResourceState(resource)
        case .contacts: Self.contactsState()
        case .calendar: Self.calendarState()
        case .photos: Self.photosState()
        case .connector: .notDetermined
        }
    }

    func request(for capability: NexusPermissionCapability) async -> NexusPermissionLiveState {
        switch capability {
        case .microphone:
            guard Self.microphoneState() == .notDetermined else { return Self.microphoneState() }
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted ? .authorized : .denied)
                }
            }
        case .speechRecognition:
            guard Self.speechState() == .notDetermined else { return Self.speechState() }
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: Self.speechState(status))
                }
            }
        case .accessibility:
            if AXIsProcessTrusted() { return .authorized }
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            // Apple documents this prompt as asynchronous. Its immediate false
            // result is never a denial and is intentionally ignored here.
            return .waitingForSystemSettings
        case .screenRecording:
            if await Self.screenCaptureState() == .authorized { return .authorized }
            _ = CGRequestScreenCaptureAccess()
            return .waitingForRestart
        case .automation(let target):
            guard await Self.ensureAutomationTargetIsRunning(target) else { return .unsupported }
            return await Self.automationState(target: target, request: true)
        case .contacts:
            let status = CNContactStore.authorizationStatus(for: .contacts)
            guard status == .notDetermined else { return Self.contactsState() }
            do { return try await CNContactStore().requestAccess(for: .contacts) ? .authorized : .denied }
            catch { return .denied }
        case .calendar:
            guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return Self.calendarState() }
            do {
                _ = try await EKEventStore().requestFullAccessToEvents()
                return Self.calendarState()
            } catch { return .denied }
        case .photos:
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined else { return Self.photosState() }
            return Self.photosState(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        case .protectedResource:
            // Full Disk Access cannot be prompted programmatically. The
            // coordinator persists its waiting state before routing the user
            // to the system-owned pane, then verifies the exact resource on a
            // later live check.
            return .waitingForSystemSettings
        case .connector:
            return .notDetermined
        }
    }

    private static func microphoneState() -> NexusPermissionLiveState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unsupported
        }
    }

    private static func speechState(_ status: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()) -> NexusPermissionLiveState {
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unsupported
        }
    }

    private static func contactsState() -> NexusPermissionLiveState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unsupported
        }
    }

    private static func calendarState() -> NexusPermissionLiveState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized, .writeOnly: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unsupported
        }
    }

    private static func photosState(_ status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)) -> NexusPermissionLiveState {
        switch status {
        case .authorized, .limited: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unsupported
        }
    }

    private static func protectedResourceState(_ resource: String) -> NexusPermissionLiveState {
        switch resource {
        case "messages":
            let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
            // Do the same class of access the Messages tool needs instead of
            // trusting the Full Disk Access checkbox or file metadata. TCC
            // may allow a stat/readability check while still denying SQLite.
            var database: OpaquePointer?
            guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let database else {
                if database != nil { sqlite3_close(database) }
                return .denied
            }
            defer { sqlite3_close(database) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &statement, nil) == SQLITE_OK,
                  let statement else { return .denied }
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            return (result == SQLITE_ROW || result == SQLITE_DONE) ? .authorized : .denied
        default: return .unsupported
        }
    }

    /// TCC cannot show a useful Automation consent sheet for an application
    /// that is not running. Opening the target is part of an explicit user
    /// request from the Allow button; it is not an attempt to bypass consent.
    @MainActor
    private static func ensureAutomationTargetIsRunning(_ target: String) async -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == target }) {
            return true
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    /// This performs a real ScreenCaptureKit screenshot capability test. The
    /// image is discarded immediately; no Settings checkbox is trusted.
    private static func screenCaptureState() async -> NexusPermissionLiveState {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return .unsupported }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: SCStreamConfiguration())
            return .authorized
        } catch {
            return .notDetermined
        }
    }

    private static func automationState(target: String, request: Bool) async -> NexusPermissionLiveState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var address = AEAddressDesc()
                let bytes = Array(target.utf8)
                let creation = bytes.withUnsafeBytes { buffer in
                    AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &address)
                }
                guard creation == noErr else { continuation.resume(returning: .unsupported); return }
                defer { AEDisposeDesc(&address) }
                // A concrete, harmless core Apple event gives macOS an exact
                // target/event pair to authorize. Wildcards can be reported
                // as "not permitted" without ever presenting the target's
                // Automation alert on some macOS releases.
                let status = AEDeterminePermissionToAutomateTarget(
                    &address,
                    AEEventClass(kCoreEventClass),
                    AEEventID(kAEGetData),
                    request
                )
                if status == noErr { continuation.resume(returning: .authorized) }
                else if status == errAEEventNotPermitted { continuation.resume(returning: .denied) }
                else { continuation.resume(returning: request ? .waitingForSystemSettings : .notDetermined) }
            }
        }
    }
}

@MainActor
final class NexusPermissionCoordinator: ObservableObject {
    static let shared = NexusPermissionCoordinator()

    @Published private(set) var session: NexusPermissionSetupSession?
    @Published private(set) var diagnostic = ""
    @Published private(set) var isReadyForOnboarding = false

    private let system: any NexusPermissionSystemAPI
    private let identityProvider: @Sendable () -> NexusPermissionSigningIdentity
    private let fileURL: URL

    init(
        system: any NexusPermissionSystemAPI = NexusPermissionSystem(),
        identityProvider: @escaping @Sendable () -> NexusPermissionSigningIdentity = { NexusPermissionSigningIdentity.current() },
        fileURL: URL? = nil
    ) {
        self.system = system
        self.identityProvider = identityProvider
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nexus", isDirectory: true)
        self.fileURL = fileURL ?? support.appendingPathComponent("PermissionSetup.json")
        load()
    }

    var setupCapabilities: [NexusPermissionCapability] {
        session?.selectedCapabilities ?? NexusPermissionCapability.defaultOnboardingCapabilities()
    }

    func state(for capability: NexusPermissionCapability) -> NexusPermissionSetupState { session?.states[capability] ?? .notStarted }
    func isVerified(_ capability: NexusPermissionCapability) -> Bool { state(for: capability) == .verified }

    func resumeAtLaunch() async {
        // A code-signature inspection failure must never erase or hide a real
        // macOS grant. TCC is the source of truth for already-authorized
        // capabilities, so retain and recheck the saved session even when a
        // development launch cannot expose its certificate chain to Security.
        let hasSavedSession = session != nil
        guard validateSigningIdentity(allowExistingSession: hasSavedSession) else { return }
        guard var session else { isReadyForOnboarding = true; return }
        // Older sessions included Messages Automation. That target is not
        // available on this Mac class and must not hold up Messages history
        // search, which is separately verified through Full Disk Access.
        session.selectedCapabilities.removeAll { capability in
            if case .automation("com.apple.MobileSMS") = capability { return true }
            return false
        }
        session.states.removeValue(forKey: .automation("com.apple.MobileSMS"))
        for capability in NexusPermissionCapability.defaultOnboardingCapabilities() where !session.selectedCapabilities.contains(capability) {
            session.selectedCapabilities.append(capability)
            session.states[capability] = .notStarted
        }
        for capability in session.selectedCapabilities {
            let live = await system.status(for: capability)
            session.states[capability] = Self.setupState(from: live, previous: session.states[capability] ?? .notStarted)
        }
        session.currentCapability = session.selectedCapabilities.first { session.states[$0] != .verified }
        session.resumeAfterRestart = false
        session.updatedAt = Date()
        self.session = session
        persist()
        isReadyForOnboarding = true
    }

    func beginSetup(selectedCapabilities: [NexusPermissionCapability]? = nil) async {
        guard validateSigningIdentity() else { return }
        let identity = identityProvider()
        var unique: [NexusPermissionCapability] = []
        for capability in (selectedCapabilities ?? NexusPermissionCapability.defaultOnboardingCapabilities()) where !unique.contains(capability) { unique.append(capability) }
        session = .init(selectedCapabilities: unique, signingRequirementHash: identity.requirementHash, states: Dictionary(uniqueKeysWithValues: unique.map { ($0, .notStarted) }), currentCapability: unique.first)
        persist()
        await resumeAtLaunch()
    }

    /// Starts (or resumes) setup and advances exactly one capability. This
    /// keeps macOS prompts deliberate and ordered instead of presenting a
    /// burst of unrelated privacy dialogs.
    func startOrContinueSetup() async {
        if session == nil {
            await beginSetup()
        } else {
            await resumeAtLaunch()
        }
        guard let next = session?.currentCapability else { return }
        _ = await request(next)
    }

    /// Requests every unresolved Automation target one at a time. This is a
    /// convenience flow only: TCC still presents and records each target as
    /// a distinct user decision, because macOS has no universal Automation
    /// grant.
    func requestRemainingAutomationApprovals() async {
        guard validateSigningIdentity(allowExistingSession: session != nil) else { return }
        if session == nil {
            await beginSetup()
        } else {
            await resumeAtLaunch()
        }
        let pendingTargets = setupCapabilities.filter { capability in
            guard case .automation = capability else { return false }
            return !isVerified(capability)
        }
        for capability in pendingTargets {
            _ = await request(capability)
        }
    }

    func request(_ capability: NexusPermissionCapability) async -> NexusPermissionCheck {
        guard validateSigningIdentity(allowExistingSession: session != nil) else { return .init(capability: capability, liveState: .unsupported, setupState: .needsAttention, recovery: diagnostic) }
        if session == nil { await beginSetup(selectedCapabilities: [capability]) }
        ensureSelected(capability)
        update(capability, to: .requesting)
        let live = await system.request(for: capability)
        let setup: NexusPermissionSetupState
        switch live {
        case .authorized: setup = .verified
        case .waitingForSystemSettings: setup = .waitingForSystemSettings
        case .waitingForRestart: setup = .waitingForRestart
        case .notDetermined: setup = .waitingForSystemSettings
        case .denied, .restricted, .unsupported: setup = .needsAttention
        }
        update(capability, to: setup)
        if case .protectedResource = capability, setup == .waitingForSystemSettings {
            // `update` above atomically persisted the resume state before
            // opening the system-owned Full Disk Access pane.
            openSystemSettings(for: capability)
        }
        if case .automation = capability, setup == .needsAttention {
            // A previously denied Automation grant cannot show the TCC alert
            // again. Route directly to the per-target Automation pane.
            openSystemSettings(for: capability)
        }
        return .init(capability: capability, liveState: live, setupState: setup, recovery: recovery(for: capability, state: setup))
    }

    func check(_ capability: NexusPermissionCapability) async -> NexusPermissionCheck {
        guard validateSigningIdentity(allowExistingSession: session != nil) else { return .init(capability: capability, liveState: .unsupported, setupState: .needsAttention, recovery: diagnostic) }
        let live = await system.status(for: capability)
        let setup = Self.setupState(from: live, previous: state(for: capability))
        if session != nil { ensureSelected(capability); update(capability, to: setup) }
        return .init(capability: capability, liveState: live, setupState: setup, recovery: recovery(for: capability, state: setup))
    }

    func openSystemSettings(for capability: NexusPermissionCapability) {
        guard validateSigningIdentity(allowExistingSession: session != nil) else { return }
        ensureSelected(capability)
        update(capability, to: capability == .screenRecording ? .waitingForRestart : .waitingForSystemSettings)
        let anchor: String?
        switch capability {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .automation: anchor = "Privacy_Automation"
        case .protectedResource: anchor = "Privacy_AllFiles"
        default: anchor = nil
        }
        guard let anchor, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Full Disk Access is intentionally user-controlled. This opens the
    /// exact currently-running Nexus.app so the user can select it after
    /// clicking `+` in the Full Disk Access pane; Nexus never adds itself.
    func revealCurrentAppForFullDiskAccess() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func prepareControlledRestart() -> Bool {
        guard validateSigningIdentity(allowExistingSession: session != nil), state(for: .screenRecording) == .waitingForRestart, var session else { return false }
        session.resumeAfterRestart = true
        session.updatedAt = Date()
        self.session = session
        persist()
        return true
    }

    func restartToFinishScreenRecording() {
        guard prepareControlledRestart(), let appURL = Bundle.main.bundleURL as URL? else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, _ in }
        NSApp.terminate(nil)
    }

    func statusMessage() -> String {
        if !diagnostic.isEmpty { return diagnostic }
        guard let session else { return "Permissions have not been set up." }
        let unfinished = session.selectedCapabilities.filter { session.states[$0] != .verified }
        return unfinished.isEmpty ? "All selected Nexus capabilities are live-verified." : "Nexus is waiting for \(unfinished.first?.displayName ?? "permission") setup."
    }

    /// Validates identity before a *new* permission request. Existing TCC
    /// grants are never discarded merely because Security.framework cannot
    /// inspect an Xcode-local build's certificate chain at runtime.
    private func validateSigningIdentity(allowExistingSession: Bool = false) -> Bool {
        let identity = identityProvider()
        guard identity.isDurable else {
            guard allowExistingSession, session != nil,
                  identity.bundleIdentifier == "na.nexus" else {
                diagnostic = identity.diagnostic ?? "Nexus signing identity is not durable."
                isReadyForOnboarding = false
                return false
            }
            // The running process has the correct bundle ID and its live TCC
            // checks will decide capability state. Do not surface an error
            // that contradicts successfully verified permissions.
            diagnostic = ""
            return true
        }
        if let session,
           !session.signingRequirementHash.isEmpty,
           !identity.requirementHash.isEmpty,
           session.signingRequirementHash != identity.requirementHash {
            diagnostic = "Nexus signing lineage changed. Existing macOS grants are not assumed valid; install a build signed by the original certificate lineage."
            isReadyForOnboarding = false
            return false
        }
        diagnostic = ""
        return true
    }

    private func ensureSelected(_ capability: NexusPermissionCapability) {
        guard var session else { return }
        if !session.selectedCapabilities.contains(capability) { session.selectedCapabilities.append(capability) }
        if session.states[capability] == nil { session.states[capability] = .notStarted }
        if session.currentCapability == nil { session.currentCapability = capability }
        session.updatedAt = Date()
        self.session = session
        persist()
    }

    private func update(_ capability: NexusPermissionCapability, to state: NexusPermissionSetupState) {
        guard var session else { return }
        session.states[capability] = state
        session.currentCapability = session.selectedCapabilities.first { session.states[$0] != .verified }
        session.updatedAt = Date()
        self.session = session
        persist()
    }

    private static func setupState(from live: NexusPermissionLiveState, previous: NexusPermissionSetupState) -> NexusPermissionSetupState {
        switch live {
        case .authorized: .verified
        case .waitingForRestart: .waitingForRestart
        case .waitingForSystemSettings: .waitingForSystemSettings
        case .notDetermined:
            switch previous {
            case .requesting, .waitingForSystemSettings, .waitingForRestart: .needsAttention
            default: .notStarted
            }
        case .denied, .restricted, .unsupported: .needsAttention
        }
    }

    private func recovery(for capability: NexusPermissionCapability, state: NexusPermissionSetupState) -> String? {
        guard state != .verified else { return nil }
        if capability == .screenRecording && state == .waitingForRestart { return "macOS saved the Screen Recording approval. Restart Nexus once to activate it." }
        if case .automation(let target) = capability { return "Allow Nexus to control \(target) in System Settings > Privacy & Security > Automation. macOS grants this independently from other apps." }
        if case .protectedResource(let resource) = capability { return "Full Disk Access is user-controlled by macOS. In the pane, click +, choose this exact Nexus.app, enable it, then return here and Refresh. Nexus will live-check \(resource)." }
        return "Continue Nexus setup and allow \(capability.displayName) in macOS Privacy & Security."
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), let loaded = try? JSONDecoder().decode(NexusPermissionSetupSession.self, from: data) else { return }
        session = loaded
    }

    private func persist() {
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum NexusScreenCapture {
    nonisolated static var hasAccess: Bool {
        MainActor.assumeIsolated { NexusPermissionCoordinator.shared.isVerified(.screenRecording) }
    }

    @MainActor
    static func requestAccess(prompt: Bool = false) {
        guard prompt else { return }
        Task { _ = await NexusPermissionCoordinator.shared.request(.screenRecording) }
    }

    @MainActor
    static func openScreenRecordingSettings() {
        NexusPermissionCoordinator.shared.openSystemSettings(for: .screenRecording)
    }

    @MainActor
    static func captureCurrentScreen() async -> NexusScreenAttachment? {
        let status = await NexusPermissionCoordinator.shared.check(.screenRecording)
        guard status.liveState == .authorized else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: SCStreamConfiguration())
            let source = NSImage(cgImage: image, size: .init(width: image.width, height: image.height))
            let longestEdge = CGFloat(max(image.width, image.height))
            let scale = min(1, 1_920 / max(1, longestEdge))
            let targetSize = NSSize(width: max(1, CGFloat(image.width) * scale), height: max(1, CGFloat(image.height) * scale))
            let target = NSImage(size: targetSize)
            target.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: NSRect(origin: .zero, size: targetSize))
            target.unlockFocus()
            guard let tiff = target.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.68]) else { return nil }
            return .init(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg")
        } catch {
            return nil
        }
    }
}
