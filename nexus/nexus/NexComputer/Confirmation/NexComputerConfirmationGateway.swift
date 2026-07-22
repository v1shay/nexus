import CryptoKit
import Foundation

private func nexComputerPendingActionDefaultFileURL() -> URL {
    let fileManager = FileManager.default
    let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    return root
        .appendingPathComponent("Nexus/NexComputer", isDirectory: true)
        .appendingPathComponent("pending-actions.json")
}

enum NexComputerPendingActionStatus: String, Codable, Sendable {
    case pending
    case executing
    case completed
    case failed
    case cancelled
    case expired
    case interrupted
}

struct NexComputerPendingActionAuditEvent: Codable, Equatable, Sendable {
    let status: NexComputerPendingActionStatus
    let occurredAt: Date
    let code: String?
}

struct NexComputerPendingAction: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let actionID: String
    let arguments: [String: NexJSONValue]
    let payloadDigest: String
    let provider: String
    let riskClass: NexComputerRiskClass
    let summary: String
    let exactEffect: String
    let idempotencyKey: UUID
    let createdAt: Date
    let expiresAt: Date
    var status: NexComputerPendingActionStatus
    var auditHistory: [NexComputerPendingActionAuditEvent]
}

actor NexComputerPendingActionStore {
    private struct Snapshot: Codable {
        let schemaVersion: Int
        let records: [NexComputerPendingAction]
    }

    private let fileURL: URL
    private var records: [UUID: NexComputerPendingAction]

    init(fileURL: URL? = nil) {
        let resolvedURL = fileURL ?? nexComputerPendingActionDefaultFileURL()
        var loadedRecords = Self.load(from: resolvedURL)
        let now = Date()
        for (id, record) in loadedRecords {
            if record.status == .executing {
                var recovered = record
                recovered.status = .interrupted
                recovered.auditHistory.append(.init(status: .interrupted, occurredAt: now, code: "restart_during_execution"))
                loadedRecords[id] = recovered
            } else if record.status == .pending, record.expiresAt <= now {
                var expired = record
                expired.status = .expired
                expired.auditHistory.append(.init(status: .expired, occurredAt: now, code: "expired_during_restart"))
                loadedRecords[id] = expired
            }
        }
        self.fileURL = resolvedURL
        self.records = loadedRecords
        try? Self.persist(records: loadedRecords, to: resolvedURL)
    }

    func save(_ record: NexComputerPendingAction) throws {
        records[record.id] = record
        try persist()
    }

    func record(id: UUID) -> NexComputerPendingAction? { records[id] }

    func activeRecord(actionID: String, payloadDigest: String, now: Date = .now) -> NexComputerPendingAction? {
        records.values
            .filter {
                $0.actionID == actionID
                    && $0.payloadDigest == payloadDigest
                    && $0.status == .pending
                    && $0.expiresAt > now
            }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    func update(
        id: UUID,
        status: NexComputerPendingActionStatus,
        code: String? = nil,
        now: Date = .now
    ) throws -> NexComputerPendingAction {
        guard var record = records[id] else { throw NexComputerConfirmationError.notFound(id) }
        record.status = status
        record.auditHistory.append(.init(status: status, occurredAt: now, code: code))
        records[id] = record
        try persist()
        return record
    }

    func recoverable(now: Date = .now) throws -> [NexComputerPendingAction] {
        var changed = false
        for (id, record) in records where record.status == .pending && record.expiresAt <= now {
            var expired = record
            expired.status = .expired
            expired.auditHistory.append(.init(status: .expired, occurredAt: now, code: "expired"))
            records[id] = expired
            changed = true
        }
        if changed { try persist() }
        return records.values
            .filter { $0.status == .pending && $0.expiresAt > now }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func allRecords() -> [NexComputerPendingAction] {
        records.values.sorted { $0.createdAt < $1.createdAt }
    }

    private func persist() throws {
        try Self.persist(records: records, to: fileURL)
    }

    nonisolated private static func load(from url: URL) -> [UUID: NexComputerPendingAction] {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(Snapshot.self, from: data),
              snapshot.schemaVersion == NexComputerPendingAction.currentSchemaVersion else { return [:] }
        return Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
    }

    nonisolated private static func persist(
        records: [UUID: NexComputerPendingAction],
        to url: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let snapshot = Snapshot(
            schemaVersion: NexComputerPendingAction.currentSchemaVersion,
            records: records.values.sorted { $0.createdAt < $1.createdAt }
        )
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    nonisolated private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum NexComputerConfirmationError: LocalizedError, Equatable {
    case notFound(UUID)
    case expired(UUID)
    case payloadChanged(UUID)
    case alreadyConsumed(UUID, NexComputerPendingActionStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:
            "That pending action no longer exists."
        case .expired:
            "That confirmation expired. Please issue the action again."
        case .payloadChanged:
            "The action or its arguments changed after confirmation was requested."
        case .alreadyConsumed(_, let status):
            "That confirmation has already been consumed (\(status.rawValue))."
        }
    }
}

actor NexComputerConfirmationGateway {
    static let defaultLifetime: TimeInterval = 5 * 60

    private let store: NexComputerPendingActionStore
    private let lifetime: TimeInterval

    init(
        store: NexComputerPendingActionStore = NexComputerPendingActionStore(),
        lifetime: TimeInterval = defaultLifetime
    ) {
        self.store = store
        self.lifetime = max(1, lifetime)
    }

    func request(
        manifest: NexComputerActionManifest,
        arguments: [String: NexJSONValue],
        now: Date = .now
    ) async throws -> NexComputerPendingAction {
        let digest = try Self.payloadDigest(manifest: manifest, arguments: arguments)
        if let existing = await store.activeRecord(actionID: manifest.actionID, payloadDigest: digest, now: now) {
            return existing
        }
        let record = NexComputerPendingAction(
            schemaVersion: NexComputerPendingAction.currentSchemaVersion,
            id: UUID(),
            actionID: manifest.actionID,
            arguments: arguments,
            payloadDigest: digest,
            provider: manifest.provider,
            riskClass: manifest.riskClass,
            summary: "\(manifest.application): \(manifest.description)",
            exactEffect: Self.exactEffect(manifest: manifest, arguments: arguments),
            idempotencyKey: UUID(),
            createdAt: now,
            expiresAt: now.addingTimeInterval(lifetime),
            status: .pending,
            auditHistory: [.init(status: .pending, occurredAt: now, code: nil)]
        )
        try await store.save(record)
        return record
    }

    func authorize(
        id: UUID,
        expectedManifest: NexComputerActionManifest? = nil,
        expectedArguments: [String: NexJSONValue]? = nil,
        now: Date = .now
    ) async throws -> NexComputerPendingAction {
        guard let record = await store.record(id: id) else {
            throw NexComputerConfirmationError.notFound(id)
        }
        guard record.expiresAt > now else {
            _ = try? await store.update(id: id, status: .expired, code: "expired", now: now)
            throw NexComputerConfirmationError.expired(id)
        }
        guard record.status == .pending else {
            throw NexComputerConfirmationError.alreadyConsumed(id, record.status)
        }
        if let expectedManifest, expectedManifest.actionID != record.actionID {
            throw NexComputerConfirmationError.payloadChanged(id)
        }
        if let expectedManifest, let expectedArguments {
            let digest = try Self.payloadDigest(manifest: expectedManifest, arguments: expectedArguments)
            guard digest == record.payloadDigest else {
                throw NexComputerConfirmationError.payloadChanged(id)
            }
        }
        return try await store.update(id: id, status: .executing, code: "confirmed", now: now)
    }

    func complete(id: UUID, now: Date = .now) async throws {
        _ = try await store.update(id: id, status: .completed, code: nil, now: now)
    }

    func fail(id: UUID, code: String, now: Date = .now) async throws {
        _ = try await store.update(id: id, status: .failed, code: code, now: now)
    }

    func cancel(id: UUID, now: Date = .now) async throws {
        guard let record = await store.record(id: id) else {
            throw NexComputerConfirmationError.notFound(id)
        }
        guard record.status == .pending else {
            throw NexComputerConfirmationError.alreadyConsumed(id, record.status)
        }
        _ = try await store.update(id: id, status: .cancelled, code: "user_cancelled", now: now)
    }

    func recoverable(now: Date = .now) async throws -> [NexComputerPendingAction] {
        try await store.recoverable(now: now)
    }

    func pending(id: UUID) async -> NexComputerPendingAction? {
        await store.record(id: id)
    }

    private static func payloadDigest(
        manifest: NexComputerActionManifest,
        arguments: [String: NexJSONValue]
    ) throws -> String {
        let payload: NexJSONValue = .object([
            "action": .string(manifest.actionID),
            "provider": .string(manifest.provider),
            "risk": .string(manifest.riskClass.rawValue),
            "arguments": .object(arguments)
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func exactEffect(
        manifest: NexComputerActionManifest,
        arguments: [String: NexJSONValue]
    ) -> String {
        let details = arguments.keys.sorted().map { key in
            "\(key): \(displayValue(arguments[key] ?? .null))"
        }.joined(separator: ", ")
        return details.isEmpty
            ? "Run \(manifest.actionID) in \(manifest.application)."
            : "Run \(manifest.actionID) in \(manifest.application) with \(details)."
    }

    private static func displayValue(_ value: NexJSONValue) -> String {
        switch value {
        case .string(let value): return "“\(value)”"
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "none"
        case .array(let values): return "[\(values.map(displayValue).joined(separator: ", "))]"
        case .object(let values):
            return "{\(values.keys.sorted().map { "\($0): \(displayValue(values[$0] ?? .null))" }.joined(separator: ", "))}"
        }
    }
}
