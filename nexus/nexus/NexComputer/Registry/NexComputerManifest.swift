import Foundation

enum NexComputerImplementationMethod: String, Codable, CaseIterable, Sendable {
    case nativeAPI = "native_api"
    case connector
    case cli
    case appleScript = "apple_script"
    case scriptingBridge = "scripting_bridge"
    case urlScheme = "url_scheme"
    case accessibility
    case browserAgent = "browser_agent"
    case coordinateAutomationUnsupported = "coordinate_automation_unsupported"

    var priority: Int {
        Self.allCases.firstIndex(of: self).map { $0 + 1 } ?? Self.allCases.count
    }
}

enum NexComputerRiskClass: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
}

enum NexComputerConfirmationPolicy: String, Codable, Sendable {
    case never
    case whenRequired = "when_required"
    case always
}

enum NexComputerDryRunMode: String, Codable, Sendable {
    case supported
    case unsupported
}

struct NexComputerDryRunBehavior: Codable, Equatable, Sendable {
    let mode: NexComputerDryRunMode
    let description: String

    static func supported(_ description: String) -> Self {
        .init(mode: .supported, description: description)
    }

    static func unsupported(_ reason: String) -> Self {
        .init(mode: .unsupported, description: reason)
    }
}

struct NexComputerPermissionRequirement: Codable, Equatable, Sendable {
    let id: String
    let permission: NexToolPermission
    let recovery: String?

    init(id: String, permission: NexToolPermission, recovery: String? = nil) {
        self.id = id
        self.permission = permission
        self.recovery = recovery
    }
}

struct NexComputerRetryPolicy: Codable, Equatable, Sendable {
    let maximumAttempts: Int
    let initialBackoffMilliseconds: Int
    let maximumBackoffMilliseconds: Int
    let retryableErrorCodes: [String]

    static let none = NexComputerRetryPolicy(
        maximumAttempts: 1,
        initialBackoffMilliseconds: 0,
        maximumBackoffMilliseconds: 0,
        retryableErrorCodes: []
    )
}

enum NexComputerAvailabilityKind: String, Codable, Sendable {
    case always
    case application
    case executable
    case custom
    case unsupported
}

struct NexComputerAvailabilityCheck: Codable, Equatable, Sendable {
    let kind: NexComputerAvailabilityKind
    let bundleIdentifier: String?
    let executablePaths: [String]
    let identifier: String?
    let reason: String?

    static let always = NexComputerAvailabilityCheck(
        kind: .always,
        bundleIdentifier: nil,
        executablePaths: [],
        identifier: nil,
        reason: nil
    )

    static func application(bundleIdentifier: String) -> Self {
        .init(
            kind: .application,
            bundleIdentifier: bundleIdentifier,
            executablePaths: [],
            identifier: nil,
            reason: nil
        )
    }

    static func executable(paths: [String]) -> Self {
        .init(
            kind: .executable,
            bundleIdentifier: nil,
            executablePaths: paths,
            identifier: nil,
            reason: nil
        )
    }

    static func custom(_ identifier: String) -> Self {
        .init(
            kind: .custom,
            bundleIdentifier: nil,
            executablePaths: [],
            identifier: identifier,
            reason: nil
        )
    }

    static func unsupported(_ reason: String) -> Self {
        .init(
            kind: .unsupported,
            bundleIdentifier: nil,
            executablePaths: [],
            identifier: nil,
            reason: reason
        )
    }
}

struct NexComputerActionManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let actionID: String
    let application: String
    let provider: String
    let bundleIdentifier: String?
    let description: String
    let examples: [String]
    let aliases: [String]
    let tags: [String]
    let inputSchema: NexToolInputSchema
    let outputSchema: NexToolInputSchema
    let implementationMethod: NexComputerImplementationMethod
    let requiredPermissions: [NexComputerPermissionRequirement]
    let registryPermission: NexToolPermission
    let riskClass: NexComputerRiskClass
    let confirmationPolicy: NexComputerConfirmationPolicy
    let availabilityCheck: NexComputerAvailabilityCheck
    let timeoutSeconds: Double
    let supportsCancellation: Bool
    let retryPolicy: NexComputerRetryPolicy
    let dryRunBehavior: NexComputerDryRunBehavior
    let previewRenderer: String
    let tests: [String]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        actionID: String,
        application: String,
        provider: String,
        bundleIdentifier: String? = nil,
        description: String,
        examples: [String],
        aliases: [String] = [],
        tags: [String] = [],
        inputSchema: NexToolInputSchema,
        outputSchema: NexToolInputSchema,
        implementationMethod: NexComputerImplementationMethod,
        requiredPermissions: [NexComputerPermissionRequirement] = [],
        registryPermission: NexToolPermission,
        riskClass: NexComputerRiskClass,
        confirmationPolicy: NexComputerConfirmationPolicy,
        availabilityCheck: NexComputerAvailabilityCheck,
        timeoutSeconds: Double,
        supportsCancellation: Bool,
        retryPolicy: NexComputerRetryPolicy = .none,
        dryRunBehavior: NexComputerDryRunBehavior,
        previewRenderer: String,
        tests: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.actionID = actionID
        self.application = application
        self.provider = provider
        self.bundleIdentifier = bundleIdentifier
        self.description = description
        self.examples = examples
        self.aliases = aliases
        self.tags = tags
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.implementationMethod = implementationMethod
        self.requiredPermissions = requiredPermissions
        self.registryPermission = registryPermission
        self.riskClass = riskClass
        self.confirmationPolicy = confirmationPolicy
        self.availabilityCheck = availabilityCheck
        self.timeoutSeconds = timeoutSeconds
        self.supportsCancellation = supportsCancellation
        self.retryPolicy = retryPolicy
        self.dryRunBehavior = dryRunBehavior
        self.previewRenderer = previewRenderer
        self.tests = tests
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NexComputerManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        guard actionID.range(
            of: #"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$"#,
            options: .regularExpression
        ) != nil else {
            throw NexComputerManifestError.invalidActionID(actionID)
        }
        try Self.require(application, field: "application")
        try Self.require(provider, field: "provider")
        try Self.require(description, field: "description")
        try Self.require(previewRenderer, field: "previewRenderer")
        guard !examples.isEmpty, examples.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NexComputerManifestError.missingExamples
        }
        guard !tests.isEmpty, tests.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NexComputerManifestError.missingTests
        }
        guard timeoutSeconds >= 0.1, timeoutSeconds <= 300 else {
            throw NexComputerManifestError.invalidTimeout(timeoutSeconds)
        }
        guard (1...5).contains(retryPolicy.maximumAttempts),
              retryPolicy.initialBackoffMilliseconds >= 0,
              retryPolicy.maximumBackoffMilliseconds >= retryPolicy.initialBackoffMilliseconds else {
            throw NexComputerManifestError.invalidRetryPolicy
        }
        if implementationMethod == .coordinateAutomationUnsupported,
           availabilityCheck.kind != .unsupported {
            throw NexComputerManifestError.coordinateAutomationMustRemainUnsupported
        }
        switch availabilityCheck.kind {
        case .application:
            guard let bundleIdentifier, !bundleIdentifier.isEmpty,
                  availabilityCheck.bundleIdentifier == bundleIdentifier else {
                throw NexComputerManifestError.invalidAvailabilityCheck
            }
        case .executable:
            guard !availabilityCheck.executablePaths.isEmpty else {
                throw NexComputerManifestError.invalidAvailabilityCheck
            }
        case .custom:
            guard !(availabilityCheck.identifier ?? "").isEmpty else {
                throw NexComputerManifestError.invalidAvailabilityCheck
            }
        case .unsupported:
            guard !(availabilityCheck.reason ?? "").isEmpty else {
                throw NexComputerManifestError.invalidAvailabilityCheck
            }
        case .always:
            break
        }
    }

    private static func require(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NexComputerManifestError.emptyField(field)
        }
    }
}

enum NexComputerManifestError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidActionID(String)
    case emptyField(String)
    case missingExamples
    case missingTests
    case invalidTimeout(Double)
    case invalidRetryPolicy
    case invalidAvailabilityCheck
    case coordinateAutomationMustRemainUnsupported

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported Nex Computer manifest schema version: \(version)."
        case .invalidActionID(let value):
            "Action ID must be a stable, dot-separated semantic identifier: \(value)."
        case .emptyField(let field):
            "Manifest field \(field) cannot be empty."
        case .missingExamples:
            "A semantic action must include at least one natural-language example."
        case .missingTests:
            "A semantic action must declare its focused tests."
        case .invalidTimeout(let seconds):
            "Action timeout \(seconds) must be between 0.1 and 300 seconds."
        case .invalidRetryPolicy:
            "Retry policy must use 1–5 attempts and a bounded nonnegative backoff."
        case .invalidAvailabilityCheck:
            "Availability check is missing required application, executable, or custom-probe metadata."
        case .coordinateAutomationMustRemainUnsupported:
            "Coordinate automation must be explicitly unavailable, never a silent executor."
        }
    }
}
