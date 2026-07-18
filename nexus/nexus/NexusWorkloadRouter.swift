import Foundation

enum NexusRoutingPreference: String, Codable, Sendable {
    case automatic
    case localOnly
    case remoteOnly
}

actor NexusLocalWorkloadExecutor: NexusWorkloadExecuting {
    private let services: NexusHostServiceExecutor
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(services: NexusHostServiceExecutor) { self.services = services }

    func events(for request: NexusWorkloadRequest) async throws -> AsyncThrowingStream<NexusWorkloadEvent, Error> {
        guard tasks[request.id] == nil else { throw NexusConnectError.requestFailed("duplicate request ID") }
        var continuation: AsyncThrowingStream<NexusWorkloadEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<NexusWorkloadEvent, Error> { continuation = $0 }
        let savedContinuation = continuation!
        let task = Task { [weak self] in
            guard let self else { return }
            await self.services.execute(request) { event in
                savedContinuation.yield(event)
                if event.isFinal { savedContinuation.finish() }
            }
            await self.remove(request.id)
        }
        tasks[request.id] = task
        let owner = self
        savedContinuation.onTermination = { termination in
            if case .cancelled = termination { Task { await owner.cancel(requestID: request.id) } }
        }
        return stream
    }

    func cancel(requestID: UUID) async { tasks.removeValue(forKey: requestID)?.cancel() }
    private func remove(_ id: UUID) { tasks.removeValue(forKey: id) }
}

actor NexusWorkloadRouter: NexusWorkloadExecuting {
    private let local: any NexusWorkloadExecuting
    private var remote: (any NexusWorkloadExecuting)?
    private var preference: NexusRoutingPreference

    init(
        local: any NexusWorkloadExecuting,
        remote: (any NexusWorkloadExecuting)? = nil,
        preference: NexusRoutingPreference = .automatic
    ) {
        self.local = local
        self.remote = remote
        self.preference = preference
    }

    func setRemote(_ executor: (any NexusWorkloadExecuting)?) { remote = executor }
    func setPreference(_ preference: NexusRoutingPreference) { self.preference = preference }

    func events(for request: NexusWorkloadRequest) async throws -> AsyncThrowingStream<NexusWorkloadEvent, Error> {
        switch preference {
        case .localOnly:
            return try await local.events(for: request)
        case .remoteOnly:
            guard let remote else { throw NexusConnectError.unavailable("the selected paired Mac is offline") }
            return try await remote.events(for: request)
        case .automatic:
            guard let remote else { return try await local.events(for: request) }
            return fallbackStream(request: request, remote: remote)
        }
    }

    func cancel(requestID: UUID) async {
        await remote?.cancel(requestID: requestID)
        await local.cancel(requestID: requestID)
    }

    private func fallbackStream(
        request: NexusWorkloadRequest,
        remote: any NexusWorkloadExecuting
    ) -> AsyncThrowingStream<NexusWorkloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var deliveredSideEffect = false
                var pendingStatusEvents: [NexusWorkloadEvent] = []
                do {
                    let stream = try await remote.events(for: request)
                    for try await event in stream {
                        if Self.isSubstantive(event) {
                            if !deliveredSideEffect {
                                for pending in pendingStatusEvents { continuation.yield(pending) }
                                pendingStatusEvents.removeAll()
                            }
                            deliveredSideEffect = true
                            continuation.yield(event)
                        } else {
                            pendingStatusEvents.append(event)
                        }
                    }
                    for pending in pendingStatusEvents { continuation.yield(pending) }
                    continuation.finish()
                } catch {
                    guard !deliveredSideEffect, Self.canFallback(request) else {
                        continuation.finish(throwing: error)
                        return
                    }
                    do {
                        let stream = try await local.events(for: request)
                        for try await event in stream { continuation.yield(event) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    static func canFallback(_ request: NexusWorkloadRequest) -> Bool {
        guard request.retrySafety == .idempotent else { return false }
        return [
            .health, .inference, .agent, .modelList, .ocr,
            .index, .searchIndex, .fileStat, .fileRead, .fileList
        ].contains(request.kind)
    }

    private static func isSubstantive(_ event: NexusWorkloadEvent) -> Bool {
        [.token, .standardOutput, .standardError, .result, .completed].contains(event.kind)
    }
}

/// Explicit multi-device router used by the v2 controller. A chosen remote is
/// never silently replaced with another computer, while Automatic retains the
/// original local-only fallback behavior for safe requests.
actor NexusMultiNodeWorkloadRouter: NexusWorkloadExecuting {
    private let local: any NexusWorkloadExecuting
    private var nodes: [UUID: NexusPairedNode] = [:]
    private var remotes: [UUID: any NexusWorkloadExecuting] = [:]
    private var route: NexusModelRoute = .automatic

    init(local: any NexusWorkloadExecuting) {
        self.local = local
    }

    func setRoute(_ route: NexusModelRoute) {
        self.route = route
    }

    func synchronize(
        nodes: [NexusPairedNode],
        executors: [UUID: any NexusWorkloadExecuting]
    ) {
        self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        remotes = executors.filter { id, _ in self.nodes[id]?.status == .online }
    }

    func events(for request: NexusWorkloadRequest) async throws -> AsyncThrowingStream<NexusWorkloadEvent, Error> {
        switch route {
        case .thisMac:
            return try await local.events(for: request)
        case .pairedNode(let nodeID):
            guard nodes[nodeID] != nil else {
                throw NexusConnectError.unavailable("the selected paired device was forgotten")
            }
            guard let remote = remotes[nodeID], nodes[nodeID]?.status == .online else {
                let detail = nodes[nodeID]?.statusDetail ?? "the selected device is offline"
                throw NexusConnectError.unavailable(detail)
            }
            return try await remote.events(for: request)
        case .automatic:
            guard let remote = automaticRemote(for: request) else {
                return try await local.events(for: request)
            }
            return automaticFallbackStream(request: request, remote: remote)
        }
    }

    func cancel(requestID: UUID) async {
        await local.cancel(requestID: requestID)
        for remote in remotes.values { await remote.cancel(requestID: requestID) }
    }

    func automaticNode(for model: NexusModelDescriptor, minimumRAMGB: Int) -> UUID? {
        let online = nodes.values.filter { $0.status == .online && remotes[$0.id] != nil }
        if let installed = online
            .filter({ $0.modelInventory.contains(model) })
            .sorted(by: Self.preferredNode)
            .first {
            return installed.id
        }
        let requiredMemory = UInt64(max(1, minimumRAMGB)) * 1_073_741_824
        let requiredDisk = Int64(max(4, minimumRAMGB)) * 1_073_741_824
        return online
            .filter {
                ($0.availableMemoryBytes ?? 0) >= requiredMemory &&
                ($0.availableDiskBytes ?? 0) >= requiredDisk
            }
            .sorted(by: Self.preferredNode)
            .first?.id
    }

    private func automaticRemote(for request: NexusWorkloadRequest) -> (any NexusWorkloadExecuting)? {
        let descriptor: NexusModelDescriptor?
        switch request.kind {
        case .inference:
            descriptor = try? request.decodePayload(NexusInferencePayload.self).modelDescriptor
        case .intentRoute:
            descriptor = .init(runtime: .ollama, identifier: "functiongemma:latest")
        case .modelPull:
            descriptor = try? request.decodePayload(NexusModelPullPayload.self).modelDescriptor
        default:
            descriptor = nil
        }
        let candidates = nodes.values.filter { node in
            guard node.status == .online, remotes[node.id] != nil else { return false }
            guard let descriptor else { return true }
            return node.modelInventory.contains(descriptor)
        }.sorted(by: Self.preferredNode)
        guard let selected = candidates.first else { return nil }
        return remotes[selected.id]
    }

    private func automaticFallbackStream(
        request: NexusWorkloadRequest,
        remote: any NexusWorkloadExecuting
    ) -> AsyncThrowingStream<NexusWorkloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var deliveredSubstantiveEvent = false
                do {
                    let stream = try await remote.events(for: request)
                    for try await event in stream {
                        if [.token, .standardOutput, .standardError, .result, .completed].contains(event.kind) {
                            deliveredSubstantiveEvent = true
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    guard !deliveredSubstantiveEvent, NexusWorkloadRouter.canFallback(request) else {
                        continuation.finish(throwing: error)
                        return
                    }
                    do {
                        let localStream = try await local.events(for: request)
                        for try await event in localStream { continuation.yield(event) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    private static func preferredNode(_ lhs: NexusPairedNode, _ rhs: NexusPairedNode) -> Bool {
        let lhsMemory = lhs.availableMemoryBytes ?? 0
        let rhsMemory = rhs.availableMemoryBytes ?? 0
        if lhsMemory != rhsMemory { return lhsMemory > rhsMemory }
        let lhsDisk = lhs.availableDiskBytes ?? 0
        let rhsDisk = rhs.availableDiskBytes ?? 0
        if lhsDisk != rhsDisk { return lhsDisk > rhsDisk }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}

private extension NexusInferencePayload {
    var modelDescriptor: NexusModelDescriptor { .init(runtime: runtime, identifier: model) }
}

private extension NexusModelPullPayload {
    var modelDescriptor: NexusModelDescriptor { .init(runtime: runtime, identifier: model) }
}
