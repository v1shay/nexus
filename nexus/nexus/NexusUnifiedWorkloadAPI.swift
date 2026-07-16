import CryptoKit
import Foundation

actor NexusAdaptiveTransferLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }

    private var limit: Int
    private var activeIDs: Set<UUID> = []
    private var waiters: [Waiter] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func setLimit(_ limit: Int) {
        self.limit = max(1, limit)
        drain()
    }

    func withPermit<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let permit = try await acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(permit)
            return result
        } catch {
            release(permit)
            throw error
        }
    }

    func snapshot() -> (active: Int, queued: Int, limit: Int) {
        (activeIDs.count, waiters.count, limit)
    }

    private func acquire() async throws -> UUID {
        let id = UUID()
        if activeIDs.count < limit {
            activeIDs.insert(id)
            return id
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(.init(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    private func release(_ id: UUID) {
        guard activeIDs.remove(id) != nil else { return }
        drain()
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func drain() {
        while activeIDs.count < limit, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            activeIDs.insert(waiter.id)
            waiter.continuation.resume(returning: waiter.id)
        }
    }
}

struct NexusTransferProgress: Equatable, Sendable {
    let completedBytes: Int64
    let totalBytes: Int64?
    let status: String

    var fraction: Double? {
        totalBytes.map { Double(completedBytes) / Double(max(1, $0)) }
    }
}

struct NexusStructuredProcessResult: Equatable, Sendable {
    let standardOutput: Data
    let standardError: Data
    let exitCode: Int32
}

/// The application-facing workload boundary. Callers describe work, never a
/// machine; the injected router decides whether it runs locally or on a paired host.
actor NexusUnifiedWorkloadAPI {
    typealias ProgressHandler = @Sendable (NexusTransferProgress) async -> Void

    private let executor: any NexusWorkloadExecuting
    private var bandwidthPolicy: NexusBandwidthPolicy
    private let transferLimiter: NexusAdaptiveTransferLimiter

    init(
        executor: any NexusWorkloadExecuting,
        bandwidthPolicy: NexusBandwidthPolicy = .policy(for: .init(
            route: .unknown,
            roundTripMilliseconds: nil,
            uploadBytesPerSecond: nil,
            downloadBytesPerSecond: nil,
            recentFailureRate: 0
        ))
    ) {
        self.executor = executor
        self.bandwidthPolicy = bandwidthPolicy
        transferLimiter = NexusAdaptiveTransferLimiter(limit: bandwidthPolicy.transferConcurrency)
    }

    func setConnectionQuality(_ quality: NexusConnectionQuality) async {
        let policy = NexusBandwidthPolicy.policy(for: quality)
        bandwidthPolicy = policy
        await transferLimiter.setLimit(policy.transferConcurrency)
    }

    func events(for request: NexusWorkloadRequest) async throws -> AsyncThrowingStream<NexusWorkloadEvent, Error> {
        try await executor.events(for: request)
    }

    func recognizeText(
        imageData: Data,
        languages: [String] = []
    ) async throws -> NexusOCRResultPayload {
        let request = try NexusWorkloadRequest(
            kind: .ocr,
            priority: .interactive,
            retrySafety: .idempotent,
            payload: NexusOCRPayload(imageData: imageData, file: nil, recognitionLanguages: languages)
        )
        return try await firstResult(request, as: NexusOCRResultPayload.self)
    }

    func index(
        rootID: String,
        relativePaths: [String],
        replaceExisting: Bool = false
    ) async throws -> NexusProgressPayload {
        let request = try NexusWorkloadRequest(
            kind: .index,
            priority: .background,
            retrySafety: .idempotent,
            payload: NexusIndexPayload(
                rootID: rootID,
                relativePaths: relativePaths,
                replaceExisting: replaceExisting
            )
        )
        return try await firstResult(request, as: NexusProgressPayload.self)
    }

    func searchIndex(query: String, limit: Int = 20) async throws -> [NexusIndexSearchResult] {
        let request = try NexusWorkloadRequest(
            kind: .searchIndex,
            priority: .interactive,
            retrySafety: .idempotent,
            payload: NexusIndexSearchPayload(query: query, limit: limit)
        )
        return try await firstResult(request, as: NexusIndexSearchResultsPayload.self).results
    }

    func runApprovedProcess(_ payload: NexusProcessPayload) async throws -> NexusStructuredProcessResult {
        let request = try NexusWorkloadRequest(
            kind: .process,
            priority: .utility,
            retrySafety: .neverReplay,
            payload: payload
        )
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32?
        let stream = try await executor.events(for: request)
        for try await event in stream {
            try Self.throwIfTerminalFailure(event)
            switch event.kind {
            case .standardOutput:
                stdout += try event.decodePayload(NexusProcessOutputPayload.self).data
            case .standardError:
                stderr += try event.decodePayload(NexusProcessOutputPayload.self).data
            case .result:
                exitCode = try event.decodePayload(NexusProcessOutputPayload.self).exitCode
            default:
                break
            }
        }
        guard let exitCode else { throw NexusConnectError.requestFailed("Process ended without an exit status") }
        return .init(standardOutput: stdout, standardError: stderr, exitCode: exitCode)
    }

    func requestProcessApproval(
        executableID: String,
        validFor seconds: TimeInterval = 60
    ) async throws -> NexusProcessApprovalResultPayload {
        let request = try NexusWorkloadRequest(
            kind: .processApproval,
            priority: .interactive,
            retrySafety: .neverReplay,
            payload: NexusProcessApprovalRequestPayload(
                executableID: executableID,
                validitySeconds: seconds
            )
        )
        return try await firstResult(request, as: NexusProcessApprovalResultPayload.self)
    }

    func listFiles(
        in directory: NexusFileReference,
        recursive: Bool = false,
        maximumEntries: Int = 1_000
    ) async throws -> [NexusFileListEntry] {
        let request = try NexusWorkloadRequest(
            kind: .fileList,
            priority: .utility,
            retrySafety: .idempotent,
            payload: NexusFileListPayload(
                directory: directory,
                recursive: recursive,
                maximumEntries: maximumEntries
            )
        )
        return try await firstResult(request, as: NexusFileListResultPayload.self).entries
    }

    /// Uploads a file in authenticated chunks. Reuse `transferID` after a
    /// reconnect or app restart to continue from Studio's verified offset.
    func uploadFile(
        from source: URL,
        to destination: NexusFileReference,
        transferID: UUID = UUID(),
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws {
        try await transferLimiter.withPermit { [self] in
            try await performUploadFile(
                from: source,
                to: destination,
                transferID: transferID,
                onProgress: onProgress
            )
        }
    }

    private func performUploadFile(
        from source: URL,
        to destination: NexusFileReference,
        transferID: UUID,
        onProgress: @escaping ProgressHandler
    ) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw NexusConnectError.requestFailed("Could not determine the upload size")
        }
        let finalSize = number.int64Value
        let finalDigest = try Self.fileSHA256(source)
        let remote = try await fileStat(
            destination,
            transferID: transferID,
            includeSHA256: true
        )
        if remote.exists, remote.isPartialTransfer != true,
           remote.size == finalSize, remote.sha256 == finalDigest {
            await onProgress(.init(completedBytes: finalSize, totalBytes: finalSize, status: "Already on paired Mac"))
            return
        }
        var offset = remote.isPartialTransfer == true ? remote.size : 0
        guard offset >= 0, offset <= finalSize else {
            throw NexusConnectError.requestFailed("The paired host returned an invalid resume offset")
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let chunkBytes = max(64 * 1_024, min(bandwidthPolicy.preferredChunkBytes, NexusConnectProtocol.maximumDataFrameBytes / 2))

        repeat {
            try Task.checkCancellation()
            let remaining = max(0, finalSize - offset)
            let length = Int(min(Int64(chunkBytes), remaining))
            let data = try handle.read(upToCount: length) ?? Data()
            guard data.count == length else {
                throw NexusConnectError.requestFailed("The source file changed during upload")
            }
            let payload = NexusFileWritePayload(
                file: destination,
                transferID: transferID,
                offset: offset,
                data: data,
                chunkSHA256: Data(SHA256.hash(data: data)),
                finalSize: finalSize,
                finalSHA256: finalDigest
            )
            let request = try NexusWorkloadRequest(
                kind: .fileWrite,
                priority: .background,
                retrySafety: .resumable,
                payload: payload
            )
            try await drain(request)
            offset += Int64(data.count)
            await onProgress(.init(completedBytes: offset, totalBytes: finalSize, status: "Sending to paired Mac"))
        } while offset < finalSize
    }

    /// Downloads a Studio file to this Mac and preserves the partial file when
    /// interrupted. The final rename occurs only after a whole-file checksum.
    func downloadFile(
        from source: NexusFileReference,
        to destination: URL,
        transferID: UUID = UUID(),
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws {
        try await transferLimiter.withPermit { [self] in
            try await performDownloadFile(
                from: source,
                to: destination,
                transferID: transferID,
                onProgress: onProgress
            )
        }
    }

    private func performDownloadFile(
        from source: NexusFileReference,
        to destination: URL,
        transferID: UUID,
        onProgress: @escaping ProgressHandler
    ) async throws {
        let remote = try await fileStat(source, includeSHA256: true)
        guard remote.exists, !remote.isDirectory, let finalDigest = remote.sha256 else {
            throw NexusConnectError.requestFailed("The paired host file is unavailable")
        }
        if FileManager.default.fileExists(atPath: destination.path),
           (try? Self.fileSHA256(destination)) == finalDigest {
            await onProgress(.init(completedBytes: remote.size, totalBytes: remote.size, status: "Already on this Mac"))
            return
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(transferID.uuidString.lowercased()).nexus-part"
        )
        try Self.requireSafePartialFile(partial)
        var offset = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.int64Value ?? 0
        if offset < 0 || offset > remote.size {
            try? FileManager.default.removeItem(at: partial)
            offset = 0
        }
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let chunkBytes = max(64 * 1_024, min(bandwidthPolicy.preferredChunkBytes, NexusConnectProtocol.maximumDataFrameBytes / 2))

        while offset < remote.size {
            try Task.checkCancellation()
            let result = try await readFile(source, offset: offset, maximumLength: chunkBytes)
            guard result.offset == offset, !result.data.isEmpty,
                  result.chunkSHA256 == Data(SHA256.hash(data: result.data)) else {
                throw NexusConnectError.requestFailed("The paired host returned an invalid transfer chunk")
            }
            try handle.write(contentsOf: result.data)
            try handle.synchronize()
            offset += Int64(result.data.count)
            await onProgress(.init(completedBytes: offset, totalBytes: remote.size, status: "Receiving from paired Mac"))
        }
        guard try Self.fileSHA256(partial) == finalDigest else {
            throw NexusConnectError.requestFailed("Downloaded file checksum did not match the paired host")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    func downloadOnStudio(
        sourceURL: URL,
        destination: NexusFileReference,
        expectedSHA256: Data? = nil,
        transferID: UUID = UUID(),
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> NexusDownloadResultPayload {
        try await transferLimiter.withPermit { [self] in
            try await performDownloadOnStudio(
                sourceURL: sourceURL,
                destination: destination,
                expectedSHA256: expectedSHA256,
                transferID: transferID,
                onProgress: onProgress
            )
        }
    }

    private func performDownloadOnStudio(
        sourceURL: URL,
        destination: NexusFileReference,
        expectedSHA256: Data?,
        transferID: UUID,
        onProgress: @escaping ProgressHandler
    ) async throws -> NexusDownloadResultPayload {
        let request = try NexusWorkloadRequest(
            kind: .download,
            priority: .background,
            retrySafety: .resumable,
            payload: NexusDownloadPayload(
                sourceURL: sourceURL,
                destination: destination,
                expectedSHA256: expectedSHA256,
                transferID: transferID
            )
        )
        var result: NexusDownloadResultPayload?
        let stream = try await executor.events(for: request)
        for try await event in stream {
            try Self.throwIfTerminalFailure(event)
            if event.kind == .progress {
                let progress = try event.decodePayload(NexusProgressPayload.self)
                await onProgress(.init(
                    completedBytes: progress.completedBytes ?? 0,
                    totalBytes: progress.totalBytes,
                    status: progress.status
                ))
            } else if event.kind == .result {
                result = try event.decodePayload(NexusDownloadResultPayload.self)
            }
        }
        guard let result else { throw NexusConnectError.requestFailed("The paired host download returned no artifact") }
        return result
    }

    private func fileStat(
        _ file: NexusFileReference,
        transferID: UUID? = nil,
        includeSHA256: Bool = false
    ) async throws -> NexusFileStatResultPayload {
        let request = try NexusWorkloadRequest(
            kind: .fileStat,
            priority: .interactive,
            retrySafety: .idempotent,
            payload: NexusFileStatPayload(
                file: file,
                transferID: transferID,
                includeSHA256: includeSHA256
            )
        )
        return try await firstResult(request, as: NexusFileStatResultPayload.self)
    }

    private func readFile(
        _ file: NexusFileReference,
        offset: Int64,
        maximumLength: Int
    ) async throws -> NexusFileDataPayload {
        let request = try NexusWorkloadRequest(
            kind: .fileRead,
            priority: .background,
            retrySafety: .idempotent,
            payload: NexusFileReadPayload(file: file, offset: offset, maximumLength: maximumLength)
        )
        return try await firstResult(request, as: NexusFileDataPayload.self)
    }

    private func firstResult<Result: Decodable>(
        _ request: NexusWorkloadRequest,
        as type: Result.Type
    ) async throws -> Result {
        let stream = try await executor.events(for: request)
        for try await event in stream {
            try Self.throwIfTerminalFailure(event)
            if event.kind == .result { return try event.decodePayload(type) }
        }
        throw NexusConnectError.requestFailed("Nexus workload returned no result")
    }

    private func drain(_ request: NexusWorkloadRequest) async throws {
        let stream = try await executor.events(for: request)
        for try await event in stream { try Self.throwIfTerminalFailure(event) }
    }

    private static func throwIfTerminalFailure(_ event: NexusWorkloadEvent) throws {
        if event.kind == .failed {
            let failure = try event.decodePayload(NexusRemoteErrorPayload.self)
            throw NexusConnectError.requestFailed(failure.message)
        }
        if event.kind == .cancelled { throw NexusConnectError.cancelled }
    }

    private static func fileSHA256(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }

    private static func requireSafePartialFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw NexusConnectError.pathOutsideAllowedRoots }
    }
}
