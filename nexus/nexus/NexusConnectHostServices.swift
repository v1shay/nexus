import CryptoKit
import Darwin
import Foundation
import Vision

protocol NexusHostModelServing: Sendable {
    func installedModels(runtime: NexusRuntimeKind?) async throws -> [NexusModelDescriptor]
    func pull(
        runtime: NexusRuntimeKind,
        model: String,
        quantization: String?,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws
    func streamChat(
        runtime: NexusRuntimeKind,
        model: String,
        prompt: String,
        onDelta: @escaping @Sendable (String, String) async -> Void
    ) async throws -> String
}

final class NexusLocalModelService: NexusHostModelServing, @unchecked Sendable {
    private let ollama: OllamaManager
    private let lmStudio: LMStudioManager

    init(ollama: OllamaManager = OllamaManager(), lmStudio: LMStudioManager = LMStudioManager()) {
        self.ollama = ollama
        self.lmStudio = lmStudio
    }

    func installedModels(runtime: NexusRuntimeKind?) async throws -> [NexusModelDescriptor] {
        var result: [NexusModelDescriptor] = []
        if runtime == nil || runtime == .ollama {
            if ollama.executableURL() != nil {
                result += try await ollama.installedModelNames().map {
                    NexusModelDescriptor(runtime: .ollama, identifier: $0)
                }
            }
        }
        if runtime == nil || runtime == .lmStudio {
            if lmStudio.executableURL() != nil {
                result += try await lmStudio.installedModelNames().map {
                    NexusModelDescriptor(runtime: .lmStudio, identifier: $0)
                }
            }
        }
        return result.sorted { $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending }
    }

    func pull(
        runtime: NexusRuntimeKind,
        model: String,
        quantization: String?,
        progress: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) async throws {
        switch runtime {
        case .ollama:
            try await ollama.pull(model: model) { update in
                Self.awaitProgress(update, handler: progress)
            }
        case .lmStudio:
            let localModel = LocalModel(
                name: model,
                identifier: model,
                family: "Remote Studio",
                backend: .lmStudio,
                minimumRAMGB: ModelCatalog.estimatedMinimumRAM(for: model),
                quantization: quantization ?? "Q4_K_M"
            )
            try await lmStudio.download(localModel) { update in
                Self.awaitProgress(update, handler: progress)
            }
        }
    }

    func streamChat(
        runtime: NexusRuntimeKind,
        model: String,
        prompt: String,
        onDelta: @escaping @Sendable (String, String) async -> Void
    ) async throws -> String {
        switch runtime {
        case .ollama:
            try await ollama.streamChat(model: model, prompt: prompt, onDelta: onDelta)
        case .lmStudio:
            try await lmStudio.streamChat(model: model, prompt: prompt, onDelta: onDelta)
        }
    }

    private static func awaitProgress(
        _ update: ModelDownloadProgress,
        handler: @escaping @Sendable (ModelDownloadProgress) async -> Void
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await handler(update)
            semaphore.signal()
        }
        semaphore.wait()
    }
}

actor NexusApprovalStore {
    private var tokens: [String: Date] = [:]

    func issue(validFor seconds: TimeInterval = 60) -> String {
        let token = UUID().uuidString.lowercased()
        tokens[token] = Date().addingTimeInterval(max(1, seconds))
        return token
    }

    func consume(_ token: String?) -> Bool {
        guard let token, let expiration = tokens.removeValue(forKey: token) else { return false }
        return expiration >= Date()
    }
}

actor NexusHostJobAccounting {
    private(set) var activeJobs = 0
    private(set) var queuedJobs = 0

    func begin() { activeJobs += 1 }
    func end() { activeJobs = max(0, activeJobs - 1) }
    func snapshot() -> (active: Int, queued: Int) { (activeJobs, queuedJobs) }
}

actor NexusHostServiceExecutor {
    typealias EventSink = @Sendable (NexusWorkloadEvent) async -> Void

    private let nodeID: UUID
    private let nodeName: String
    private let policy: NexusExecutionPolicy
    private let models: any NexusHostModelServing
    private let runner: any NexusCommandRunning
    private let approvals: NexusApprovalStore
    private let index: NexusTextIndex
    private let session: URLSession
    private let jobs = NexusHostJobAccounting()
    private var inventoryDigest = Data()

    init(
        nodeID: UUID,
        nodeName: String = Host.current().localizedName ?? "Mac Studio",
        policy: NexusExecutionPolicy = .defaultStudioPolicy(),
        models: any NexusHostModelServing = NexusLocalModelService(),
        runner: any NexusCommandRunning = NexusFoundationCommandRunner(),
        approvals: NexusApprovalStore = NexusApprovalStore(),
        index: NexusTextIndex = NexusTextIndex(),
        session: URLSession = .shared
    ) {
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.policy = policy
        self.models = models
        self.runner = runner
        self.approvals = approvals
        self.index = index
        self.session = session
    }

    func execute(_ request: NexusWorkloadRequest, sink: @escaping EventSink) async {
        let emitter = NexusWorkloadEmitter(requestID: request.id, sink: sink)
        await jobs.begin()
        await emitter.emit(kind: .accepted, payload: NexusProgressPayload(
            completedBytes: nil, totalBytes: nil, fraction: nil, status: "Accepted by \(nodeName)"
        ))
        do {
            try Task.checkCancellation()
            try policy.require(request.kind.capability)
            try await dispatch(request, emitter: emitter)
            await emitter.emit(kind: .completed, isFinal: true, payload: NexusEmptyPayload())
        } catch is CancellationError {
            await emitter.emit(kind: .cancelled, isFinal: true, payload: NexusEmptyPayload())
        } catch {
            await emitter.emit(kind: .failed, isFinal: true, payload: NexusRemoteErrorPayload(
                code: Self.errorCode(error),
                message: error.localizedDescription,
                retryable: Self.isRetryable(error)
            ))
        }
        await jobs.end()
    }

    func issueProcessApproval(validFor seconds: TimeInterval = 60) async -> String {
        await approvals.issue(validFor: seconds)
    }

    private func dispatch(_ request: NexusWorkloadRequest, emitter: NexusWorkloadEmitter) async throws {
        switch request.kind {
        case .health:
            _ = try request.decodePayload(NexusEmptyPayload.self)
            await emitter.emit(kind: .result, payload: await health())
        case .inference:
            try await inference(try request.decodePayload(), emitter: emitter)
        case .agent:
            try await agent(try request.decodePayload(), emitter: emitter)
        case .modelList:
            let payload: NexusModelListPayload = try request.decodePayload()
            let installed = try await models.installedModels(runtime: payload.runtime)
            inventoryDigest = Data(SHA256.hash(data: try NexusPayloadCoder.encoder.encode(installed)))
            await emitter.emit(kind: .result, payload: NexusModelInventoryPayload(models: installed))
        case .modelPull:
            let payload: NexusModelPullPayload = try request.decodePayload()
            try await models.pull(runtime: payload.runtime, model: payload.model, quantization: payload.quantization) { progress in
                await emitter.emit(kind: .progress, payload: NexusProgressPayload(
                    completedBytes: progress.completedBytes,
                    totalBytes: progress.totalBytes,
                    fraction: progress.fraction,
                    status: progress.status
                ))
            }
            let installed = try await models.installedModels(runtime: payload.runtime)
            guard installed.contains(where: { $0.identifier == payload.model || $0.identifier == "\(payload.model):latest" }) else {
                throw NexusConnectError.requestFailed("The Studio finished downloading but could not verify \(payload.model).")
            }
            inventoryDigest = Data(SHA256.hash(data: try NexusPayloadCoder.encoder.encode(installed)))
            await emitter.emit(kind: .result, payload: NexusModelInventoryPayload(models: installed))
        case .ocr:
            try await recognizeText(try request.decodePayload(), emitter: emitter)
        case .index:
            let payload: NexusIndexPayload = try request.decodePayload()
            let count = try await index.index(payload: payload, policy: policy)
            await emitter.emit(kind: .result, payload: NexusProgressPayload(
                completedBytes: Int64(count), totalBytes: Int64(count), fraction: 1,
                status: "Indexed \(count) files"
            ))
        case .searchIndex:
            let payload: NexusIndexSearchPayload = try request.decodePayload()
            await emitter.emit(kind: .result, payload: NexusIndexSearchResultsPayload(
                results: await index.search(query: payload.query, limit: payload.limit)
            ))
        case .process:
            try await process(try request.decodePayload(), emitter: emitter)
        case .fileStat:
            try await fileStat(try request.decodePayload(), emitter: emitter)
        case .fileRead:
            try await fileRead(try request.decodePayload(), emitter: emitter)
        case .fileWrite:
            try await fileWrite(try request.decodePayload(), emitter: emitter)
        case .fileList:
            try await fileList(try request.decodePayload(), emitter: emitter)
        case .download:
            try await download(try request.decodePayload(), emitter: emitter)
        }
    }

    private func inference(_ payload: NexusInferencePayload, emitter: NexusWorkloadEmitter) async throws {
        let prompt = payload.messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n\n")
        let answer = try await models.streamChat(runtime: payload.runtime, model: payload.model, prompt: prompt) { delta, accumulated in
            await emitter.emit(kind: .token, payload: NexusTextDeltaPayload(delta: delta, accumulated: accumulated))
        }
        await emitter.emit(kind: .result, payload: NexusTextDeltaPayload(delta: "", accumulated: answer))
    }

    private func agent(_ payload: NexusAgentPayload, emitter: NexusWorkloadEmitter) async throws {
        guard (1...32).contains(payload.maximumSteps) else {
            throw NexusConnectError.policyDenied("agent step limit must be between 1 and 32")
        }
        let context = payload.context.map { "\($0.role): \($0.content)" }.joined(separator: "\n\n")
        let prompt = """
        You are a Nexus agent running on the user's paired Mac Studio.
        Follow these instructions carefully: \(payload.instructions)

        Context:
        \(context)
        """
        let answer = try await models.streamChat(runtime: payload.runtime, model: payload.model, prompt: prompt) { delta, accumulated in
            await emitter.emit(kind: .token, payload: NexusTextDeltaPayload(delta: delta, accumulated: accumulated))
        }
        await emitter.emit(kind: .result, payload: NexusTextDeltaPayload(delta: "", accumulated: answer))
    }

    private func recognizeText(_ payload: NexusOCRPayload, emitter: NexusWorkloadEmitter) async throws {
        let data: Data
        if let imageData = payload.imageData {
            guard imageData.count <= NexusConnectProtocol.maximumDataFrameBytes else {
                throw NexusConnectError.frameTooLarge(imageData.count)
            }
            data = imageData
        } else if let file = payload.file {
            data = try Data(contentsOf: policy.resolve(file), options: [.mappedIfSafe])
        } else {
            throw NexusConnectError.requestFailed("OCR needs image data or an allowed file.")
        }
        let languages = payload.recognitionLanguages
        let observations = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if !languages.isEmpty { request.recognitionLanguages = languages }
            let handler = VNImageRequestHandler(data: data)
            try handler.perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }.value
        await emitter.emit(kind: .result, payload: NexusOCRResultPayload(
            text: observations.joined(separator: "\n"), observations: observations
        ))
    }

    private func process(_ payload: NexusProcessPayload, emitter: NexusWorkloadEmitter) async throws {
        let approved = await approvals.consume(payload.approvalToken)
        let rule = try policy.validateProcess(payload, approvalTokenIsValid: approved)
        let workingDirectory = try payload.workingDirectory.map(policy.resolve)
        let result = try await runner.run(
            executable: rule.executableURL,
            arguments: payload.arguments,
            environment: payload.environment,
            workingDirectory: workingDirectory,
            timeoutSeconds: payload.timeoutSeconds,
            maximumOutputBytes: payload.maximumOutputBytes
        )
        if !result.standardOutput.isEmpty {
            await emitter.emit(kind: .standardOutput, payload: NexusProcessOutputPayload(data: result.standardOutput, exitCode: nil))
        }
        if !result.standardError.isEmpty {
            await emitter.emit(kind: .standardError, payload: NexusProcessOutputPayload(data: result.standardError, exitCode: nil))
        }
        await emitter.emit(kind: .result, payload: NexusProcessOutputPayload(data: Data(), exitCode: result.exitCode))
    }

    private func fileStat(_ payload: NexusFileStatPayload, emitter: NexusWorkloadEmitter) async throws {
        let url = try policy.resolve(payload.file)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let attributes = exists ? try FileManager.default.attributesOfItem(atPath: url.path) : [:]
        let modified = (attributes[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970 * 1_000) }
        await emitter.emit(kind: .result, payload: NexusFileStatResultPayload(
            file: payload.file,
            exists: exists,
            isDirectory: isDirectory.boolValue,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAtMilliseconds: modified
        ))
    }

    private func fileRead(_ payload: NexusFileReadPayload, emitter: NexusWorkloadEmitter) async throws {
        guard payload.offset >= 0, (1...NexusConnectProtocol.maximumDataFrameBytes).contains(payload.maximumLength) else {
            throw NexusConnectError.policyDenied("invalid file read range")
        }
        let url = try policy.resolve(payload.file)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(payload.offset))
        let data = try handle.read(upToCount: payload.maximumLength) ?? Data()
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        await emitter.emit(kind: .result, payload: NexusFileDataPayload(
            file: payload.file, offset: payload.offset, data: data,
            endOfFile: payload.offset + Int64(data.count) >= size
        ))
    }

    private func fileWrite(_ payload: NexusFileWritePayload, emitter: NexusWorkloadEmitter) async throws {
        guard payload.offset >= 0, payload.data.count <= NexusConnectProtocol.defaultChunkBytes,
              Data(SHA256.hash(data: payload.data)) == payload.chunkSHA256 else {
            throw NexusConnectError.requestFailed("invalid transfer chunk")
        }
        let destination = try policy.resolve(payload.file)
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(payload.transferID).nexus-part")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        let current = try handle.seekToEnd()
        guard current == UInt64(payload.offset) else {
            throw NexusConnectError.requestFailed("resume offset mismatch; Studio has \(current) bytes")
        }
        try handle.write(contentsOf: payload.data)
        if let finalSize = payload.finalSize, payload.offset + Int64(payload.data.count) == finalSize {
            try handle.synchronize()
            if let finalSHA256 = payload.finalSHA256,
               try Self.fileSHA256(partial) != finalSHA256 {
                throw NexusConnectError.requestFailed("final transfer checksum mismatch")
            }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        await emitter.emit(kind: .progress, payload: NexusProgressPayload(
            completedBytes: payload.offset + Int64(payload.data.count), totalBytes: payload.finalSize,
            fraction: payload.finalSize.map { Double(payload.offset + Int64(payload.data.count)) / Double(max(1, $0)) },
            status: "Transferred to Mac Studio"
        ))
    }

    private func fileList(_ payload: NexusFileListPayload, emitter: NexusWorkloadEmitter) async throws {
        guard (1...10_000).contains(payload.maximumEntries) else {
            throw NexusConnectError.policyDenied("invalid file listing limit")
        }
        let root = try policy.resolve(payload.directory)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let options: FileManager.DirectoryEnumerationOptions = payload.recursive ? [] : [.skipsSubdirectoryDescendants]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else {
            throw NexusConnectError.requestFailed("could not list the requested folder")
        }
        var entries: [NexusFileListEntry] = []
        for case let url as URL in enumerator {
            if entries.count >= payload.maximumEntries { break }
            let values = try url.resourceValues(forKeys: Set(keys))
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let base = payload.directory.relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let reference = NexusFileReference(
                rootID: payload.directory.rootID,
                relativePath: [base, relative].filter { !$0.isEmpty }.joined(separator: "/")
            )
            _ = try policy.resolve(reference)
            entries.append(.init(file: reference, isDirectory: values.isDirectory ?? false, size: Int64(values.fileSize ?? 0)))
        }
        await emitter.emit(kind: .result, payload: NexusFileListResultPayload(entries: entries))
    }

    private func download(_ payload: NexusDownloadPayload, emitter: NexusWorkloadEmitter) async throws {
        guard payload.sourceURL.scheme == "https" else {
            throw NexusConnectError.policyDenied("Studio downloads require HTTPS")
        }
        let destination = try policy.resolve(payload.destination)
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(payload.transferID).nexus-download")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber)?.int64Value ?? 0
        var request = URLRequest(url: payload.sourceURL)
        request.timeoutInterval = 60
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NexusConnectError.requestFailed("download server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let resumed = existing > 0 && http.statusCode == 206
        if !resumed { try? FileManager.default.removeItem(at: partial) }
        if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        if resumed { _ = try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
        var completed = resumed ? existing : 0
        let expectedTotal = response.expectedContentLength > 0 ? completed + response.expectedContentLength : nil
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 64 * 1_024 {
                try handle.write(contentsOf: buffer)
                completed += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await emitter.emit(kind: .progress, payload: NexusProgressPayload(
                    completedBytes: completed, totalBytes: expectedTotal,
                    fraction: expectedTotal.map { Double(completed) / Double(max(1, $0)) },
                    status: resumed ? "Resuming on Mac Studio" : "Downloading on Mac Studio"
                ))
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); completed += Int64(buffer.count) }
        try handle.synchronize()
        let digest = try Self.fileSHA256(partial)
        if let expected = payload.expectedSHA256, digest != expected {
            throw NexusConnectError.requestFailed("download checksum mismatch")
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
        await emitter.emit(kind: .result, payload: NexusDownloadResultPayload(
            destination: payload.destination, byteCount: completed, sha256: digest
        ))
    }

    private func health() async -> NexusNodeHealth {
        let accounting = await jobs.snapshot()
        let memory = Self.memorySnapshot()
        let disk = (try? FileManager.default.attributesOfFileSystem(forPath: FileManager.default.homeDirectoryForCurrentUser.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        var load = [Double](repeating: 0, count: 3)
        let count = getloadavg(&load, 3)
        if count < 3 { load = Array(load.prefix(max(0, Int(count)))) }
        return .init(
            nodeID: nodeID,
            nodeName: nodeName,
            hostVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1",
            protocolMinimum: NexusConnectProtocol.minimumVersion,
            protocolMaximum: NexusConnectProtocol.currentVersion,
            capabilities: policy.allowedCapabilities,
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            totalMemoryBytes: memory.total,
            availableMemoryBytes: memory.available,
            availableDiskBytes: disk,
            queueDepth: accounting.queued,
            activeJobs: accounting.active,
            loadAverage: load,
            modelInventoryDigest: inventoryDigest,
            timestampMilliseconds: NexusClock.nowMilliseconds()
        )
    }

    private static func memorySnapshot() -> (total: UInt64, available: UInt64) {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let available: UInt64
        if result == KERN_SUCCESS {
            available = UInt64(statistics.free_count + statistics.inactive_count) * UInt64(pageSize)
        } else {
            available = 0
        }
        return (ProcessInfo.processInfo.physicalMemory, available)
    }

    private static func fileSHA256(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty { hasher.update(data: data) }
        return Data(hasher.finalize())
    }

    private static func errorCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if case NexusConnectError.policyDenied = error { return "policy_denied" }
        return "request_failed"
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case NexusConnectError.unavailable = error { return true }
        return false
    }
}

actor NexusWorkloadEmitter {
    private let requestID: UUID
    private let sink: NexusHostServiceExecutor.EventSink
    private var sequence: UInt64 = 0

    init(requestID: UUID, sink: @escaping NexusHostServiceExecutor.EventSink) {
        self.requestID = requestID
        self.sink = sink
    }

    func emit<Payload: Encodable>(
        kind: NexusWorkloadEventKind,
        isFinal: Bool = false,
        payload: Payload
    ) async {
        guard let event = try? NexusWorkloadEvent(
            requestID: requestID,
            kind: kind,
            sequence: sequence,
            isFinal: isFinal,
            payload: payload
        ) else { return }
        sequence += 1
        await sink(event)
    }
}

actor NexusTextIndex {
    private struct Document: Codable {
        let file: NexusFileReference
        let text: String
        let terms: [String: Int]
    }

    private var documents: [String: Document] = [:]
    private let persistenceURL: URL?

    init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        if let persistenceURL,
           let data = try? Data(contentsOf: persistenceURL),
           let saved = try? NexusPayloadCoder.decoder.decode([String: Document].self, from: data) {
            documents = saved
        }
    }

    func index(payload: NexusIndexPayload, policy: NexusExecutionPolicy) throws -> Int {
        if payload.replaceExisting {
            documents = documents.filter { $0.value.file.rootID != payload.rootID }
        }
        var indexed = 0
        for relativePath in payload.relativePaths {
            let reference = NexusFileReference(rootID: payload.rootID, relativePath: relativePath)
            let url = try policy.resolve(reference)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let child as URL in enumerator {
                        let canonicalChild = child.resolvingSymlinksInPath().standardizedFileURL
                        let suffix = String(canonicalChild.path.dropFirst(url.path.count))
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        let childReference = NexusFileReference(
                            rootID: payload.rootID,
                            relativePath: [relativePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
                        )
                        _ = try policy.resolve(childReference)
                        if try indexFile(canonicalChild, reference: childReference) { indexed += 1 }
                    }
                }
            } else if try indexFile(url, reference: reference) {
                indexed += 1
            }
        }
        try persist()
        return indexed
    }

    func search(query: String, limit: Int) -> [NexusIndexSearchResult] {
        let queryTerms = Self.tokenize(query)
        guard !queryTerms.isEmpty else { return [] }
        return documents.values.compactMap { document -> NexusIndexSearchResult? in
            let score = queryTerms.reduce(0.0) { $0 + Double(document.terms[$1] ?? 0) }
            guard score > 0 else { return nil }
            let snippet = String(document.text.prefix(500)).replacingOccurrences(of: "\n", with: " ")
            return .init(file: document.file, score: score, snippet: snippet)
        }
        .sorted { $0.score > $1.score }
        .prefix(max(1, min(100, limit)))
        .map { $0 }
    }

    private func indexFile(_ url: URL, reference: NexusFileReference) throws -> Bool {
        let supported = Set(["txt", "md", "swift", "py", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "csv", "html", "css", "sh"])
        guard supported.contains(url.pathExtension.lowercased()) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 10 * 1_024 * 1_024,
              let text = try? String(contentsOf: url) else { return false }
        let terms = Dictionary(grouping: Self.tokenize(text), by: { $0 }).mapValues(\.count)
        documents["\(reference.rootID):\(reference.relativePath)"] = Document(file: reference, text: text, terms: terms)
        return true
    }

    private func persist() throws {
        guard let persistenceURL else { return }
        try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NexusPayloadCoder.encoder.encode(documents).write(to: persistenceURL, options: .atomic)
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init)
    }
}
