import Foundation
import Network

protocol NexusWorkloadExecuting: Sendable {
    func events(for request: NexusWorkloadRequest) async throws -> AsyncThrowingStream<NexusWorkloadEvent, Error>
    func cancel(requestID: UUID) async
}

actor NexusFramedConnection {
    private let transport: any NexusByteTransport
    private var decoder = NexusFrameDecoder()
    private var pending: [Data] = []

    init(transport: any NexusByteTransport) {
        self.transport = transport
    }

    func sendPayload(_ payload: Data, maximumBytes: Int = NexusConnectProtocol.maximumDataFrameBytes) async throws {
        try await transport.send(NexusFrameCodec.frame(payload, maximumBytes: maximumBytes))
    }

    func sendFramed(_ data: Data) async throws {
        try await transport.send(data)
    }

    func receivePayload(maximumBytes: Int = NexusConnectProtocol.maximumDataFrameBytes) async throws -> Data {
        if !pending.isEmpty {
            let result = pending.removeFirst()
            guard result.count <= maximumBytes else { throw NexusConnectError.frameTooLarge(result.count) }
            return result
        }
        while true {
            let data = try await transport.receive()
            let frames = try decoder.append(data)
            if let first = frames.first {
                pending.append(contentsOf: frames.dropFirst())
                guard first.count <= maximumBytes else { throw NexusConnectError.frameTooLarge(first.count) }
                return first
            }
        }
    }

    func cancel() async { await transport.cancel() }
}

actor NexusRemoteClientSession: NexusRemoteSession, NexusWorkloadExecuting {
    typealias TransportFactory = @Sendable () -> any NexusByteTransport

    private let vault: any NexusSessionCredentialProviding
    private let transportFactory: TransportFactory
    private var connection: NexusFramedConnection?
    private var secureChannel: NexusSecureChannel?
    private var sessionID: UUID?
    private var receiveTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncThrowingStream<NexusWorkloadEvent, Error>.Continuation] = [:]
    private var connectedPeer: NexusTailscalePeer?
    private var negotiatedProtocol = NexusConnectProtocol.currentVersion
    private(set) var negotiatedFeatures: Set<NexusConnectFeature> = []

    init(
        vault: any NexusSessionCredentialProviding = NexusIdentityVault(role: .client),
        transportFactory: @escaping TransportFactory = { NexusNWConnectionTransport() }
    ) {
        self.vault = vault
        self.transportFactory = transportFactory
    }

    func connect(to peer: NexusTailscalePeer) async throws -> NexusNodeHealth {
        await disconnect()
        guard var pairing = try vault.loadPairing() else {
            throw NexusConnectError.unavailable("this Mac has not been paired with a Studio")
        }
        let identity = try vault.loadOrCreateIdentity()
        let transport = transportFactory()
        try await transport.connect(host: peer.connectionHost, port: NexusConnectProtocol.servicePort)
        let framed = NexusFramedConnection(transport: transport)
        let newSessionID = UUID()
        let pending = try NexusHandshake.makeHello(identity: identity, role: .client, pairing: pairing)
        let envelope = NexusHandshakeEnvelope(sessionID: newSessionID, hello: pending.hello)
        try await framed.sendPayload(
            try NexusPayloadCoder.encoder.encode(envelope),
            maximumBytes: NexusConnectProtocol.maximumControlFrameBytes
        )
        let responseData = try await framed.receivePayload(maximumBytes: NexusConnectProtocol.maximumControlFrameBytes)
        let response = try NexusPayloadCoder.decoder.decode(NexusHandshakeEnvelope.self, from: responseData)
        guard response.sessionID == newSessionID else { throw NexusConnectError.authenticationFailed }
        try NexusHandshake.verify(
            response.hello,
            pairing: pairing,
            expectedRole: .studioHost,
            respondingToNonce: pending.hello.nonce
        )
        let negotiation = try NexusProtocolNegotiator.negotiate(
            remoteRange: response.hello.advertisedProtocolRange,
            remoteFeatures: response.hello.advertisedFeatures
        )
        pairing = try pairing.pinning(
            peerDeviceID: response.hello.deviceID,
            peerSigningPublicKey: response.hello.signingPublicKey
        )
        try vault.savePairing(pairing)
        let key = try NexusHandshake.deriveSessionKey(
            local: pending,
            remote: response.hello,
            pairing: pairing,
            clientNonce: pending.hello.nonce,
            hostNonce: response.hello.nonce,
            sessionID: newSessionID
        )
        connection = framed
        sessionID = newSessionID
        connectedPeer = peer
        secureChannel = NexusSecureChannel(
            sessionID: newSessionID,
            key: key,
            outgoingDirection: .clientToHost,
            incomingDirection: .hostToClient,
            protocolVersion: negotiation.version
        )
        negotiatedProtocol = negotiation.version
        negotiatedFeatures = negotiation.features
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        return try await health()
    }

    func health() async throws -> NexusNodeHealth {
        let request = try NexusWorkloadRequest(
            kind: .health,
            priority: .interactive,
            retrySafety: .idempotent,
            payload: NexusEmptyPayload()
        )
        let stream = try await events(for: request)
        var result: NexusNodeHealth?
        for try await event in stream {
            if event.kind == .result { result = try event.decodePayload(NexusNodeHealth.self) }
        }
        guard let result else { throw NexusConnectError.unavailable("Studio did not return health data") }
        return result
    }

    func events(for request: NexusWorkloadRequest) async throws -> AsyncThrowingStream<NexusWorkloadEvent, Error> {
        guard connection != nil, secureChannel != nil, let sessionID else {
            throw NexusConnectError.unavailable("Mac Studio is not connected")
        }
        guard continuations[request.id] == nil else {
            throw NexusConnectError.requestFailed("duplicate request ID")
        }
        var continuation: AsyncThrowingStream<NexusWorkloadEvent, Error>.Continuation!
        let stream = AsyncThrowingStream<NexusWorkloadEvent, Error> { continuation = $0 }
        let savedContinuation = continuation!
        continuations[request.id] = savedContinuation
        let owner = self
        savedContinuation.onTermination = { termination in
            guard case .cancelled = termination else { return }
            Task { await owner.cancel(requestID: request.id) }
        }
        do {
            try await send(kind: .request, requestID: request.id, payload: request, sessionID: sessionID)
        } catch {
            continuations.removeValue(forKey: request.id)
            savedContinuation.finish(throwing: error)
            throw error
        }
        return stream
    }

    func cancel(requestID: UUID) async {
        guard let sessionID else { return }
        try? await send(kind: .cancel, requestID: requestID, payload: NexusEmptyPayload(), sessionID: sessionID)
        continuations.removeValue(forKey: requestID)?.finish(throwing: NexusConnectError.cancelled)
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        await connection?.cancel()
        connection = nil
        secureChannel = nil
        sessionID = nil
        connectedPeer = nil
        negotiatedProtocol = NexusConnectProtocol.currentVersion
        negotiatedFeatures = []
        finishAll(throwing: NexusConnectError.unavailable("Mac Studio disconnected"))
    }

    private func send<Payload: Encodable>(
        kind: NexusMessageKind,
        requestID: UUID?,
        payload: Payload,
        sessionID: UUID
    ) async throws {
        guard let connection, var channel = secureChannel else {
            throw NexusConnectError.unavailable("Mac Studio is not connected")
        }
        let message = try NexusConnectMessage(
            protocolVersion: negotiatedProtocol,
            sessionID: sessionID,
            kind: kind,
            requestID: requestID,
            payload: payload
        )
        let framed = try channel.seal(message)
        secureChannel = channel
        try await connection.sendFramed(framed)
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                guard let connection else { return }
                let packet = try await connection.receivePayload()
                guard var channel = secureChannel else { return }
                let message = try channel.open(packet)
                secureChannel = channel
                try await handle(message)
            }
        } catch is CancellationError {
            return
        } catch {
            finishAll(throwing: error)
            await connection?.cancel()
            connection = nil
            secureChannel = nil
            sessionID = nil
            negotiatedProtocol = NexusConnectProtocol.currentVersion
            negotiatedFeatures = []
        }
    }

    private func handle(_ message: NexusConnectMessage) async throws {
        switch message.kind {
        case .event:
            let event = try message.decodePayload(NexusWorkloadEvent.self)
            guard event.requestID == message.requestID,
                  let continuation = continuations[event.requestID] else { return }
            continuation.yield(event)
            if event.isFinal {
                continuations.removeValue(forKey: event.requestID)
                if event.kind == .failed,
                   let remoteError = try? event.decodePayload(NexusRemoteErrorPayload.self) {
                    continuation.finish(throwing: NexusConnectError.requestFailed(remoteError.message))
                } else if event.kind == .cancelled {
                    continuation.finish(throwing: NexusConnectError.cancelled)
                } else {
                    continuation.finish()
                }
            }
        case .pong:
            break
        case .error:
            let remoteError = try message.decodePayload(NexusRemoteErrorPayload.self)
            if let requestID = message.requestID {
                continuations.removeValue(forKey: requestID)?.finish(
                    throwing: NexusConnectError.requestFailed(remoteError.message)
                )
            }
        default:
            throw NexusConnectError.malformedFrame
        }
    }

    private func finishAll(throwing error: Error) {
        let active = continuations.values
        continuations.removeAll()
        for continuation in active { continuation.finish(throwing: error) }
    }
}

actor NexusHostBackgroundJobRegistry {
    private var jobs: [UUID: Task<Void, Never>] = [:]

    func start(
        requestID: UUID,
        operation: @escaping @Sendable () async -> Void
    ) throws {
        guard jobs[requestID] == nil else {
            throw NexusConnectError.requestFailed("duplicate background request ID")
        }
        jobs[requestID] = Task { [weak self] in
            await operation()
            await self?.finished(requestID)
        }
    }

    func cancel(requestID: UUID) {
        jobs.removeValue(forKey: requestID)?.cancel()
    }

    func contains(requestID: UUID) -> Bool { jobs[requestID] != nil }

    private func finished(_ requestID: UUID) {
        jobs.removeValue(forKey: requestID)
    }
}

actor NexusConnectHostSession {
    private let transport: any NexusByteTransport
    private let vault: any NexusSessionCredentialProviding
    private let executor: NexusHostServiceExecutor
    private let backgroundJobs: NexusHostBackgroundJobRegistry
    private var connection: NexusFramedConnection?
    private var secureChannel: NexusSecureChannel?
    private var sessionID: UUID?
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var negotiatedProtocol = NexusConnectProtocol.currentVersion

    init(
        transport: any NexusByteTransport,
        vault: any NexusSessionCredentialProviding = NexusIdentityVault(role: .studioHost),
        executor: NexusHostServiceExecutor,
        backgroundJobs: NexusHostBackgroundJobRegistry = NexusHostBackgroundJobRegistry()
    ) {
        self.transport = transport
        self.vault = vault
        self.executor = executor
        self.backgroundJobs = backgroundJobs
    }

    func run() async throws {
        do {
            try await runAuthenticatedConnection()
            await close()
        } catch {
            await close()
            throw error
        }
    }

    private func runAuthenticatedConnection() async throws {
        guard var pairing = try vault.loadPairing() else {
            throw NexusConnectError.unavailable("Studio host has not been paired")
        }
        let identity = try vault.loadOrCreateIdentity()
        let framed = NexusFramedConnection(transport: transport)
        let requestData = try await framed.receivePayload(maximumBytes: NexusConnectProtocol.maximumControlFrameBytes)
        let request = try NexusPayloadCoder.decoder.decode(NexusHandshakeEnvelope.self, from: requestData)
        try NexusHandshake.verify(request.hello, pairing: pairing, expectedRole: .client)
        let negotiation = try NexusProtocolNegotiator.negotiate(
            remoteRange: request.hello.advertisedProtocolRange,
            remoteFeatures: request.hello.advertisedFeatures
        )
        pairing = try pairing.pinning(
            peerDeviceID: request.hello.deviceID,
            peerSigningPublicKey: request.hello.signingPublicKey
        )
        try vault.savePairing(pairing)
        let pending = try NexusHandshake.makeHello(
            identity: identity,
            role: .studioHost,
            pairing: pairing,
            respondingToNonce: request.hello.nonce
        )
        let key = try NexusHandshake.deriveSessionKey(
            local: pending,
            remote: request.hello,
            pairing: pairing,
            clientNonce: request.hello.nonce,
            hostNonce: pending.hello.nonce,
            sessionID: request.sessionID
        )
        try await framed.sendPayload(
            try NexusPayloadCoder.encoder.encode(NexusHandshakeEnvelope(
                sessionID: request.sessionID,
                hello: pending.hello
            )),
            maximumBytes: NexusConnectProtocol.maximumControlFrameBytes
        )
        connection = framed
        sessionID = request.sessionID
        secureChannel = NexusSecureChannel(
            sessionID: request.sessionID,
            key: key,
            outgoingDirection: .hostToClient,
            incomingDirection: .clientToHost,
            protocolVersion: negotiation.version
        )
        negotiatedProtocol = negotiation.version

        while !Task.isCancelled {
            let packet = try await framed.receivePayload()
            guard var channel = secureChannel else { return }
            let message = try channel.open(packet)
            secureChannel = channel
            try await handle(message)
        }
    }

    func close() async {
        for task in jobs.values { task.cancel() }
        jobs.removeAll()
        await transport.cancel()
        connection = nil
        secureChannel = nil
        sessionID = nil
        negotiatedProtocol = NexusConnectProtocol.currentVersion
    }

    private func handle(_ message: NexusConnectMessage) async throws {
        switch message.kind {
        case .request:
            let request = try message.decodePayload(NexusWorkloadRequest.self)
            guard message.requestID == request.id, jobs[request.id] == nil else {
                throw NexusConnectError.malformedFrame
            }
            if Self.survivesClientDisconnect(request.kind) {
                let executor = executor
                let send: @Sendable (NexusWorkloadEvent) async -> Void = { [weak self] event in
                    try? await self?.sendEvent(event)
                }
                try await backgroundJobs.start(requestID: request.id) {
                    await executor.execute(request, sink: send)
                }
            } else {
                jobs[request.id] = Task { [weak self] in
                    guard let self else { return }
                    await self.executor.execute(request) { event in
                        try? await self.sendEvent(event)
                    }
                    await self.removeJob(request.id)
                }
            }
        case .cancel:
            guard let requestID = message.requestID else { throw NexusConnectError.malformedFrame }
            jobs.removeValue(forKey: requestID)?.cancel()
            await backgroundJobs.cancel(requestID: requestID)
        case .ping:
            guard let sessionID else { return }
            let ping = try message.decodePayload(NexusPingPayload.self)
            try await send(kind: .pong, requestID: message.requestID, payload: ping, sessionID: sessionID)
        default:
            throw NexusConnectError.malformedFrame
        }
    }

    private func sendEvent(_ event: NexusWorkloadEvent) async throws {
        guard let sessionID else { return }
        try await send(kind: .event, requestID: event.requestID, payload: event, sessionID: sessionID)
    }

    private func send<Payload: Encodable>(
        kind: NexusMessageKind,
        requestID: UUID?,
        payload: Payload,
        sessionID: UUID
    ) async throws {
        guard let connection, var channel = secureChannel else {
            throw NexusConnectError.unavailable("host session closed")
        }
        let message = try NexusConnectMessage(
            protocolVersion: negotiatedProtocol,
            sessionID: sessionID,
            kind: kind,
            requestID: requestID,
            payload: payload
        )
        let framed = try channel.seal(message)
        secureChannel = channel
        try await connection.sendFramed(framed)
    }

    private func removeJob(_ id: UUID) { jobs.removeValue(forKey: id) }

    static func survivesClientDisconnect(_ kind: NexusWorkloadKind) -> Bool {
        kind == .modelPull || kind == .download
    }
}

final class NexusConnectHostListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nexus.connect.listener", qos: .userInitiated)
    private let lock = NSLock()
    private let vault: any NexusSessionCredentialProviding
    private let executor: NexusHostServiceExecutor
    private let backgroundJobs = NexusHostBackgroundJobRegistry()
    private var listener: NWListener?
    private var sessions: [UUID: Task<Void, Never>] = [:]

    init(
        vault: any NexusSessionCredentialProviding = NexusIdentityVault(role: .studioHost),
        executor: NexusHostServiceExecutor
    ) {
        self.vault = vault
        self.executor = executor
    }

    func start() async throws {
        let port = NWEndpoint.Port(rawValue: NexusConnectProtocol.servicePort)!
        let newListener = try NWListener(using: .tcp, on: port)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = NexusContinuationGate(continuation)
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.succeed()
                case .failed(let error): gate.fail(NexusConnectError.unavailable(error.localizedDescription))
                case .cancelled: gate.fail(NexusConnectError.cancelled)
                default: break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            lock.lock()
            listener?.cancel()
            listener = newListener
            lock.unlock()
            newListener.start(queue: queue)
        }
    }

    func stop() {
        lock.lock()
        let activeListener = listener
        listener = nil
        let activeSessions = sessions.values
        sessions.removeAll()
        lock.unlock()
        activeListener?.cancel()
        for task in activeSessions { task.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isTailnetEndpoint(connection.endpoint) else {
            connection.cancel()
            return
        }
        let id = UUID()
        let transport = NexusNWConnectionTransport(acceptedConnection: connection)
        let task = Task { [weak self] in
            do {
                try await transport.startAcceptedConnection()
                guard let self else { return }
                let session = NexusConnectHostSession(
                    transport: transport,
                    vault: self.vault,
                    executor: self.executor,
                    backgroundJobs: self.backgroundJobs
                )
                try await session.run()
            } catch {
                await transport.cancel()
            }
            self?.removeSession(id)
        }
        lock.lock()
        sessions[id] = task
        lock.unlock()
    }

    private func removeSession(_ id: UUID) {
        lock.lock()
        sessions.removeValue(forKey: id)
        lock.unlock()
    }

    static func isTailnetEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let value = "\(host)".lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value.hasSuffix(".ts.net") || value.hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = value.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
}
