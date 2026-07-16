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
            guard let remote else { throw NexusConnectError.unavailable("Mac Studio is offline") }
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
        return [.health, .inference, .agent, .modelList, .ocr].contains(request.kind)
    }

    private static func isSubstantive(_ event: NexusWorkloadEvent) -> Bool {
        [.token, .standardOutput, .standardError, .result, .completed].contains(event.kind)
    }
}
