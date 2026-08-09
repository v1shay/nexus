import AppKit
import Foundation

enum NexComputerExecutionStatus: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
    case timedOut = "timed_out"
    case dryRun = "dry_run"
    case unavailable
    case confirmationRequired = "confirmation_required"
    case permissionRequired = "permission_required"
}

struct NexComputerStructuredError: Codable, Equatable, Sendable {
    let code: String
    let message: String
    let permission: String?
    let recovery: String?
    let retryable: Bool
}

struct NexComputerResultEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let executionID: UUID
    let ok: Bool
    let action: String
    let status: NexComputerExecutionStatus
    let data: NexJSONValue
    let display: String
    let warnings: [String]
    let durationMs: Int
    let error: NexComputerStructuredError?
}

struct NexComputerAvailability: Equatable, Sendable {
    let isAvailable: Bool
    let reason: String?
    let recovery: String?

    static let available = NexComputerAvailability(isAvailable: true, reason: nil, recovery: nil)

    static func unavailable(_ reason: String, recovery: String? = nil) -> Self {
        .init(isAvailable: false, reason: reason, recovery: recovery)
    }
}

struct NexComputerActionFailure: LocalizedError, Equatable, Sendable {
    let code: String
    let message: String
    let permission: String?
    let recovery: String?
    let retryable: Bool

    init(
        code: String,
        message: String,
        permission: String? = nil,
        recovery: String? = nil,
        retryable: Bool = false
    ) {
        self.code = code
        self.message = message
        self.permission = permission
        self.recovery = recovery
        self.retryable = retryable
    }

    var errorDescription: String? { message }
}

struct NexComputerExecutionOptions: Sendable {
    let dryRun: Bool
    let timeoutOverrideSeconds: Double?
    let invocation: NexToolInvocation

    init(
        dryRun: Bool = false,
        timeoutOverrideSeconds: Double? = nil,
        invocation: NexToolInvocation = .app
    ) {
        self.dryRun = dryRun
        self.timeoutOverrideSeconds = timeoutOverrideSeconds
        self.invocation = invocation
    }
}

struct NexComputerActionLogEntry: Codable, Equatable, Sendable {
    let executionID: UUID
    let actionID: String
    let status: NexComputerExecutionStatus
    let argumentKeys: [String]
    let dryRun: Bool
    let errorCode: String?
    let durationMs: Int
    let occurredAt: Date
}

actor NexComputerActionLogger {
    private let capacity: Int
    private var entries: [NexComputerActionLogEntry] = []

    init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    func record(_ entry: NexComputerActionLogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func recentEntries() -> [NexComputerActionLogEntry] { entries }
}

actor NexComputerRegistry {
    typealias AvailabilityProbe = @Sendable () async -> NexComputerAvailability

    private struct Entry: Sendable {
        let manifest: NexComputerActionManifest
        let availability: AvailabilityProbe
        let handler: NexRegisteredTool.Handler
    }

    private let toolRegistry: NexToolRegistry
    private let confirmationGateway: NexComputerConfirmationGateway
    private let permissionManager: NexComputerPermissionManager
    private var entries: [String: Entry] = [:]
    private var controlToolsRegistered = false

    init(
        toolRegistry: NexToolRegistry,
        confirmationGateway: NexComputerConfirmationGateway = NexComputerConfirmationGateway(),
        permissionManager: NexComputerPermissionManager = NexComputerPermissionManager()
    ) {
        self.toolRegistry = toolRegistry
        self.confirmationGateway = confirmationGateway
        self.permissionManager = permissionManager
    }

    func register(
        manifest: NexComputerActionManifest,
        availability: AvailabilityProbe? = nil,
        handler: @escaping NexRegisteredTool.Handler
    ) async throws {
        try manifest.validate()
        guard entries[manifest.actionID] == nil else {
            throw NexToolError.duplicateRegistration(manifest.actionID)
        }

        try await registerControlToolsIfNeeded()
        let probe = availability ?? Self.defaultAvailabilityProbe(for: manifest.availabilityCheck)
        let registry = self
        let tool = NexRegisteredTool(
            name: manifest.actionID,
            description: manifest.description,
            statusLabel: "Using \(manifest.application)…",
            completionLabel: "Used \(manifest.application)",
            spokenStatus: "Using \(manifest.application)",
            iconSystemName: "app.badge",
            permission: manifest.registryPermission,
            schema: manifest.inputSchema,
            application: manifest.application,
            provider: manifest.provider,
            examples: manifest.examples,
            aliases: manifest.aliases,
            tags: manifest.tags,
            supportedWorkflows: manifest.examples,
            handler: { arguments, context in
                try await registry.invoke(
                    actionID: manifest.actionID,
                    arguments: arguments,
                    invocation: .modelReadOnly,
                    context: context
                )
            }
        )
        try await toolRegistry.register(tool)
        entries[manifest.actionID] = Entry(manifest: manifest, availability: probe, handler: handler)
    }

    func manifests() -> [NexComputerActionManifest] {
        entries.values.map(\.manifest).sorted { $0.actionID < $1.actionID }
    }

    func contains(actionID: String) -> Bool {
        entries[actionID] != nil
    }

    func manifest(actionID: String) throws -> NexComputerActionManifest {
        guard let entry = entries[actionID] else { throw NexToolError.notFound(actionID) }
        return entry.manifest
    }

    func availability(actionID: String) async throws -> NexComputerAvailability {
        guard let entry = entries[actionID] else { throw NexToolError.notFound(actionID) }
        return await entry.availability()
    }

    func availabilitySnapshot() async -> [String: NexComputerAvailability] {
        var snapshot: [String: NexComputerAvailability] = [:]
        for (actionID, entry) in entries {
            snapshot[actionID] = await entry.availability()
        }
        return snapshot
    }

    func execute(
        actionID: String,
        arguments: [String: NexJSONValue],
        invocation: NexToolInvocation
    ) async throws -> NexJSONValue {
        try await toolRegistry.execute(name: actionID, arguments: arguments, invocation: invocation)
    }

    func recoverablePendingActions() async throws -> [NexComputerPendingAction] {
        try await confirmationGateway.recoverable()
    }

    private func invoke(
        actionID: String,
        arguments: [String: NexJSONValue],
        invocation: NexToolInvocation,
        context: NexToolExecutionContext
    ) async throws -> NexJSONValue {
        guard let entry = entries[actionID] else { throw NexToolError.notFound(actionID) }
        try entry.manifest.inputSchema.validate(arguments)
        let availability = await entry.availability()
        guard availability.isAvailable else {
            throw NexComputerActionFailure(
                code: "UNAVAILABLE",
                message: availability.reason ?? "Action is unavailable.",
                recovery: availability.recovery
            )
        }
        do {
            try await permissionManager.authorize(entry.manifest.requiredPermissions)
        } catch let failure as NexComputerPermissionFailure {
            return Self.permissionRequiredJSON(failure.status)
        }
        if Self.requiresConfirmation(entry.manifest) {
            let pending = try await confirmationGateway.request(
                manifest: entry.manifest,
                arguments: arguments
            )
            return Self.confirmationRequiredJSON(pending)
        }
        return try await entry.handler(arguments, context)
    }

    private func confirm(actionID: UUID, context: NexToolExecutionContext) async throws -> NexJSONValue {
        guard let preview = await confirmationGateway.pending(id: actionID) else {
            throw NexComputerConfirmationError.notFound(actionID)
        }
        guard let entry = entries[preview.actionID] else {
            try? await confirmationGateway.fail(id: actionID, code: "action_unavailable_after_restart")
            throw NexToolError.notFound(preview.actionID)
        }
        let pending = try await confirmationGateway.authorize(
            id: actionID,
            expectedManifest: entry.manifest,
            expectedArguments: preview.arguments
        )
        do {
            let result = try await entry.handler(pending.arguments, context)
            try await confirmationGateway.complete(id: actionID)
            return result
        } catch {
            try? await confirmationGateway.fail(id: actionID, code: "execution_failed")
            throw error
        }
    }

    private func registerControlToolsIfNeeded() async throws {
        guard !controlToolsRegistered else { return }
        let registry = self
        do {
            try await toolRegistry.register(.init(
                name: "confirm_action",
                description: "Confirm and execute one exact pending Nex action. The opaque action_id must come from a confirmation_required result.",
                statusLabel: "Confirming action…",
                completionLabel: "Confirmed action",
                spokenStatus: "Confirming that action.",
                iconSystemName: "checkmark.circle",
                permission: .automation,
                schema: .init(fields: [
                    "actionId": .init(.string, required: true, description: "Opaque pending action ID returned by Nexus.")
                ]),
                application: "Nex",
                provider: "Nexus Confirmation Gateway",
                examples: ["Confirm the pending action"],
                aliases: ["approve action", "confirm pending action"],
                tags: ["confirmation", "approval", "pending action"]
            ) { arguments, context in
                guard let raw = arguments["actionId"]?.string, let id = UUID(uuidString: raw) else {
                    throw NexToolError.executionFailed(code: "invalid_action_id", message: "The pending action ID is invalid.")
                }
                return try await registry.confirm(actionID: id, context: context)
            })
            try await toolRegistry.register(.init(
                name: "cancel_action",
                description: "Cancel one exact pending Nex action before it executes.",
                statusLabel: "Cancelling action…",
                completionLabel: "Cancelled action",
                spokenStatus: "Cancelling that action.",
                iconSystemName: "xmark.circle",
                permission: .automation,
                schema: .init(fields: [
                    "actionId": .init(.string, required: true, description: "Opaque pending action ID returned by Nexus.")
                ]),
                application: "Nex",
                provider: "Nexus Confirmation Gateway",
                examples: ["Cancel the pending action"],
                aliases: ["reject action", "cancel pending action"],
                tags: ["confirmation", "cancel", "pending action"]
            ) { arguments, _ in
                guard let raw = arguments["actionId"]?.string, let id = UUID(uuidString: raw) else {
                    throw NexToolError.executionFailed(code: "invalid_action_id", message: "The pending action ID is invalid.")
                }
                try await registry.confirmationGateway.cancel(id: id)
                return .object(["status": .string("cancelled"), "actionId": .string(id.uuidString)])
            })
            controlToolsRegistered = true
        } catch NexToolError.duplicateRegistration(_) {
            controlToolsRegistered = true
        }
    }

    private static func requiresConfirmation(_ manifest: NexComputerActionManifest) -> Bool {
        if manifest.riskClass == .high { return true }
        switch manifest.confirmationPolicy {
        case .always: return true
        case .whenRequired: return manifest.riskClass != .low
        case .never: return false
        }
    }

    private static func confirmationRequiredJSON(_ pending: NexComputerPendingAction) -> NexJSONValue {
        .object([
            "status": .string("confirmation_required"),
            "actionId": .string(pending.id.uuidString),
            "summary": .string(pending.summary),
            "exactEffect": .string(pending.exactEffect),
            "expiresAt": .string(ISO8601DateFormatter().string(from: pending.expiresAt))
        ])
    }

    private static func permissionRequiredJSON(_ status: NexComputerPermissionStatus) -> NexJSONValue {
        .object([
            "status": .string("permission_required"),
            "permission": .string(status.requirementID),
            "state": .string(status.state.rawValue),
            "recovery": status.recovery.map(NexJSONValue.string) ?? .null
        ])
    }

    private static func defaultAvailabilityProbe(
        for check: NexComputerAvailabilityCheck
    ) -> AvailabilityProbe {
        switch check.kind {
        case .always:
            return { .available }
        case .application:
            let bundleIdentifier = check.bundleIdentifier ?? ""
            return {
                guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil else {
                    return .unavailable("Required application is not installed: \(bundleIdentifier).")
                }
                return .available
            }
        case .executable:
            let paths = check.executablePaths
            return {
                let found = paths.contains { FileManager.default.isExecutableFile(atPath: $0) }
                return found
                    ? .available
                    : .unavailable("Required executable was not found.", recovery: "Install or configure one of: \(paths.joined(separator: ", ")).")
            }
        case .custom:
            let identifier = check.identifier ?? "custom"
            return {
                .unavailable(
                    "Availability probe \(identifier) was not registered.",
                    recovery: "Register the action with its deterministic availability probe."
                )
            }
        case .unsupported:
            let reason = check.reason ?? "This action is unsupported."
            return { .unavailable(reason) }
        }
    }
}

actor NexComputerRuntime {
    private struct RunningExecution {
        let task: Task<NexJSONValue, Error>
        let supportsCancellation: Bool
    }

    private enum RuntimeFailure: Error {
        case timedOut
        case invalidOutput(String)
    }

    private let registry: NexComputerRegistry
    private let logger: NexComputerActionLogger
    private var running: [UUID: RunningExecution] = [:]

    init(registry: NexComputerRegistry, logger: NexComputerActionLogger = NexComputerActionLogger()) {
        self.registry = registry
        self.logger = logger
    }

    /// Model-originated computer actions use the same timeout, retry,
    /// cancellation, availability and output-validation boundary as CLI
    /// actions. Confirmation and permission results remain structured so the
    /// planner can present their exact recovery instead of fabricating one.
    func executeForModel(
        actionID: String,
        arguments: [String: NexJSONValue]
    ) async throws -> NexJSONValue {
        let envelope = await execute(
            actionID: actionID,
            arguments: arguments,
            options: .init(invocation: .modelReadOnly)
        )
        switch envelope.status {
        case .completed, .dryRun, .confirmationRequired, .permissionRequired:
            return envelope.data
        case .failed, .cancelled, .timedOut, .unavailable:
            let failure = envelope.error
            throw NexComputerActionFailure(
                code: failure?.code ?? envelope.status.rawValue.uppercased(),
                message: failure?.message ?? envelope.display,
                permission: failure?.permission,
                recovery: failure?.recovery,
                retryable: failure?.retryable ?? false
            )
        }
    }

    func execute(
        actionID: String,
        arguments: [String: NexJSONValue],
        executionID: UUID = UUID(),
        options: NexComputerExecutionOptions = .init()
    ) async -> NexComputerResultEnvelope {
        let startedAt = Date()
        var manifest: NexComputerActionManifest?

        do {
            let resolvedManifest = try await registry.manifest(actionID: actionID)
            manifest = resolvedManifest
            try resolvedManifest.inputSchema.validate(arguments)

            let availability = try await registry.availability(actionID: actionID)
            guard availability.isAvailable else {
                return await finish(
                    executionID: executionID,
                    actionID: actionID,
                    arguments: arguments,
                    status: .unavailable,
                    data: .object([:]),
                    display: availability.reason ?? "Action is unavailable.",
                    warnings: [],
                    error: .init(
                        code: "UNAVAILABLE",
                        message: availability.reason ?? "Action is unavailable.",
                        permission: nil,
                        recovery: availability.recovery,
                        retryable: false
                    ),
                    startedAt: startedAt,
                    dryRun: options.dryRun
                )
            }

            if options.dryRun {
                guard resolvedManifest.dryRunBehavior.mode == .supported else {
                    return await finish(
                        executionID: executionID,
                        actionID: actionID,
                        arguments: arguments,
                        status: .failed,
                        data: .object([:]),
                        display: resolvedManifest.dryRunBehavior.description,
                        warnings: [],
                        error: .init(
                            code: "DRY_RUN_UNSUPPORTED",
                            message: resolvedManifest.dryRunBehavior.description,
                            permission: nil,
                            recovery: nil,
                            retryable: false
                        ),
                        startedAt: startedAt,
                        dryRun: true
                    )
                }
                let data: NexJSONValue = .object([
                    "action": .string(resolvedManifest.actionID),
                    "implementation": .string(resolvedManifest.implementationMethod.rawValue),
                    "risk": .string(resolvedManifest.riskClass.rawValue),
                    "confirmation": .string(resolvedManifest.confirmationPolicy.rawValue),
                    "permissions": .array(resolvedManifest.requiredPermissions.map { .string($0.id) }),
                    "arguments": .object(arguments)
                ])
                return await finish(
                    executionID: executionID,
                    actionID: actionID,
                    arguments: arguments,
                    status: .dryRun,
                    data: data,
                    display: resolvedManifest.dryRunBehavior.description,
                    warnings: [],
                    error: nil,
                    startedAt: startedAt,
                    dryRun: true
                )
            }

            let timeout = min(
                max(options.timeoutOverrideSeconds ?? resolvedManifest.timeoutSeconds, 0.1),
                resolvedManifest.timeoutSeconds
            )
            let task = Task<NexJSONValue, Error> { [registry] in
                try await Self.executeWithTimeout(seconds: timeout) {
                    try await Self.executeWithRetry(
                        manifest: resolvedManifest,
                        registry: registry,
                        arguments: arguments,
                        invocation: options.invocation
                    )
                }
            }
            running[executionID] = RunningExecution(
                task: task,
                supportsCancellation: resolvedManifest.supportsCancellation
            )
            defer { running[executionID] = nil }

            let result = try await task.value
            guard case .object(let object) = result else {
                throw RuntimeFailure.invalidOutput("Action output must be a JSON object.")
            }
            if object["status"] == .string("confirmation_required") {
                return await finish(
                    executionID: executionID,
                    actionID: actionID,
                    arguments: arguments,
                    status: .confirmationRequired,
                    data: result,
                    display: object["summary"]?.string ?? "Confirmation is required.",
                    warnings: [],
                    error: .init(
                        code: "CONFIRMATION_REQUIRED",
                        message: object["exactEffect"]?.string ?? "Confirm this exact action before it runs.",
                        permission: nil,
                        recovery: "Approve or cancel the pending action before it expires.",
                        retryable: false
                    ),
                    startedAt: startedAt,
                    dryRun: false
                )
            }
            if object["status"] == .string("permission_required") {
                return await finish(
                    executionID: executionID,
                    actionID: actionID,
                    arguments: arguments,
                    status: .permissionRequired,
                    data: result,
                    display: "Permission is required for \(actionID).",
                    warnings: [],
                    error: .init(
                        code: "PERMISSION_REQUIRED",
                        message: "The required macOS permission is unavailable.",
                        permission: object["permission"]?.string,
                        recovery: object["recovery"]?.string,
                        retryable: false
                    ),
                    startedAt: startedAt,
                    dryRun: false
                )
            }
            do {
                try resolvedManifest.outputSchema.validate(object)
            } catch {
                throw RuntimeFailure.invalidOutput(error.localizedDescription)
            }
            return await finish(
                executionID: executionID,
                actionID: actionID,
                arguments: arguments,
                status: .completed,
                data: result,
                display: Self.displayText(from: object, fallback: "Completed \(actionID)."),
                warnings: Self.warnings(from: object),
                error: nil,
                startedAt: startedAt,
                dryRun: false
            )
        } catch is CancellationError {
            return await finish(
                executionID: executionID,
                actionID: actionID,
                arguments: arguments,
                status: .cancelled,
                data: .object([:]),
                display: "Cancelled \(actionID).",
                warnings: manifest?.supportsCancellation == false ? ["The executor may still be finishing in the background."] : [],
                error: .init(
                    code: "CANCELLED",
                    message: "The action was cancelled.",
                    permission: nil,
                    recovery: nil,
                    retryable: false
                ),
                startedAt: startedAt,
                dryRun: options.dryRun
            )
        } catch RuntimeFailure.timedOut {
            return await finish(
                executionID: executionID,
                actionID: actionID,
                arguments: arguments,
                status: .timedOut,
                data: .object([:]),
                display: "\(actionID) timed out.",
                warnings: [],
                error: .init(
                    code: "TIMED_OUT",
                    message: "The action did not finish before its timeout.",
                    permission: nil,
                    recovery: "Retry the action or inspect the target application.",
                    retryable: true
                ),
                startedAt: startedAt,
                dryRun: options.dryRun
            )
        } catch RuntimeFailure.invalidOutput(let message) {
            return await finish(
                executionID: executionID,
                actionID: actionID,
                arguments: arguments,
                status: .failed,
                data: .object([:]),
                display: "The action returned invalid data.",
                warnings: [],
                error: .init(
                    code: "INVALID_OUTPUT",
                    message: message,
                    permission: nil,
                    recovery: "Update the executor to match its declared output schema.",
                    retryable: false
                ),
                startedAt: startedAt,
                dryRun: options.dryRun
            )
        } catch let failure as NexComputerActionFailure {
            return await finish(
                executionID: executionID,
                actionID: actionID,
                arguments: arguments,
                status: .failed,
                data: .object([:]),
                display: failure.message,
                warnings: [],
                error: .init(
                    code: failure.code,
                    message: failure.message,
                    permission: failure.permission,
                    recovery: failure.recovery,
                    retryable: failure.retryable
                ),
                startedAt: startedAt,
                dryRun: options.dryRun
            )
        } catch {
            let toolError = error as? NexToolError
            return await finish(
                executionID: executionID,
                actionID: actionID,
                arguments: arguments,
                status: .failed,
                data: .object([:]),
                display: error.localizedDescription,
                warnings: [],
                error: .init(
                    code: toolError?.code.uppercased() ?? "EXECUTION_FAILED",
                    message: error.localizedDescription,
                    permission: nil,
                    recovery: nil,
                    retryable: false
                ),
                startedAt: startedAt,
                dryRun: options.dryRun
            )
        }
    }

    @discardableResult
    func cancel(executionID: UUID) -> Bool {
        guard let execution = running[executionID], execution.supportsCancellation else { return false }
        execution.task.cancel()
        return true
    }

    func recentLogEntries() async -> [NexComputerActionLogEntry] {
        await logger.recentEntries()
    }

    private func finish(
        executionID: UUID,
        actionID: String,
        arguments: [String: NexJSONValue],
        status: NexComputerExecutionStatus,
        data: NexJSONValue,
        display: String,
        warnings: [String],
        error: NexComputerStructuredError?,
        startedAt: Date,
        dryRun: Bool
    ) async -> NexComputerResultEnvelope {
        let duration = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        let envelope = NexComputerResultEnvelope(
            schemaVersion: NexComputerResultEnvelope.currentSchemaVersion,
            executionID: executionID,
            ok: status == .completed || status == .dryRun,
            action: actionID,
            status: status,
            data: data,
            display: display,
            warnings: warnings,
            durationMs: duration,
            error: error
        )
        await logger.record(.init(
            executionID: executionID,
            actionID: actionID,
            status: status,
            argumentKeys: arguments.keys.sorted(),
            dryRun: dryRun,
            errorCode: error?.code,
            durationMs: duration,
            occurredAt: Date()
        ))
        return envelope
    }

    private static func displayText(from object: [String: NexJSONValue], fallback: String) -> String {
        object["display"]?.string ?? fallback
    }

    private static func warnings(from object: [String: NexJSONValue]) -> [String] {
        object["warnings"]?.strings ?? []
    }

    private static func executeWithRetry(
        manifest: NexComputerActionManifest,
        registry: NexComputerRegistry,
        arguments: [String: NexJSONValue],
        invocation: NexToolInvocation
    ) async throws -> NexJSONValue {
        var attempt = 1
        var backoff = manifest.retryPolicy.initialBackoffMilliseconds

        while true {
            do {
                return try await registry.execute(
                    actionID: manifest.actionID,
                    arguments: arguments,
                    invocation: invocation
                )
            } catch {
                let failure = error as? NexComputerActionFailure
                let shouldRetry = attempt < manifest.retryPolicy.maximumAttempts
                    && failure?.retryable == true
                    && manifest.retryPolicy.retryableErrorCodes.contains(failure?.code ?? "")
                guard shouldRetry else { throw error }

                attempt += 1
                if backoff > 0 {
                    try await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000)
                }
                backoff = min(
                    max(backoff * 2, manifest.retryPolicy.initialBackoffMilliseconds),
                    manifest.retryPolicy.maximumBackoffMilliseconds
                )
            }
        }
    }

    private static func executeWithTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RuntimeFailure.timedOut
            }
            guard let value = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return value
        }
    }
}
