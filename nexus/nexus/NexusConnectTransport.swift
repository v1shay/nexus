import Foundation
import Network

protocol NexusByteTransport: Sendable {
    func connect(host: String, port: UInt16) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func cancel() async
}

final class NexusNWConnectionTransport: NexusByteTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nexus.connect.transport", qos: .userInitiated)
    private let lock = NSLock()
    private var connection: NWConnection?

    init() {}

    init(acceptedConnection: NWConnection) {
        connection = acceptedConnection
    }

    func connect(host: String, port: UInt16) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NexusConnectError.unavailable("invalid Nexus Connect port")
        }
        let newConnection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        replaceConnection(with: newConnection)

        try await start(newConnection)
    }

    func startAcceptedConnection() async throws {
        try await start(currentConnection())
    }

    func send(_ data: Data) async throws {
        let activeConnection = try currentConnection()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            activeConnection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: NexusConnectError.unavailable(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> Data {
        let activeConnection = try currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            activeConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: NexusConnectError.unavailable(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if complete {
                    continuation.resume(throwing: NexusConnectError.unavailable("Mac Studio closed the connection"))
                } else {
                    continuation.resume(throwing: NexusConnectError.unavailable("empty network read"))
                }
            }
        }
    }

    func cancel() async {
        takeConnection()?.cancel()
    }

    private func currentConnection() throws -> NWConnection {
        lock.lock()
        defer { lock.unlock() }
        guard let connection else { throw NexusConnectError.unavailable("not connected") }
        return connection
    }

    private func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = NexusContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    gate.succeed()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    gate.fail(NexusConnectError.unavailable(error.localizedDescription))
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    gate.fail(NexusConnectError.cancelled)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func replaceConnection(with newConnection: NWConnection) {
        lock.lock()
        let previousConnection = connection
        connection = newConnection
        lock.unlock()
        previousConnection?.cancel()
    }

    private func takeConnection() -> NWConnection? {
        lock.lock()
        let activeConnection = connection
        connection = nil
        lock.unlock()
        return activeConnection
    }
}

final class NexusContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func succeed() { finish(.success(())) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard let savedContinuation = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()
        savedContinuation.resume(with: result)
    }
}
