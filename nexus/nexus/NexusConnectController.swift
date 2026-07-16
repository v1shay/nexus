import AppKit
import Combine
import CryptoKit
import Foundation

enum NexusConnectRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case client
    case studioHost

    var id: String { rawValue }
    var title: String { self == .client ? "Use Mac Studio" : "This is the Mac Studio" }
    var vaultRole: NexusNodeRole { self == .client ? .client : .studioHost }
}

enum NexusConnectDisplayState: Equatable, Sendable {
    case off
    case needsPairing
    case discovering
    case connecting(String)
    case ready(name: String, memoryGB: Int, roundTripMilliseconds: Double?)
    case hosting
    case reconnecting(String)
    case failed(String)

    var statusText: String {
        switch self {
        case .off: "Off — Nexus is using this Mac"
        case .needsPairing: "Pairing code required"
        case .discovering: "Finding your Mac Studio…"
        case .connecting(let name): "Connecting to \(name)…"
        case .ready(let name, let memoryGB, let rtt):
            if let rtt { "Connected to \(name) · \(memoryGB) GB · \(Int(rtt.rounded())) ms" }
            else { "Connected to \(name) · \(memoryGB) GB" }
        case .hosting: "Studio host is ready on Tailscale"
        case .reconnecting(let detail): "Reconnecting · \(detail)"
        case .failed(let detail): detail
        }
    }
}

enum NexusPairingCode {
    private static let prefix = "NX1"

    static func generate() throws -> (material: NexusPairingMaterial, code: String) {
        let material = try NexusPairingMaterial.fresh()
        return (material, encode(material))
    }

    static func encode(_ material: NexusPairingMaterial) -> String {
        let secret = base64URL(material.secret)
        let checksum = base64URL(Data(SHA256.hash(data: Data("\(prefix).\(secret)".utf8))).prefix(6))
        return "\(prefix).\(secret).\(checksum)"
    }

    static func decode(_ code: String) throws -> NexusPairingMaterial {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == prefix,
              let secret = dataFromBase64URL(parts[1]), secret.count == 32 else {
            throw NexusConnectError.authenticationFailed
        }
        let expected = base64URL(Data(SHA256.hash(data: Data("\(prefix).\(parts[1])".utf8))).prefix(6))
        guard parts[2] == expected else { throw NexusConnectError.authenticationFailed }
        return try NexusPairingMaterial(secret: secret)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func dataFromBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

@MainActor
final class NexusConnectController: ObservableObject {
    static let shared = NexusConnectController()

    @Published private(set) var state: NexusConnectDisplayState = .off
    @Published private(set) var role: NexusConnectRole
    @Published private(set) var enabled: Bool
    @Published private(set) var isPaired = false
    @Published var pairingCode = ""
    @Published var setupMessage = ""

    var shouldUseStudio: Bool { enabled && role == .client && isPaired }
    var remoteMemoryGB: Int? {
        guard case .ready(_, let memoryGB, _) = state else { return nil }
        return memoryGB
    }

    private let defaults: UserDefaults
    private let clientVault: NexusIdentityVault
    private let hostVault: NexusIdentityVault
    private let remoteClient: NexusRemoteClientSession
    private let router: NexusWorkloadRouter
    private let coordinator: NexusConnectCoordinator
    private var hostListener: NexusConnectHostListener?
    private var hostStartTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private let enabledKey = "nexus.connect.enabled"
    private let roleKey = "nexus.connect.role"
    private let preferredNodeKey = "nexus.connect.preferred-node"
    private let localNodeIDKey = "nexus.connect.local-node-id"

    init(
        defaults: UserDefaults = .standard,
        secretStore: NexusSecretStore = NexusKeychainSecretStore()
    ) {
        self.defaults = defaults
        let suggestedRole = Self.suggestedRole()
        role = defaults.string(forKey: roleKey).flatMap(NexusConnectRole.init(rawValue:)) ?? suggestedRole
        enabled = defaults.bool(forKey: enabledKey)
        clientVault = NexusIdentityVault(store: secretStore, role: .client)
        hostVault = NexusIdentityVault(store: secretStore, role: .studioHost)
        remoteClient = NexusRemoteClientSession(vault: clientVault)

        let nodeID: UUID
        if let saved = defaults.string(forKey: localNodeIDKey).flatMap(UUID.init(uuidString:)) {
            nodeID = saved
        } else {
            nodeID = UUID()
            defaults.set(nodeID.uuidString, forKey: localNodeIDKey)
        }
        let localServices = NexusHostServiceExecutor(nodeID: nodeID, nodeName: Host.current().localizedName ?? "This Mac")
        let local = NexusLocalWorkloadExecutor(services: localServices)
        router = NexusWorkloadRouter(local: local, remote: remoteClient, preference: .automatic)
        coordinator = NexusConnectCoordinator(
            discovery: NexusTailscaleDiscovery(),
            sessionFactory: { [remoteClient] in remoteClient },
            pairingIsAvailable: { [clientVault] in (try? clientVault.loadPairing()) != nil }
        )
        isPaired = Self.hasPairing(role: role, clientVault: clientVault, hostVault: hostVault)

        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &cancellables)
    }

    func start() {
        restart()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: enabledKey)
        restart()
    }

    func setRole(_ role: NexusConnectRole) {
        guard self.role != role else { return }
        self.role = role
        defaults.set(role.rawValue, forKey: roleKey)
        isPaired = Self.hasPairing(role: role, clientVault: clientVault, hostVault: hostVault)
        pairingCode = ""
        setupMessage = ""
        restart()
    }

    func createPairingCode() {
        do {
            let generated = try NexusPairingCode.generate()
            try vault(for: role).savePairing(generated.material)
            pairingCode = generated.code
            isPaired = true
            setupMessage = "Copy this code once to Nexus on the other Mac. It is the app-level secret."
            restart()
        } catch {
            setupMessage = error.localizedDescription
        }
    }

    func applyPairingCode() {
        do {
            let material = try NexusPairingCode.decode(pairingCode)
            try vault(for: role).savePairing(material)
            isPaired = true
            setupMessage = "Pairing saved securely in Keychain."
            restart()
        } catch {
            setupMessage = "That pairing code is invalid or damaged."
        }
    }

    func copyPairingCode() {
        guard !pairingCode.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingCode, forType: .string)
        setupMessage = "Pairing code copied."
    }

    func unpair() {
        try? vault(for: role).removePairing()
        isPaired = false
        pairingCode = ""
        setupMessage = "Pairing removed."
        restart()
    }

    func response(
        model: LocalModel,
        prompt: String,
        onDelta: @escaping @Sendable (String, String) async -> Void
    ) async throws -> String {
        let request = try NexusWorkloadRequest(
            kind: .inference,
            priority: .interactive,
            retrySafety: .idempotent,
            payload: NexusInferencePayload(
                runtime: model.backend == .ollama ? .ollama : .lmStudio,
                model: model.identifier,
                messages: [.init(role: "user", content: prompt)],
                temperature: nil,
                maximumTokens: nil
            )
        )
        let stream = try await router.events(for: request)
        var answer = ""
        for try await event in stream {
            if event.kind == .token {
                let delta = try event.decodePayload(NexusTextDeltaPayload.self)
                answer = delta.accumulated ?? answer + delta.delta
                await onDelta(delta.delta, answer)
            } else if event.kind == .result {
                answer = try event.decodePayload(NexusTextDeltaPayload.self).accumulated ?? answer
            }
        }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NexusConnectError.requestFailed("Nexus received an empty model response.")
        }
        return answer
    }

    func pullModel(
        _ model: LocalModel,
        onProgress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws {
        guard shouldUseStudio else { throw NexusConnectError.unavailable("Nexus Connect is not enabled") }
        let request = try NexusWorkloadRequest(
            kind: .modelPull,
            priority: .utility,
            retrySafety: .resumable,
            payload: NexusModelPullPayload(
                runtime: model.backend == .ollama ? .ollama : .lmStudio,
                model: model.identifier,
                quantization: model.quantization
            )
        )
        // Model placement is intentionally remote-only. Falling back here could
        // unexpectedly put a 120B+ model on the MacBook Air.
        let stream = try await remoteClient.events(for: request)
        for try await event in stream where event.kind == .progress {
            let progress = try event.decodePayload(NexusProgressPayload.self)
            await onProgress(.init(
                completedBytes: progress.completedBytes,
                totalBytes: progress.totalBytes,
                status: progress.status
            ))
        }
    }

    func installedStudioModels(runtime: NexusRuntimeKind? = nil) async throws -> [NexusModelDescriptor] {
        guard shouldUseStudio else { return [] }
        let request = try NexusWorkloadRequest(
            kind: .modelList,
            retrySafety: .idempotent,
            payload: NexusModelListPayload(runtime: runtime)
        )
        let stream = try await remoteClient.events(for: request)
        for try await event in stream where event.kind == .result {
            return try event.decodePayload(NexusModelInventoryPayload.self).models
        }
        return []
    }

    func shutdown() {
        hostStartTask?.cancel()
        hostListener?.stop()
        coordinator.stop()
        Task { await remoteClient.disconnect() }
    }

    private func restart() {
        hostStartTask?.cancel()
        hostStartTask = nil
        hostListener?.stop()
        hostListener = nil
        coordinator.stop()
        isPaired = Self.hasPairing(role: role, clientVault: clientVault, hostVault: hostVault)

        guard enabled else { state = .off; return }
        guard isPaired else { state = .needsPairing; return }
        switch role {
        case .client:
            state = .discovering
            coordinator.start(
                enabled: true,
                preferredNodeID: defaults.string(forKey: preferredNodeKey)
            )
        case .studioHost:
            startHosting()
        }
    }

    private func startHosting() {
        do {
            let identity = try hostVault.loadOrCreateIdentity()
            let executor = NexusHostServiceExecutor(nodeID: identity.deviceID)
            let listener = NexusConnectHostListener(vault: hostVault, executor: executor)
            hostListener = listener
            state = .connecting("Tailscale")
            hostStartTask = Task { [weak self] in
                do {
                    try await listener.start()
                    guard !Task.isCancelled else { listener.stop(); return }
                    self?.state = .hosting
                } catch {
                    self?.state = .failed("Studio host could not start: \(error.localizedDescription)")
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func apply(_ lifecycle: NexusConnectLifecycleState) {
        guard enabled, role == .client else { return }
        switch lifecycle {
        case .disabled: state = .off
        case .discovering: state = .discovering
        case .connecting(let peer), .authenticating(let peer): state = .connecting(peer.hostName)
        case .ready(let peer, let health, let quality):
            defaults.set(peer.id, forKey: preferredNodeKey)
            state = .ready(
                name: health.nodeName,
                memoryGB: max(1, Int(health.totalMemoryBytes / 1_073_741_824)),
                roundTripMilliseconds: quality.roundTripMilliseconds
            )
        case .reconnecting(let message, _): state = .reconnecting(message)
        case .offline(let message): state = .failed(message)
        }
    }

    private func vault(for role: NexusConnectRole) -> NexusIdentityVault {
        role == .client ? clientVault : hostVault
    }

    private static func hasPairing(
        role: NexusConnectRole,
        clientVault: NexusIdentityVault,
        hostVault: NexusIdentityVault
    ) -> Bool {
        let vault = role == .client ? clientVault : hostVault
        return (try? vault.loadPairing()) != nil
    }

    private static func suggestedRole() -> NexusConnectRole {
        let name = Host.current().localizedName?.lowercased() ?? ""
        return name.contains("studio") ? .studioHost : .client
    }
}
