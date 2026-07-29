import Foundation

enum NexusConnectProtocol {
    /// Version 2 adds feature negotiation and per-node runtime/inventory
    /// metadata. Version 1 remains accepted for rolling upgrades.
    static let currentVersion = 2
    static let minimumVersion = 1
    static let servicePort: UInt16 = 49_718
    static let maximumControlFrameBytes = 1_048_576
    static let maximumDataFrameBytes = 8_388_608
    static let defaultChunkBytes = 1_048_576
}

enum NexusConnectFeature: String, CaseIterable, Codable, Hashable, Sendable {
    case streamingInference
    case resumableModelPull
    case perNodeInventory
    case runtimeProvisioning
    case modelDelete
    case backgroundHost

    var introducedInProtocol: Int {
        switch self {
        case .streamingInference, .resumableModelPull: 1
        case .perNodeInventory, .runtimeProvisioning, .modelDelete, .backgroundHost: 2
        }
    }
}

struct NexusNegotiatedProtocol: Codable, Equatable, Sendable {
    let version: Int
    let features: Set<NexusConnectFeature>
}

enum NexusProtocolNegotiator {
    static func negotiate(
        localRange: NexusProtocolVersionRange = .local,
        localFeatures: Set<NexusConnectFeature> = Set(NexusConnectFeature.allCases),
        remoteRange: NexusProtocolVersionRange,
        remoteFeatures: Set<NexusConnectFeature>
    ) throws -> NexusNegotiatedProtocol {
        guard let version = localRange.highestCommonVersion(with: remoteRange) else {
            throw NexusConnectError.unsupportedProtocol
        }
        let features = localFeatures.intersection(remoteFeatures).filter {
            $0.introducedInProtocol <= version
        }
        return .init(version: version, features: features)
    }
}

enum NexusNodeRole: String, Codable, Sendable {
    case client
    case studioHost
}

enum NexusCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case health
    case inference
    case agent
    case modelList
    case modelPull
    case modelDelete
    case runtimeStatus
    case runtimeProvision
    case ocr
    case index
    case searchIndex
    case process
    case fileStat
    case fileRead
    case fileWrite
    case fileList
    case download
}

enum NexusWorkloadKind: String, Codable, Sendable {
    case health
    case inference
    case intentRoute
    case agent
    case modelList
    case modelPull
    case modelDelete
    case runtimeStatus
    case runtimeProvision
    case ocr
    case index
    case searchIndex
    case processApproval
    case process
    case fileStat
    case fileRead
    case fileWrite
    case fileList
    case download

    var capability: NexusCapability {
        switch self {
        case .health: .health
        case .inference, .intentRoute: .inference
        case .agent: .agent
        case .modelList: .modelList
        case .modelPull: .modelPull
        case .modelDelete: .modelDelete
        case .runtimeStatus: .runtimeStatus
        case .runtimeProvision: .runtimeProvision
        case .ocr: .ocr
        case .index: .index
        case .searchIndex: .searchIndex
        case .processApproval: .process
        case .process: .process
        case .fileStat: .fileStat
        case .fileRead: .fileRead
        case .fileWrite: .fileWrite
        case .fileList: .fileList
        case .download: .download
        }
    }
}

enum NexusWorkloadPriority: Int, Codable, Comparable, Sendable {
    case background = 0
    case utility = 1
    case interactive = 2

    static func < (lhs: NexusWorkloadPriority, rhs: NexusWorkloadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum NexusRetrySafety: String, Codable, Sendable {
    case idempotent
    case resumable
    case neverReplay
}

struct NexusWorkloadRequest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: NexusWorkloadKind
    let priority: NexusWorkloadPriority
    let retrySafety: NexusRetrySafety
    let createdAtMilliseconds: Int64
    let payload: Data

    init<Payload: Encodable>(
        id: UUID = UUID(),
        kind: NexusWorkloadKind,
        priority: NexusWorkloadPriority = .utility,
        retrySafety: NexusRetrySafety,
        createdAtMilliseconds: Int64 = NexusClock.nowMilliseconds(),
        payload: Payload
    ) throws {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.retrySafety = retrySafety
        self.createdAtMilliseconds = createdAtMilliseconds
        self.payload = try NexusPayloadCoder.encoder.encode(payload)
    }

    func decodePayload<Payload: Decodable>(_ type: Payload.Type = Payload.self) throws -> Payload {
        try NexusPayloadCoder.decoder.decode(type, from: payload)
    }
}

enum NexusWorkloadEventKind: String, Codable, Sendable {
    case accepted
    case progress
    case token
    case standardOutput
    case standardError
    case result
    case completed
    case cancelled
    case failed
}

struct NexusWorkloadEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let requestID: UUID
    let kind: NexusWorkloadEventKind
    let sequence: UInt64
    let isFinal: Bool
    let payload: Data

    init<Payload: Encodable>(
        id: UUID = UUID(),
        requestID: UUID,
        kind: NexusWorkloadEventKind,
        sequence: UInt64,
        isFinal: Bool = false,
        payload: Payload
    ) throws {
        self.id = id
        self.requestID = requestID
        self.kind = kind
        self.sequence = sequence
        self.isFinal = isFinal
        self.payload = try NexusPayloadCoder.encoder.encode(payload)
    }

    func decodePayload<Payload: Decodable>(_ type: Payload.Type = Payload.self) throws -> Payload {
        try NexusPayloadCoder.decoder.decode(type, from: payload)
    }
}

enum NexusMessageKind: String, Codable, Sendable {
    case request
    case event
    case cancel
    case ping
    case pong
    case error
}

struct NexusConnectMessage: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let sessionID: UUID
    let kind: NexusMessageKind
    let requestID: UUID?
    let payload: Data

    init<Payload: Encodable>(
        protocolVersion: Int = NexusConnectProtocol.currentVersion,
        sessionID: UUID,
        kind: NexusMessageKind,
        requestID: UUID? = nil,
        payload: Payload
    ) throws {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.kind = kind
        self.requestID = requestID
        self.payload = try NexusPayloadCoder.encoder.encode(payload)
    }

    func decodePayload<Payload: Decodable>(_ type: Payload.Type = Payload.self) throws -> Payload {
        try NexusPayloadCoder.decoder.decode(type, from: payload)
    }
}

struct NexusHandshakeEnvelope: Codable, Equatable, Sendable {
    let sessionID: UUID
    let hello: NexusHandshakeHello
}

struct NexusPingPayload: Codable, Equatable, Sendable {
    let sentAtMilliseconds: Int64
}

enum NexusRuntimeKind: String, Codable, Sendable {
    case ollama
    case lmStudio
}

struct NexusChatMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String
    /// Base64-encoded image data for a single multimodal turn. Conversation
    /// history stays text-only; this is intentionally ephemeral request
    /// context such as the user's current screen.
    let imageBase64: String?
    let imageMediaType: String?

    init(
        role: String,
        content: String,
        imageBase64: String? = nil,
        imageMediaType: String? = nil
    ) {
        self.role = role
        self.content = content
        self.imageBase64 = imageBase64
        self.imageMediaType = imageMediaType
    }
}

struct NexusInferencePayload: Codable, Equatable, Sendable {
    let runtime: NexusRuntimeKind
    let model: String
    let messages: [NexusChatMessage]
    let temperature: Double?
    let maximumTokens: Int?
}

struct NexusIntentRoutePayload: Codable, Equatable, Sendable {
    let model: String
    let prompt: String
    let maximumTokens: Int
}

struct NexusIntentRouteResultPayload: Codable, Equatable, Sendable {
    let response: String
}

struct NexusAgentPayload: Codable, Equatable, Sendable {
    let runtime: NexusRuntimeKind
    let model: String
    let instructions: String
    let context: [NexusChatMessage]
    let maximumSteps: Int
}

struct NexusEmptyPayload: Codable, Equatable, Sendable {}

struct NexusModelListPayload: Codable, Equatable, Sendable {
    let runtime: NexusRuntimeKind?
}

struct NexusModelPullPayload: Codable, Equatable, Sendable {
    let runtime: NexusRuntimeKind
    let model: String
    let quantization: String?
}

struct NexusModelDeletePayload: Codable, Equatable, Sendable {
    let runtime: NexusRuntimeKind
    let model: String
}

struct NexusRuntimeProvisionPayload: Codable, Equatable, Sendable {
    let preferredRuntime: NexusRuntimeKind?
    let userConfirmed: Bool
}

struct NexusRuntimeInventoryPayload: Codable, Equatable, Sendable {
    let runtimes: Set<NexusRuntimeAvailability>
    let defaultRuntime: NexusRuntimeKind?
    /// Additive diagnostic field. MLX is reported here until Nexus has a
    /// first-class MLX model descriptor and streaming adapter; older peers
    /// safely ignore it.
    let detectedRuntimeNames: Set<String>?

    init(
        runtimes: Set<NexusRuntimeAvailability>,
        defaultRuntime: NexusRuntimeKind?,
        detectedRuntimeNames: Set<String>? = nil
    ) {
        self.runtimes = runtimes
        self.defaultRuntime = defaultRuntime
        self.detectedRuntimeNames = detectedRuntimeNames
    }
}

struct NexusModelDescriptor: Codable, Equatable, Hashable, Sendable {
    let runtime: NexusRuntimeKind
    let identifier: String
}

struct NexusModelInventoryPayload: Codable, Equatable, Sendable {
    let models: [NexusModelDescriptor]
}

struct NexusProgressPayload: Codable, Equatable, Sendable {
    let completedBytes: Int64?
    let totalBytes: Int64?
    let fraction: Double?
    let status: String
}

struct NexusTextDeltaPayload: Codable, Equatable, Sendable {
    let delta: String
    let accumulated: String?
}

struct NexusOCRPayload: Codable, Equatable, Sendable {
    let imageData: Data?
    let file: NexusFileReference?
    let recognitionLanguages: [String]
}

struct NexusOCRResultPayload: Codable, Equatable, Sendable {
    let text: String
    let observations: [String]
}

struct NexusIndexPayload: Codable, Equatable, Sendable {
    let rootID: String
    let relativePaths: [String]
    let replaceExisting: Bool
}

struct NexusIndexSearchPayload: Codable, Equatable, Sendable {
    let query: String
    let limit: Int
}

struct NexusIndexSearchResult: Codable, Equatable, Sendable {
    let file: NexusFileReference
    let score: Double
    let snippet: String
}

struct NexusIndexSearchResultsPayload: Codable, Equatable, Sendable {
    let results: [NexusIndexSearchResult]
}

struct NexusProcessPayload: Codable, Equatable, Sendable {
    let executableID: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: NexusFileReference?
    let timeoutSeconds: Double
    let maximumOutputBytes: Int
    let approvalToken: String?
}

struct NexusProcessApprovalRequestPayload: Codable, Equatable, Sendable {
    let executableID: String
    let validitySeconds: TimeInterval
}

struct NexusProcessApprovalResultPayload: Codable, Equatable, Sendable {
    let token: String
    let expiresAtMilliseconds: Int64
}

struct NexusProcessOutputPayload: Codable, Equatable, Sendable {
    let data: Data
    let exitCode: Int32?
}

struct NexusFileReference: Codable, Equatable, Hashable, Sendable {
    let rootID: String
    let relativePath: String
}

struct NexusFileReadPayload: Codable, Equatable, Sendable {
    let file: NexusFileReference
    let offset: Int64
    let maximumLength: Int
}

struct NexusFileStatPayload: Codable, Equatable, Sendable {
    let file: NexusFileReference
    /// When present, asks for the resumable temporary file associated with this
    /// transfer if the final destination does not exist yet.
    let transferID: UUID?
    let includeSHA256: Bool?

    init(
        file: NexusFileReference,
        transferID: UUID? = nil,
        includeSHA256: Bool = false
    ) {
        self.file = file
        self.transferID = transferID
        self.includeSHA256 = includeSHA256
    }
}

struct NexusFileStatResultPayload: Codable, Equatable, Sendable {
    let file: NexusFileReference
    let exists: Bool
    let isDirectory: Bool
    let size: Int64
    let modifiedAtMilliseconds: Int64?
    let sha256: Data?
    let isPartialTransfer: Bool?

    init(
        file: NexusFileReference,
        exists: Bool,
        isDirectory: Bool,
        size: Int64,
        modifiedAtMilliseconds: Int64?,
        sha256: Data? = nil,
        isPartialTransfer: Bool? = nil
    ) {
        self.file = file
        self.exists = exists
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAtMilliseconds = modifiedAtMilliseconds
        self.sha256 = sha256
        self.isPartialTransfer = isPartialTransfer
    }
}

struct NexusFileListPayload: Codable, Equatable, Sendable {
    let directory: NexusFileReference
    let recursive: Bool
    let maximumEntries: Int
}

struct NexusFileListEntry: Codable, Equatable, Sendable {
    let file: NexusFileReference
    let isDirectory: Bool
    let size: Int64
}

struct NexusFileListResultPayload: Codable, Equatable, Sendable {
    let entries: [NexusFileListEntry]
}

struct NexusFileDataPayload: Codable, Equatable, Sendable {
    let file: NexusFileReference
    let offset: Int64
    let data: Data
    let endOfFile: Bool
    let chunkSHA256: Data?

    init(
        file: NexusFileReference,
        offset: Int64,
        data: Data,
        endOfFile: Bool,
        chunkSHA256: Data? = nil
    ) {
        self.file = file
        self.offset = offset
        self.data = data
        self.endOfFile = endOfFile
        self.chunkSHA256 = chunkSHA256
    }
}

struct NexusFileWritePayload: Codable, Equatable, Sendable {
    let file: NexusFileReference
    let transferID: UUID
    let offset: Int64
    let data: Data
    let chunkSHA256: Data
    let finalSize: Int64?
    let finalSHA256: Data?
}

struct NexusDownloadPayload: Codable, Equatable, Sendable {
    let sourceURL: URL
    let destination: NexusFileReference
    let expectedSHA256: Data?
    let transferID: UUID
}

struct NexusDownloadResultPayload: Codable, Equatable, Sendable {
    let destination: NexusFileReference
    let byteCount: Int64
    let sha256: Data
}

struct NexusTransferChunk: Codable, Equatable, Sendable {
    let transferID: UUID
    let offset: Int64
    let data: Data
    let sha256: Data
    let isFinal: Bool
}

struct NexusNodeHealth: Codable, Equatable, Sendable {
    let nodeID: UUID
    let nodeName: String
    let hostVersion: String
    let protocolMinimum: Int
    let protocolMaximum: Int
    let capabilities: Set<NexusCapability>
    let uptimeSeconds: TimeInterval
    let totalMemoryBytes: UInt64
    let availableMemoryBytes: UInt64
    let availableDiskBytes: Int64
    let queueDepth: Int
    let activeJobs: Int
    let loadAverage: [Double]
    let modelInventoryDigest: Data
    let timestampMilliseconds: Int64
}

enum NexusConnectionRoute: String, Codable, Sendable {
    case direct
    case peerRelay
    case derp
    case unknown
}

struct NexusConnectionQuality: Codable, Equatable, Sendable {
    let route: NexusConnectionRoute
    let roundTripMilliseconds: Double?
    let uploadBytesPerSecond: Double?
    let downloadBytesPerSecond: Double?
    let recentFailureRate: Double
}

struct NexusRemoteErrorPayload: Codable, Equatable, Sendable {
    let code: String
    let message: String
    let retryable: Bool
}

enum NexusConnectError: LocalizedError, Equatable {
    case unavailable(String)
    case unsupportedProtocol
    case authenticationFailed
    case identityMismatch
    case handshakeExpired
    case replayDetected
    case malformedFrame
    case frameTooLarge(Int)
    case policyDenied(String)
    case pathOutsideAllowedRoots
    case requestFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail): "Nexus Connect is unavailable: \(detail)"
        case .unsupportedProtocol: "The paired Mac is running an incompatible Nexus Connect protocol."
        case .authenticationFailed: "Nexus Connect could not authenticate the paired device."
        case .identityMismatch: "The paired Mac identity changed. Re-pair before connecting."
        case .handshakeExpired: "The Nexus Connect handshake expired."
        case .replayDetected: "Nexus Connect rejected a replayed message."
        case .malformedFrame: "Nexus Connect received a malformed frame."
        case .frameTooLarge(let bytes): "Nexus Connect rejected an oversized \(bytes)-byte frame."
        case .policyDenied(let detail): "Nexus Connect policy denied the request: \(detail)"
        case .pathOutsideAllowedRoots: "Nexus Connect blocked a path outside its allowed folders."
        case .requestFailed(let detail): detail
        case .cancelled: "Nexus Connect request canceled."
        }
    }
}

enum NexusPayloadCoder {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder { JSONDecoder() }
}

enum NexusClock {
    static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}
