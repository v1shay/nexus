import AppKit
import Combine
import CryptoKit
import Foundation

enum NexusConnectRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case client
    case studioHost

    var id: String { rawValue }
    var title: String { self == .client ? "Use paired Macs" : "Offer this Mac" }
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
        case .discovering: "Finding saved Macs…"
        case .connecting(let name): "Connecting to \(name)…"
        case .ready(let name, let memoryGB, let rtt):
            if let rtt { "Connected to \(name) · \(memoryGB) GB · \(Int(rtt.rounded())) ms" }
            else { "Connected to \(name) · \(memoryGB) GB" }
        case .hosting: "This Mac's background host is ready on Tailscale"
        case .reconnecting(let detail): "Reconnecting · \(detail)"
        case .failed(let detail): detail
        }
    }
}

private struct NexusConnectRestoredTrust: Sendable {
    let pairedNodes: [NexusPairedNode]
    let authorizedClients: [NexusAuthorizedClient]
    let isPaired: Bool
}

struct NexusPairingInvitation: Codable, Equatable, Sendable {
    let invitationID: UUID
    let hostNodeID: UUID
    let hostSigningPublicKey: Data
    let secret: Data
    let displayName: String
    let endpoint: String
    let tailscaleNodeID: String?
    let protocolRange: NexusProtocolVersionRange

    init(
        invitationID: UUID,
        hostNodeID: UUID,
        hostSigningPublicKey: Data,
        secret: Data,
        displayName: String,
        endpoint: String,
        tailscaleNodeID: String? = nil,
        protocolRange: NexusProtocolVersionRange
    ) {
        self.invitationID = invitationID
        self.hostNodeID = hostNodeID
        self.hostSigningPublicKey = hostSigningPublicKey
        self.secret = secret
        self.displayName = displayName
        self.endpoint = endpoint
        self.tailscaleNodeID = tailscaleNodeID
        self.protocolRange = protocolRange
    }
}

enum NexusPairingCode {
    private static let legacyPrefix = "NX1"
    private static let invitationPrefix = "NX2"

    static func generate() throws -> (material: NexusPairingMaterial, code: String) {
        let material = try NexusPairingMaterial.fresh()
        return (material, encode(material))
    }

    static func generateInvitation(
        identity: NexusDeviceIdentity,
        displayName: String,
        endpoint: String,
        tailscaleNodeID: String? = nil
    ) throws -> (material: NexusPairingMaterial, invitation: NexusPairingInvitation, code: String) {
        let invitationID = UUID()
        let material = try NexusPairingMaterial.fresh(pairingID: invitationID)
        let invitation = NexusPairingInvitation(
            invitationID: invitationID,
            hostNodeID: identity.deviceID,
            hostSigningPublicKey: identity.signingPublicKey,
            secret: material.secret,
            displayName: displayName,
            endpoint: endpoint,
            tailscaleNodeID: tailscaleNodeID,
            protocolRange: .local
        )
        let payload = try NexusPayloadCoder.encoder.encode(invitation)
        let encoded = base64URL(payload)
        return (material, invitation, "\(invitationPrefix).\(encoded).\(checksum(prefix: invitationPrefix, payload: encoded))")
    }

    static func encode(_ material: NexusPairingMaterial) -> String {
        let secret = base64URL(material.secret)
        return "\(legacyPrefix).\(secret).\(checksum(prefix: legacyPrefix, payload: secret))"
    }

    static func decode(_ code: String) throws -> NexusPairingMaterial {
        let parts = components(code)
        guard parts.count == 3, parts[0] == legacyPrefix,
              parts[2] == checksum(prefix: legacyPrefix, payload: parts[1]),
              let secret = dataFromBase64URL(parts[1]), secret.count == 32 else {
            throw NexusConnectError.authenticationFailed
        }
        return try NexusPairingMaterial(secret: secret)
    }

    static func decodeInvitation(_ code: String) throws -> NexusPairingInvitation {
        let parts = components(code)
        guard parts.count == 3, parts[0] == invitationPrefix,
              parts[2] == checksum(prefix: invitationPrefix, payload: parts[1]),
              let payload = dataFromBase64URL(parts[1]) else {
            throw NexusConnectError.authenticationFailed
        }
        let invitation = try NexusPayloadCoder.decoder.decode(NexusPairingInvitation.self, from: payload)
        guard invitation.secret.count == 32,
              invitation.hostSigningPublicKey.count == 32,
              invitation.protocolRange.isValid else {
            throw NexusConnectError.authenticationFailed
        }
        return invitation
    }

    static func isInvitation(_ code: String) -> Bool {
        components(code).first == invitationPrefix
    }

    private static func components(_ code: String) -> [String] {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func checksum(prefix: String, payload: String) -> String {
        base64URL(Data(SHA256.hash(data: Data("\(prefix).\(payload)".utf8))).prefix(6))
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
    @Published private(set) var pairedNodes: [NexusPairedNode] = []
    @Published private(set) var authorizedClients: [NexusAuthorizedClient] = []
    @Published private(set) var modelRoute: NexusModelRoute
    @Published private(set) var downloadTargets: Set<NexusDownloadTarget>
    @Published var pairingCode = ""
    @Published var setupMessage = ""

    /// Kept for source compatibility while callers migrate to `modelRoute`.
    var shouldUseStudio: Bool {
        enabled && role == .client && modelRoute != .thisMac && !pairedNodes.isEmpty
    }

    let workloads: NexusUnifiedWorkloadAPI

    var remoteMemoryGB: Int? {
        let online = pairedNodes.filter { $0.status == .online }
        switch modelRoute {
        case .pairedNode(let id):
            return online.first(where: { $0.id == id })?.totalMemoryBytes.map(Self.gigabytes)
        case .automatic:
            return online.compactMap(\.totalMemoryBytes).max().map(Self.gigabytes)
        case .thisMac:
            return nil
        }
    }

    private let defaults: UserDefaults
    private let clientVault: NexusIdentityVault
    private let hostVault: NexusIdentityVault
    private let hostTrust: NexusHostTrustStore
    private let roster: NexusPairedNodeStore
    private let discovery: any NexusNodeDiscovering
    private let router: NexusMultiNodeWorkloadRouter
    private let coordinator: NexusPairedNodeCoordinator
    private let persistentHost: any NexusPersistentHostManaging
    private var hostStartTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private let enabledKey = "nexus.connect.enabled"
    private let roleKey = "nexus.connect.role"
    private let preferredNodeKey = "nexus.connect.preferred-node"
    private let localNodeIDKey = "nexus.connect.local-node-id"
    private let modelRouteKey = "nexus.connect.model-route.v2"
    private let downloadTargetsKey = "nexus.connect.download-targets.v2"

    init(
        defaults: UserDefaults = .standard,
        secretStore: NexusSecretStore = NexusKeychainSecretStore(),
        discovery: any NexusNodeDiscovering = NexusTailscaleDiscovery(),
        persistentHost: any NexusPersistentHostManaging = NexusConnectHostManager()
    ) {
        self.defaults = defaults
        role = defaults.string(forKey: roleKey).flatMap(NexusConnectRole.init(rawValue:)) ?? Self.suggestedRole()
        enabled = defaults.bool(forKey: enabledKey)
        modelRoute = Self.restoreRoute(from: defaults.data(forKey: modelRouteKey))
        downloadTargets = Self.restoreDownloadTargets(from: defaults.data(forKey: downloadTargetsKey))

        let clientVault = NexusIdentityVault(store: secretStore, role: .client)
        let hostVault = NexusIdentityVault(store: secretStore, role: .studioHost)
        let hostTrust = NexusHostTrustStore(secretStore: secretStore)
        let roster = NexusPairedNodeStore(secretStore: secretStore, scope: .client)
        self.clientVault = clientVault
        self.hostVault = hostVault
        self.hostTrust = hostTrust
        self.roster = roster
        self.discovery = discovery
        self.persistentHost = persistentHost

        // Keychain reads can require macOS to resolve or display an access
        // prompt. Never make app launch, the Notch, or nexusctl wait on that
        // work; restore the exact same persisted trust state in the
        // background and reconnect when it becomes available.
        pairedNodes = []
        authorizedClients = []

        let localNodeID: UUID
        if let saved = defaults.string(forKey: localNodeIDKey).flatMap(UUID.init(uuidString:)) {
            localNodeID = saved
        } else {
            localNodeID = UUID()
            defaults.set(localNodeID.uuidString, forKey: localNodeIDKey)
        }
        let localServices = NexusHostServiceExecutor(
            nodeID: localNodeID,
            nodeName: Host.current().localizedName ?? "This Mac"
        )
        let local = NexusLocalWorkloadExecutor(services: localServices)
        let router = NexusMultiNodeWorkloadRouter(local: local)
        self.router = router
        workloads = NexusUnifiedWorkloadAPI(executor: router)
        coordinator = NexusPairedNodeCoordinator(
            discovery: discovery,
            roster: roster,
            sessionFactory: { node in
                NexusRemoteClientSession(vault: NexusPairedNodeCredentials(
                    identityVault: clientVault,
                    roster: roster,
                    nodeID: node.id
                ))
            }
        )
        isPaired = false

        coordinator.$nodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply(nodes: $0) }
            .store(in: &cancellables)
        Task { await router.setRoute(modelRoute) }

        let roleAtLaunch = role
        let preferredTailscaleID = defaults.string(forKey: preferredNodeKey)
        Task { @MainActor [weak self, roster, clientVault, hostVault, hostTrust] in
            let restored = await Task.detached {
                Self.restoreKeychainBackedTrust(
                    role: roleAtLaunch,
                    preferredTailscaleID: preferredTailscaleID,
                    roster: roster,
                    clientVault: clientVault,
                    hostVault: hostVault,
                    hostTrust: hostTrust
                )
            }.value
            guard let self else { return }
            self.pairedNodes = restored.pairedNodes
            self.authorizedClients = restored.authorizedClients
            self.isPaired = restored.isPaired
            if self.enabled { self.restart() }
        }
    }

    nonisolated private static func restoreKeychainBackedTrust(
        role: NexusConnectRole,
        preferredTailscaleID: String?,
        roster: NexusPairedNodeStore,
        clientVault: NexusIdentityVault,
        hostVault: NexusIdentityVault,
        hostTrust: NexusHostTrustStore
    ) -> NexusConnectRestoredTrust {
        let clientPairing = try? clientVault.loadPairing()
        if let migrated = try? roster.migrateLegacyPairing(clientPairing, displayName: "Paired Mac"),
           let preferredTailscaleID {
            try? roster.update(nodeID: migrated.id) { $0.tailscaleNodeID = preferredTailscaleID }
        }
        let pairedNodes = (try? roster.prepareForLaunch()) ?? []
        let authorizedClients = (try? hostTrust.load()) ?? []
        let isPaired = role == .client
            ? !pairedNodes.isEmpty || clientPairing != nil
            : !authorizedClients.filter({ $0.status != .revoked }).isEmpty || (try? hostVault.loadPairing()) != nil
        return .init(pairedNodes: pairedNodes, authorizedClients: authorizedClients, isPaired: isPaired)
    }

    func start() { restart() }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: enabledKey)
        restart()
    }

    func setRole(_ role: NexusConnectRole) {
        guard self.role != role else { return }
        self.role = role
        defaults.set(role.rawValue, forKey: roleKey)
        isPaired = role == .client
            ? !pairedNodes.isEmpty
            : !authorizedClients.filter({ $0.status != .revoked }).isEmpty || (try? hostVault.loadPairing()) != nil
        pairingCode = ""
        setupMessage = ""
        restart()
    }

    func setModelRoute(_ route: NexusModelRoute) {
        modelRoute = route
        if let data = try? NexusPayloadCoder.encoder.encode(route) {
            defaults.set(data, forKey: modelRouteKey)
        }
        Task { await router.setRoute(route) }
    }

    func setDownloadTarget(_ target: NexusDownloadTarget, selected: Bool) {
        if target == .automatic, selected {
            downloadTargets = [.automatic]
        } else if selected {
            downloadTargets.remove(.automatic)
            downloadTargets.insert(target)
        } else {
            downloadTargets.remove(target)
        }
        // A download with no destination is never meaningful. Keep the local
        // target as a safe, visible default instead of guessing later.
        if downloadTargets.isEmpty { downloadTargets = [.thisMac] }
        persistDownloadTargets()
    }

    func useOnlyDownloadTarget(_ target: NexusDownloadTarget) {
        downloadTargets = [target]
        persistDownloadTargets()
    }

    func automaticDownloadTarget(
        for model: LocalModel,
        localHasModel: Bool
    ) async throws -> NexusDownloadTarget {
        if localHasModel { return .thisMac }
        let descriptor = NexusModelDescriptor(
            runtime: model.backend == .ollama ? .ollama : .lmStudio,
            identifier: model.identifier
        )
        if let nodeID = await router.automaticNode(
            for: descriptor,
            minimumRAMGB: model.minimumRAMGB
        ) {
            return .pairedNode(nodeID)
        }
        let requiredMemory = UInt64(max(1, model.minimumRAMGB)) * 1_073_741_824
        let requiredDisk = Int64(max(4, model.minimumRAMGB)) * 1_073_741_824
        let localMemory = ProcessInfo.processInfo.physicalMemory
        let fileSystem = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let localDisk = (fileSystem?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard localMemory >= requiredMemory, localDisk >= requiredDisk else {
            throw NexusConnectError.unavailable("No online paired Mac or this Mac has enough reported memory and free disk for \(model.name).")
        }
        return .thisMac
    }

    func createPairingCode() async {
        do {
            if role == .studioHost {
                let identity = try hostVault.loadOrCreateIdentity()
                let snapshot = try await discovery.snapshot()
                guard snapshot.backendState.caseInsensitiveCompare("Running") == .orderedSame else {
                    throw NexusConnectError.unavailable("Tailscale must be connected before creating a pairing code")
                }
                let name = snapshot.localNodeName.isEmpty
                    ? (Host.current().localizedName ?? "Nexus Mac")
                    : snapshot.localNodeName
                let endpoint = (snapshot.localDNSName.isEmpty ? nil : snapshot.localDNSName)
                    ?? snapshot.localAddresses.first(where: NexusConnectHostListener.isTailnetAddress)
                    ?? name
                let generated = try NexusPairingCode.generateInvitation(
                    identity: identity,
                    displayName: name,
                    endpoint: endpoint,
                    tailscaleNodeID: snapshot.localNodeID.isEmpty ? nil : snapshot.localNodeID
                )
                try hostTrust.registerInvitation(pairing: generated.material)
                authorizedClients = try hostTrust.load()
                pairingCode = generated.code
                setupMessage = "Pair this device once. Nexus will pin \(name)'s identity and reconnect automatically."
            } else {
                let generated = try NexusPairingCode.generate()
                try clientVault.savePairing(generated.material)
                pairingCode = generated.code
                setupMessage = "Legacy NX1 code created. Generate the preferred NX2 code on the host Mac."
            }
            isPaired = true
            restart()
        } catch {
            setupMessage = error.localizedDescription
        }
    }

    func applyPairingCode() {
        do {
            if NexusPairingCode.isInvitation(pairingCode) {
                let invitation = try NexusPairingCode.decodeInvitation(pairingCode)
                guard invitation.protocolRange.highestCommonVersion(with: .local) != nil else {
                    throw NexusConnectError.unsupportedProtocol
                }
                let pairing = try NexusPairingMaterial(
                    secret: invitation.secret,
                    peerDeviceID: invitation.hostNodeID,
                    peerSigningPublicKey: invitation.hostSigningPublicKey,
                    pairingID: invitation.invitationID
                )
                let node = NexusPairedNode(
                    id: invitation.hostNodeID,
                    pinnedPublicIdentityKey: invitation.hostSigningPublicKey,
                    displayName: invitation.displayName,
                    endpoint: invitation.endpoint,
                    tailscaleNodeID: invitation.tailscaleNodeID,
                    protocolRange: invitation.protocolRange
                )
                try roster.upsert(node, pairing: pairing)
                pairedNodes = try roster.prepareForLaunch()
                setupMessage = "\(node.displayName) is paired permanently and will reconnect automatically."
            } else {
                let material = try NexusPairingCode.decode(pairingCode)
                try vault(for: role).savePairing(material)
                setupMessage = "Legacy pairing saved securely in Keychain."
            }
            isPaired = true
            restart()
        } catch NexusConnectError.unsupportedProtocol {
            setupMessage = "This device uses an incompatible Nexus Connect protocol. Pairing was not changed."
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

    func rename(nodeID: UUID, to name: String) {
        do {
            try roster.rename(nodeID: nodeID, to: name)
            pairedNodes = try roster.load()
            setupMessage = "Device renamed."
        } catch {
            setupMessage = error.localizedDescription
        }
    }

    func reconnect(nodeID: UUID) { coordinator.reconnect(nodeID: nodeID) }

    func renameAuthorizedClient(pairingID: UUID, to name: String) {
        do {
            try hostTrust.rename(pairingID: pairingID, to: name)
            authorizedClients = try hostTrust.load()
            setupMessage = "Authorized device renamed."
        } catch {
            setupMessage = error.localizedDescription
        }
    }

    func revokeAuthorizedClient(pairingID: UUID) {
        do {
            try hostTrust.revoke(pairingID: pairingID)
            authorizedClients = try hostTrust.load()
            isPaired = authorizedClients.contains { $0.status != .revoked }
            setupMessage = "Device access revoked. Existing credentials can no longer reconnect."
        } catch {
            setupMessage = error.localizedDescription
        }
    }

    func refreshAuthorizedClients() {
        authorizedClients = (try? hostTrust.load()) ?? authorizedClients
    }

    func forget(nodeID: UUID) {
        do {
            try roster.forget(nodeID: nodeID)
            coordinator.forget(nodeID: nodeID)
            pairedNodes = try roster.load()
            if case .pairedNode(nodeID) = modelRoute { setModelRoute(.automatic) }
            downloadTargets.remove(.pairedNode(nodeID))
            if downloadTargets.isEmpty { downloadTargets = [.thisMac] }
            persistDownloadTargets()
            isPaired = !pairedNodes.isEmpty
            setupMessage = "Device forgotten and its credentials revoked."
            synchronizeRouter()
        } catch {
            setupMessage = error.localizedDescription
        }
    }

    /// Legacy whole-role removal. New UI uses per-node `forget(nodeID:)`.
    func unpair() {
        if role == .client {
            for node in pairedNodes { try? roster.forget(nodeID: node.id) }
            try? clientVault.removePairing()
            pairedNodes = []
            coordinator.stop()
        } else {
            for client in authorizedClients where client.status != .revoked {
                try? hostTrust.revoke(pairingID: client.id)
            }
            try? hostVault.removePairing()
            authorizedClients = (try? hostTrust.load()) ?? []
        }
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
        try await response(
            model: model,
            messages: [.init(role: "user", content: prompt)],
            onDelta: onDelta
        )
    }

    func response(
        model: LocalModel,
        messages: [NexusChatMessage],
        temperature: Double? = nil,
        maximumTokens: Int? = nil,
        onDelta: @escaping @Sendable (String, String) async -> Void
    ) async throws -> String {
        let request = try NexusWorkloadRequest(
            kind: .inference,
            priority: .interactive,
            retrySafety: .idempotent,
            payload: NexusInferencePayload(
                runtime: model.backend == .ollama ? .ollama : .lmStudio,
                model: model.identifier,
                messages: messages,
                temperature: temperature,
                maximumTokens: maximumTokens
            )
        )
        let stream = try await workloads.events(for: request)
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
        on nodeID: UUID? = nil,
        onProgress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws {
        let targetID: UUID
        if let nodeID {
            targetID = nodeID
        } else if case .pairedNode(let selected) = modelRoute {
            targetID = selected
        } else {
            let descriptor = NexusModelDescriptor(
                runtime: model.backend == .ollama ? .ollama : .lmStudio,
                identifier: model.identifier
            )
            guard let automatic = await router.automaticNode(for: descriptor, minimumRAMGB: model.minimumRAMGB) else {
                throw NexusConnectError.unavailable("no connected paired device has enough free memory and disk")
            }
            targetID = automatic
        }
        guard let remote = coordinator.executor(for: targetID) else {
            let name = pairedNodes.first(where: { $0.id == targetID })?.displayName ?? "Selected device"
            throw NexusConnectError.unavailable("\(name) is not connected; the download was not moved to this Mac")
        }
        try await prepareRuntimeForModelDownload(model, on: targetID)
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
        let stream = try await remote.events(for: request)
        for try await event in stream where event.kind == .progress {
            let progress = try event.decodePayload(NexusProgressPayload.self)
            await onProgress(.init(
                completedBytes: progress.completedBytes,
                totalBytes: progress.totalBytes,
                status: progress.status
            ))
        }
        try await refreshInventory(nodeID: targetID)
    }

    /// A download is already an explicit request to mutate the selected
    /// destination. Probe the host at operation time so stale cached
    /// inventory cannot cause an unnecessary prompt. If Ollama is absent, the
    /// same authenticated operation provisions it before pulling the model.
    private func prepareRuntimeForModelDownload(_ model: LocalModel, on nodeID: UUID) async throws {
        guard let node = pairedNodes.first(where: { $0.id == nodeID }),
              node.capabilities.contains(.runtimeStatus) else {
            // Protocol-v1 hosts perform their own authoritative probe.
            return
        }
        let requested: NexusRuntimeKind = model.backend == .ollama ? .ollama : .lmStudio
        let inventory = try await runtimeInventory(on: nodeID)
        if inventory.runtimes.contains(where: { $0.kind == requested }) { return }

        if requested == .ollama, node.capabilities.contains(.runtimeProvision) {
            _ = try await provisionDefaultRuntime(
                on: nodeID,
                preferred: .ollama,
                userConfirmed: true
            )
            return
        }

        let detected = (inventory.detectedRuntimeNames ?? Set(inventory.runtimes.map(\.kind.rawValue)))
            .sorted()
            .joined(separator: ", ")
        let suffix = detected.isEmpty ? "No supported runtime was detected." : "Detected: \(detected)."
        throw NexusConnectError.requestFailed(
            "LM Studio is not installed on \(node.displayName). \(suffix) Install LM Studio there or download an Ollama model, which Nexus can provision automatically."
        )
    }

    func installedStudioModels(runtime: NexusRuntimeKind? = nil) async throws -> [NexusModelDescriptor] {
        let onlineIDs = pairedNodes.filter { $0.status == .online }.map(\.id)
        var result: Set<NexusModelDescriptor> = []
        for nodeID in onlineIDs {
            result.formUnion(try await installedModels(on: nodeID, runtime: runtime))
        }
        return result.sorted { $0.identifier < $1.identifier }
    }

    func installedModels(on nodeID: UUID, runtime: NexusRuntimeKind? = nil) async throws -> [NexusModelDescriptor] {
        guard let remote = coordinator.executor(for: nodeID) else {
            throw NexusConnectError.unavailable("the selected remote host is offline")
        }
        let request = try NexusWorkloadRequest(
            kind: .modelList,
            retrySafety: .idempotent,
            payload: NexusModelListPayload(runtime: runtime)
        )
        let stream = try await remote.events(for: request)
        for try await event in stream where event.kind == .result {
            return try event.decodePayload(NexusModelInventoryPayload.self).models
        }
        return []
    }

    func runtimeInventory(on nodeID: UUID) async throws -> NexusRuntimeInventoryPayload {
        let remote = try connectedExecutor(nodeID: nodeID)
        guard pairedNodes.first(where: { $0.id == nodeID })?.capabilities.contains(.runtimeStatus) == true else {
            throw NexusConnectError.requestFailed("This host version does not support runtime management. Model inference remains available; update Nexus on that host to install runtimes remotely.")
        }
        let request = try NexusWorkloadRequest(
            kind: .runtimeStatus,
            retrySafety: .idempotent,
            payload: NexusEmptyPayload()
        )
        let stream = try await remote.events(for: request)
        for try await event in stream where event.kind == .result {
            return try event.decodePayload(NexusRuntimeInventoryPayload.self)
        }
        throw NexusConnectError.requestFailed("The remote host did not return its runtime inventory.")
    }

    @discardableResult
    func provisionDefaultRuntime(
        on nodeID: UUID,
        preferred: NexusRuntimeKind? = .ollama,
        userConfirmed: Bool
    ) async throws -> NexusRuntimeInventoryPayload {
        let remote = try connectedExecutor(nodeID: nodeID)
        guard pairedNodes.first(where: { $0.id == nodeID })?.capabilities.contains(.runtimeProvision) == true else {
            throw NexusConnectError.requestFailed("This host version cannot provision runtimes remotely. Update Nexus on that host and retry.")
        }
        let request = try NexusWorkloadRequest(
            kind: .runtimeProvision,
            priority: .utility,
            retrySafety: .resumable,
            payload: NexusRuntimeProvisionPayload(preferredRuntime: preferred, userConfirmed: userConfirmed)
        )
        let stream = try await remote.events(for: request)
        for try await event in stream where event.kind == .result {
            let inventory = try event.decodePayload(NexusRuntimeInventoryPayload.self)
            try roster.update(nodeID: nodeID) { $0.runtimes = inventory.runtimes }
            pairedNodes = try roster.load()
            synchronizeRouter()
            return inventory
        }
        throw NexusConnectError.requestFailed("Runtime installation ended without a result.")
    }

    func deleteModel(_ model: LocalModel, on nodeID: UUID) async throws {
        let remote = try connectedExecutor(nodeID: nodeID)
        guard pairedNodes.first(where: { $0.id == nodeID })?.capabilities.contains(.modelDelete) == true else {
            throw NexusConnectError.requestFailed("This host version does not support remote model deletion.")
        }
        let request = try NexusWorkloadRequest(
            kind: .modelDelete,
            priority: .utility,
            retrySafety: .neverReplay,
            payload: NexusModelDeletePayload(
                runtime: model.backend == .ollama ? .ollama : .lmStudio,
                model: model.identifier
            )
        )
        let stream = try await remote.events(for: request)
        for try await event in stream where event.isFinal {
            if event.kind == .failed {
                throw NexusConnectError.requestFailed(try event.decodePayload(NexusRemoteErrorPayload.self).message)
            }
        }
        try await refreshInventory(nodeID: nodeID)
    }

    /// Runs one allowlisted executable after an intentional user confirmation.
    /// Arguments remain a structured array and no shell interpreter is used.
    func runApprovedProcess(
        executableID: String,
        arguments: [String],
        workingDirectory: NexusFileReference? = nil,
        timeoutSeconds: TimeInterval = 120,
        maximumOutputBytes: Int = 8 * 1_024 * 1_024
    ) async throws -> NexusStructuredProcessResult {
        let alert = NSAlert()
        alert.messageText = "Allow \(executableID) on \(routeDisplayName)?"
        alert.informativeText = arguments.isEmpty
            ? "Nexus will run the executable once without a shell."
            : "Arguments:\n\(arguments.joined(separator: " "))\n\nNexus will not use zsh -c or execute model-generated shell text."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Run Once")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { throw NexusConnectError.cancelled }

        let approval = try await workloads.requestProcessApproval(
            executableID: executableID,
            validFor: 60
        )
        return try await workloads.runApprovedProcess(.init(
            executableID: executableID,
            arguments: arguments,
            environment: [:],
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds,
            maximumOutputBytes: maximumOutputBytes,
            approvalToken: approval.token
        ))
    }

    func shutdown() {
        hostStartTask?.cancel()
        coordinator.stop()
    }

    private func restart() {
        hostStartTask?.cancel()
        hostStartTask = nil
        coordinator.stop()
        isPaired = role == .client
            ? !pairedNodes.isEmpty
            : authorizedClients.contains { $0.status != .revoked } || (try? hostVault.loadPairing()) != nil

        guard enabled else {
            Task { await router.setRoute(.thisMac) }
            state = .off
            return
        }
        guard isPaired else {
            Task { await router.setRoute(.thisMac) }
            state = .needsPairing
            return
        }
        switch role {
        case .client:
            guard !pairedNodes.isEmpty else {
                state = .needsPairing
                return
            }
            Task { await router.setRoute(modelRoute) }
            state = .discovering
            coordinator.start(nodes: pairedNodes)
        case .studioHost:
            Task { await router.setRoute(.thisMac) }
            startHosting()
        }
    }

    private func startHosting() {
        do {
            try persistentHost.installAndStart()
            state = .connecting("Tailscale")
            hostStartTask = Task { [weak self] in
                for _ in 0..<30 {
                    guard !Task.isCancelled else { return }
                    if let status = self?.persistentHost.currentStatus() {
                        if status.state == "ready" {
                            self?.state = .hosting
                        } else if status.state == "failed" {
                            self?.state = .failed(status.detail ?? "Nexus Connect host failed")
                        }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                self?.state = .failed("Background Nexus Connect host did not become ready")
            }
        } catch {
            state = .failed("Background Nexus Connect host could not start: \(error.localizedDescription)")
        }
    }

    private func apply(nodes: [NexusPairedNode]) {
        pairedNodes = nodes
        isPaired = !nodes.isEmpty
        synchronizeRouter()
        guard enabled, role == .client else { return }
        let online = nodes.filter { $0.status == .online }
        if online.count == 1, let node = online.first {
            let rtt = node.statusDetail.flatMap { Double($0.replacingOccurrences(of: " ms", with: "")) }
            state = .ready(
                name: node.displayName,
                memoryGB: node.totalMemoryBytes.map(Self.gigabytes) ?? 0,
                roundTripMilliseconds: rtt
            )
        } else if online.count > 1 {
            state = .ready(
                name: "\(online.count) paired Macs",
                memoryGB: online.compactMap(\.totalMemoryBytes).map(Self.gigabytes).reduce(0, +),
                roundTripMilliseconds: nil
            )
        } else if let incompatible = nodes.first(where: { $0.status == .incompatible }) {
            state = .failed(incompatible.statusDetail ?? "\(incompatible.displayName) is incompatible")
        } else if nodes.contains(where: { $0.status == .reconnecting }) {
            state = .discovering
        } else {
            state = .failed("All paired Macs are offline; local Nexus remains available.")
        }
    }

    private func synchronizeRouter() {
        var executors: [UUID: any NexusWorkloadExecuting] = [:]
        for node in pairedNodes where node.status == .online {
            executors[node.id] = coordinator.executor(for: node.id)
        }
        let nodes = pairedNodes
        Task { await router.synchronize(nodes: nodes, executors: executors) }
    }

    private func refreshInventory(nodeID: UUID) async throws {
        let inventory = try await installedModels(on: nodeID)
        try roster.update(nodeID: nodeID) { $0.modelInventory = inventory }
        pairedNodes = try roster.load()
        synchronizeRouter()
    }

    private func connectedExecutor(nodeID: UUID) throws -> any NexusWorkloadExecuting {
        guard let node = pairedNodes.first(where: { $0.id == nodeID }) else {
            throw NexusConnectError.unavailable("the paired device was forgotten")
        }
        guard node.status == .online, let remote = coordinator.executor(for: nodeID) else {
            throw NexusConnectError.unavailable("\(node.displayName) is \(node.status.rawValue); Nexus did not fall back to this Mac")
        }
        return remote
    }

    private func persistDownloadTargets() {
        if let data = try? NexusPayloadCoder.encoder.encode(Array(downloadTargets)) {
            defaults.set(data, forKey: downloadTargetsKey)
        }
    }

    private var routeDisplayName: String {
        switch modelRoute {
        case .automatic: "the automatically selected Mac"
        case .thisMac: "this Mac"
        case .pairedNode(let id): pairedNodes.first(where: { $0.id == id })?.displayName ?? "the selected Mac"
        }
    }

    private func vault(for role: NexusConnectRole) -> NexusIdentityVault {
        role == .client ? clientVault : hostVault
    }

    private static func suggestedRole() -> NexusConnectRole {
        let name = Host.current().localizedName?.lowercased() ?? ""
        return name.contains("studio") ? .studioHost : .client
    }

    private static func restoreRoute(from data: Data?) -> NexusModelRoute {
        guard let data, let route = try? NexusPayloadCoder.decoder.decode(NexusModelRoute.self, from: data) else {
            return .automatic
        }
        return route
    }

    private static func restoreDownloadTargets(from data: Data?) -> Set<NexusDownloadTarget> {
        guard let data,
              let targets = try? NexusPayloadCoder.decoder.decode([NexusDownloadTarget].self, from: data),
              !targets.isEmpty else { return [.thisMac] }
        return Set(targets)
    }

    private static func gigabytes(_ bytes: UInt64) -> Int {
        max(1, Int(bytes / 1_073_741_824))
    }
}
