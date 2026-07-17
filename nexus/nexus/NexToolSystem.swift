import Foundation

enum NexJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([NexJSONValue])
    case object([String: NexJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([NexJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: NexJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }
    var strings: [String]? {
        guard case .array(let values) = self else { return nil }
        let strings = values.compactMap(\.string)
        return strings.count == values.count ? strings : nil
    }
}

enum NexToolFieldType: String, Codable, Sendable {
    case string
    case integer
    case number
    case boolean
    case stringArray = "string_array"
}

struct NexToolFieldSchema: Codable, Equatable, Sendable {
    let type: NexToolFieldType
    let required: Bool
    let allowedValues: [String]
    let minimum: Double?
    let maximum: Double?

    init(
        _ type: NexToolFieldType,
        required: Bool = false,
        allowedValues: [String] = [],
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        self.type = type
        self.required = required
        self.allowedValues = allowedValues
        self.minimum = minimum
        self.maximum = maximum
    }
}

struct NexToolInputSchema: Codable, Equatable, Sendable {
    let version: Int
    let fields: [String: NexToolFieldSchema]
    let rejectUnknownFields: Bool

    init(fields: [String: NexToolFieldSchema], rejectUnknownFields: Bool = true) {
        version = 1
        self.fields = fields
        self.rejectUnknownFields = rejectUnknownFields
    }

    func validate(_ arguments: [String: NexJSONValue]) throws {
        if rejectUnknownFields, let unknown = Set(arguments.keys).subtracting(fields.keys).sorted().first {
            throw NexToolError.unknownField(unknown)
        }
        if let missing = fields.first(where: { $0.value.required && arguments[$0.key] == nil })?.key {
            throw NexToolError.missingField(missing)
        }
        for (name, value) in arguments {
            guard let field = fields[name] else { continue }
            let valid: Bool
            switch field.type {
            case .string: valid = value.string != nil
            case .integer: valid = value.integer != nil
            case .number: if case .number = value { valid = true } else { valid = false }
            case .boolean: if case .bool = value { valid = true } else { valid = false }
            case .stringArray: valid = value.strings != nil
            }
            guard valid else { throw NexToolError.invalidType(field: name, expected: field.type) }
            if !field.allowedValues.isEmpty, let string = value.string,
               !field.allowedValues.contains(string) {
                throw NexToolError.invalidEnum(field: name, allowed: field.allowedValues)
            }
            let number: Double? = switch value {
            case .number(let number): number
            default: nil
            }
            if let number, let minimum = field.minimum, number < minimum {
                throw NexToolError.outOfRange(field: name, minimum: minimum, maximum: field.maximum)
            }
            if let number, let maximum = field.maximum, number > maximum {
                throw NexToolError.outOfRange(field: name, minimum: field.minimum, maximum: maximum)
            }
        }
    }
}

enum NexToolPermission: String, Codable, Sendable {
    case readMemory = "read_memory"
    case writeMemory = "write_memory"
    case forgetMemory = "forget_memory"
    case network
    case files
    case codeExecution = "code_execution"
}

enum NexToolInvocationSource: String, Codable, Sendable {
    case app
    case model
}

struct NexToolInvocation: Sendable {
    let source: NexToolInvocationSource
    let userAuthorizedWrite: Bool

    static let app = NexToolInvocation(source: .app, userAuthorizedWrite: true)
    static let modelReadOnly = NexToolInvocation(source: .model, userAuthorizedWrite: false)
}

enum NexToolLifecyclePhase: String, Codable, Equatable, Sendable {
    case started
    case progress
    case completed
    case failed
}

struct NexToolLifecycleEvent: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { executionID }
    let executionID: UUID
    let toolName: String
    let phase: NexToolLifecyclePhase
    let message: String
    let progress: Double?
    let errorCode: String?
    let occurredAt: Date
}

actor NexToolEventBus {
    private var continuations: [UUID: AsyncStream<NexToolLifecycleEvent>.Continuation] = [:]

    func events() -> AsyncStream<NexToolLifecycleEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    func emit(_ event: NexToolLifecycleEvent) {
        continuations.values.forEach { $0.yield(event) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

struct NexToolExecutionContext: Sendable {
    let executionID: UUID
    let reportProgress: @Sendable (String, Double?) async -> Void
}

struct NexRegisteredTool: Sendable {
    typealias Handler = @Sendable ([String: NexJSONValue], NexToolExecutionContext) async throws -> NexJSONValue

    let name: String
    let description: String
    let statusLabel: String
    let completionLabel: String
    let spokenStatus: String
    let iconSystemName: String
    let permission: NexToolPermission
    let schema: NexToolInputSchema
    let handler: Handler

    init(
        name: String,
        description: String,
        statusLabel: String,
        completionLabel: String? = nil,
        spokenStatus: String,
        iconSystemName: String,
        permission: NexToolPermission,
        schema: NexToolInputSchema,
        handler: @escaping Handler
    ) {
        self.name = name
        self.description = description
        self.statusLabel = statusLabel
        self.completionLabel = completionLabel
            ?? "Used \(name.replacingOccurrences(of: "_", with: " "))"
        self.spokenStatus = spokenStatus
        self.iconSystemName = iconSystemName
        self.permission = permission
        self.schema = schema
        self.handler = handler
    }
}

enum NexToolError: LocalizedError, Equatable {
    case notFound(String)
    case duplicateRegistration(String)
    case unknownField(String)
    case missingField(String)
    case invalidType(field: String, expected: NexToolFieldType)
    case invalidEnum(field: String, allowed: [String])
    case outOfRange(field: String, minimum: Double?, maximum: Double?)
    case permissionDenied(NexToolPermission)
    case invalidStableID(String)
    case executionFailed(code: String, message: String)

    var code: String {
        switch self {
        case .notFound: "tool_not_found"
        case .duplicateRegistration: "duplicate_registration"
        case .unknownField: "unknown_field"
        case .missingField: "missing_field"
        case .invalidType: "invalid_type"
        case .invalidEnum: "invalid_enum"
        case .outOfRange: "out_of_range"
        case .permissionDenied: "permission_denied"
        case .invalidStableID: "invalid_stable_id"
        case .executionFailed(let code, _): code
        }
    }

    var errorDescription: String? {
        switch self {
        case .notFound(let name): "Unknown tool: \(name)."
        case .duplicateRegistration(let name): "Tool \(name) is already registered."
        case .unknownField(let field): "Unknown input field: \(field)."
        case .missingField(let field): "Missing required input field: \(field)."
        case .invalidType(let field, let type): "Input \(field) must be \(type.rawValue)."
        case .invalidEnum(let field, let allowed): "Input \(field) must be one of: \(allowed.joined(separator: ", "))."
        case .outOfRange(let field, let minimum, let maximum):
            "Input \(field) is outside the allowed range \(minimum.map { String($0) } ?? "-")…\(maximum.map { String($0) } ?? "+")."
        case .permissionDenied(let permission): "Tool permission \(permission.rawValue) was not granted."
        case .invalidStableID(let value): "\(value) is not a valid stable memory ID."
        case .executionFailed(_, let message): message
        }
    }
}

actor NexToolRegistry {
    let events: NexToolEventBus
    private var tools: [String: NexRegisteredTool] = [:]

    init(events: NexToolEventBus = NexToolEventBus()) {
        self.events = events
    }

    func register(_ tool: NexRegisteredTool) throws {
        guard tools[tool.name] == nil else { throw NexToolError.duplicateRegistration(tool.name) }
        tools[tool.name] = tool
    }

    func definitions() -> [NexRegisteredTool] {
        tools.values.sorted { $0.name < $1.name }
    }

    func execute(
        name: String,
        arguments: [String: NexJSONValue],
        invocation: NexToolInvocation = .app
    ) async throws -> NexJSONValue {
        guard let tool = tools[name] else { throw NexToolError.notFound(name) }
        try tool.schema.validate(arguments)
        if invocation.source == .model,
           (tool.permission == .writeMemory || tool.permission == .forgetMemory),
           !invocation.userAuthorizedWrite {
            throw NexToolError.permissionDenied(tool.permission)
        }
        let executionID = UUID()
        await events.emit(.init(
            executionID: executionID,
            toolName: name,
            phase: .started,
            message: tool.statusLabel,
            progress: nil,
            errorCode: nil,
            occurredAt: Date()
        ))
        let eventBus = events
        let context = NexToolExecutionContext(executionID: executionID) { message, progress in
            await eventBus.emit(.init(
                executionID: executionID,
                toolName: name,
                phase: .progress,
                message: message,
                progress: progress,
                errorCode: nil,
                occurredAt: Date()
            ))
        }
        do {
            let result = try await tool.handler(arguments, context)
            await events.emit(.init(
                executionID: executionID,
                toolName: name,
                phase: .completed,
                message: Self.completionMessage(label: tool.completionLabel, result: result),
                progress: 1,
                errorCode: nil,
                occurredAt: Date()
            ))
            return result
        } catch {
            let toolError = error as? NexToolError
            await events.emit(.init(
                executionID: executionID,
                toolName: name,
                phase: .failed,
                message: error.localizedDescription,
                progress: nil,
                errorCode: toolError?.code ?? "tool_execution_failed",
                occurredAt: Date()
            ))
            throw error
        }
    }

    private static func completionMessage(label: String, result: NexJSONValue) -> String {
        guard case .object(let object) = result,
              case .number(let rawCount) = object["count"] else { return label }
        let count = max(0, Int(rawCount))
        return "\(label) · \(count) source\(count == 1 ? "" : "s")"
    }
}
