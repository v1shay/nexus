import Foundation

enum NexusResponseInstructions {
    static let conciseSystemPrompt = """
    You are Nex, a highly advanced personal assistant and occasional babysitter. Never call yourself Nexus. If asked who you are, what you are, or your name, answer: “I’m Nex, your highly advanced personal assistant and occasional babysitter. What would you like me to do?”

    Be exceptionally intelligent, direct, accurate, and concise. Concise means removing filler, repetition, obvious explanations, greetings, and narrated reasoning; it never means omitting requested work. Give ordinary answers in one to three sharp sentences when that fully answers the request. When the user asks for code, a plan, steps, a list, analysis, creative work, or any larger deliverable, provide the complete deliverable at the necessary length. Never truncate code, stop after an example, replace requested sections with placeholders, or claim the rest is implied. Preserve requested Markdown, code, math, and structure.

    Be funny, mischievous, silly, and heavily sarcastic when the situation allows it. Playfully roast the user and yourself when it is genuinely funny, but never let the joke reduce correctness, completeness, clarity, or safety. Do not roast sensitive traits, distress, emergencies, or serious personal situations. Match the user’s energy without becoming repetitive or obnoxious.
    """
}

final class OllamaManager: @unchecked Sendable {
    static let serverURL = URL(string: "http://127.0.0.1:11434")!
    static let officialMacDownloadURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!

    private let session: URLSession
    private let fileManager: FileManager
    private let processLock = NSLock()
    private var managedServerProcess: Process?

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func executableURL() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
            "\(home)/Applications/Ollama.app/Contents/Resources/ollama"
        ]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    func installOfficialMacApp() async throws {
        let (archive, response) = try await session.download(from: Self.officialMacDownloadURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalModelError.installFailed("the official server did not return the app")
        }
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let applicationsDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: applicationsDirectory, withIntermediateDirectories: true)
            try await Self.runProcess(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, temporaryDirectory.path])
            let source = temporaryDirectory.appendingPathComponent("Ollama.app", isDirectory: true)
            let destination = applicationsDirectory.appendingPathComponent("Ollama.app", isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: source, to: destination)
            try? fileManager.removeItem(at: temporaryDirectory)
        } catch let error as LocalModelError {
            throw error
        } catch {
            throw LocalModelError.installFailed(error.localizedDescription)
        }
        guard executableURL() != nil else { throw LocalModelError.installFailed("the app archive did not contain the Ollama CLI") }
    }

    func ensureServerRunning() async throws {
        if await serverResponds() { return }
        guard let executable = executableURL() else { throw LocalModelError.ollamaMissing }

        let existing = currentManagedServer()
        if existing?.isRunning != true {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.environment = ProcessInfo.processInfo.environment
            do { try process.run() } catch { throw LocalModelError.serverUnavailable("Ollama") }
            setManagedServer(process)
        }
        for _ in 0..<60 {
            try Task.checkCancellation()
            if await serverResponds() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        stopManagedServer()
        throw LocalModelError.serverUnavailable("Ollama")
    }

    func pull(model identifier: String, progress: @escaping (ModelDownloadProgress) -> Void) async throws {
        try await ensureServerRunning()
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OllamaPullRequest(model: identifier, stream: true))
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Self.requireSuccess(response)
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
                let event = try JSONDecoder().decode(OllamaPullEvent.self, from: data)
                if let error = event.error { throw LocalModelError.downloadFailed("Ollama could not download \(identifier): \(error)") }
                progress(.init(completedBytes: event.completed, totalBytes: event.total, status: event.status))
            }
        } catch is CancellationError {
            throw LocalModelError.cancelled
        }
        guard try await installedModelNames().contains(where: { Self.namesMatch($0, identifier) }) else {
            throw LocalModelError.verificationFailed(identifier)
        }
    }

    func installedModelNames() async throws -> [String] {
        try await ensureServerRunning()
        let (data, response) = try await session.data(from: Self.serverURL.appendingPathComponent("api/tags"))
        try Self.requireSuccess(response)
        return try JSONDecoder().decode(OllamaTagsResponse.self, from: data).models.map(\.name)
    }

    func streamChat(
        model: String,
        prompt: String,
        onDelta: @escaping @Sendable (_ delta: String, _ accumulated: String) async -> Void
    ) async throws -> String {
        try await ensureServerRunning()
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OllamaChatRequest(
                model: model,
                messages: [
                    .init(role: "system", content: NexusResponseInstructions.conciseSystemPrompt),
                    .init(role: "user", content: prompt)
                ],
                stream: true
            )
        )
        let (bytes, response) = try await session.bytes(for: request)
        try Self.requireSuccess(response)
        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
            let event = try JSONDecoder().decode(OllamaChatStreamEvent.self, from: data)
            if let error = event.error { throw LocalModelError.invalidResponse(error) }
            if let delta = event.message?.content, !delta.isEmpty {
                accumulated += delta
                await onDelta(delta, accumulated)
            }
        }
        let answer = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw LocalModelError.invalidResponse("Ollama returned an empty answer") }
        return answer
    }

    func stopManagedServer() {
        processLock.lock()
        let process = managedServerProcess
        managedServerProcess = nil
        processLock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func currentManagedServer() -> Process? {
        processLock.lock(); defer { processLock.unlock() }
        return managedServerProcess
    }

    private func setManagedServer(_ process: Process) {
        processLock.lock(); defer { processLock.unlock() }
        managedServerProcess = process
    }

    private func serverResponds() async -> Bool {
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalModelError.invalidResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
    }

    private static func namesMatch(_ installed: String, _ requested: String) -> Bool {
        installed == requested || installed == "\(requested):latest" || requested == "\(installed):latest"
    }

    private static func runProcess(executable: URL, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        }
        guard status == 0 else { throw LocalModelError.installFailed("the archive could not be extracted") }
    }
}

private struct OllamaPullRequest: Encodable { let model: String; let stream: Bool }
private struct OllamaPullEvent: Decodable { let status: String; let completed: Int64?; let total: Int64?; let error: String? }
private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}
private struct OllamaChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    let model: String
    let messages: [Message]
    let stream: Bool
}
private struct OllamaChatStreamEvent: Decodable {
    struct Message: Decodable { let content: String }
    let message: Message?
    let error: String?
}

final class LMStudioManager: @unchecked Sendable {
    static let serverURL = URL(string: "http://127.0.0.1:1234")!

    private let fileManager: FileManager
    private let session: URLSession
    private let processLock = NSLock()
    private var downloads: [String: Process] = [:]
    private var serverStartProcess: Process?

    init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
    }

    func executableURL() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.lmstudio/bin/lms", "/opt/homebrew/bin/lms", "/usr/local/bin/lms",
            "/Applications/LM Studio.app/Contents/Resources/app/.webpack/lms"
        ]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    func download(_ model: LocalModel, progress: @escaping (ModelDownloadProgress) -> Void) async throws {
        guard let executable = executableURL() else { throw LocalModelError.lmStudioMissing }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        let quantization = model.quantization.map { "@\($0.lowercased())" } ?? ""
        let identifier = model.identifier.contains("/") && !model.identifier.hasPrefix("http")
            ? "https://huggingface.co/\(model.identifier)"
            : model.identifier
        process.arguments = ["get", "-y", "--gguf", "\(identifier)\(quantization)"]
        process.standardOutput = output
        process.standardError = output
        process.environment = ProcessInfo.processInfo.environment

        guard register(process, for: model.id) else { return }

        let accumulatedOutput = SynchronizedText()
        output.fileHandleForReading.readabilityHandler = { handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            let snapshot = accumulatedOutput.append(text)
            if let percentage = Self.lastPercentage(in: snapshot) {
                progress(.init(completedBytes: Int64(percentage), totalBytes: 100, status: "Downloading with LM Studio"))
            }
        }
        do { try process.run() } catch {
            cleanup(id: model.id, pipe: output)
            throw LocalModelError.downloadFailed("LM Studio could not start its downloader: \(error.localizedDescription)")
        }
        let status = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        cleanup(id: model.id, pipe: output)
        if Task.isCancelled { throw LocalModelError.cancelled }
        guard status == 0 else {
            let detail = accumulatedOutput.value.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalModelError.downloadFailed(detail.isEmpty ? "LM Studio could not download \(model.identifier)." : detail)
        }
        guard try await isInstalled(model) else { throw LocalModelError.verificationFailed(model.identifier) }
        progress(.init(completedBytes: 1, totalBytes: 1, status: "Installed"))
    }

    func cancel(modelID: String) {
        processLock.lock(); let process = downloads[modelID]; processLock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    func installedModelNames() async throws -> [String] {
        try await ensureServerRunning()
        let (data, response) = try await session.data(from: Self.serverURL.appendingPathComponent("v1/models"))
        try Self.requireSuccess(response)
        return try JSONDecoder().decode(OpenAIModelsResponse.self, from: data).data.map(\.id)
    }

    func streamChat(
        model: String,
        prompt: String,
        onDelta: @escaping @Sendable (_ delta: String, _ accumulated: String) async -> Void
    ) async throws -> String {
        try await ensureServerRunning()
        let resolvedModel = await resolvedModelIdentifier(preferred: model)
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OpenAIChatRequest(
                model: resolvedModel,
                messages: [
                    .init(role: "system", content: NexusResponseInstructions.conciseSystemPrompt),
                    .init(role: "user", content: prompt)
                ],
                stream: true
            )
        )
        let (bytes, response) = try await session.bytes(for: request)
        try Self.requireSuccess(response)
        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8), !data.isEmpty else { continue }
            let event = try JSONDecoder().decode(OpenAIChatStreamResponse.self, from: data)
            if let message = event.error?.message { throw LocalModelError.invalidResponse(message) }
            if let delta = event.choices?.first?.delta.content, !delta.isEmpty {
                accumulated += delta
                await onDelta(delta, accumulated)
            }
        }
        let answer = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw LocalModelError.invalidResponse("LM Studio returned an empty answer") }
        return answer
    }

    func ensureServerRunning() async throws {
        if await serverResponds() { return }
        guard let executable = executableURL() else { throw LocalModelError.lmStudioMissing }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["server", "start"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment
        do { try process.run() } catch { throw LocalModelError.serverUnavailable("LM Studio") }
        setServerStartProcess(process)
        for _ in 0..<80 {
            try Task.checkCancellation()
            if await serverResponds() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw LocalModelError.serverUnavailable("LM Studio")
    }

    func stopManagedProcesses() {
        processLock.lock()
        var processes = Array(downloads.values)
        if let serverStartProcess { processes.append(serverStartProcess) }
        downloads.removeAll()
        serverStartProcess = nil
        processLock.unlock()
        processes.filter(\.isRunning).forEach { $0.terminate() }
    }

    private func serverResponds() async -> Bool {
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("v1/models"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    private func resolvedModelIdentifier(preferred: String) async -> String {
        let needle = preferred.split(separator: "/").last.map(String.init) ?? preferred
        if let (data, _) = try? await session.data(from: Self.serverURL.appendingPathComponent("api/v1/models")),
           let response = try? JSONDecoder().decode(LMStudioModelsResponse.self, from: data),
           let match = response.models.first(where: { $0.key == preferred || $0.key.localizedCaseInsensitiveContains(needle) }) {
            return match.key
        }
        if let (data, _) = try? await session.data(from: Self.serverURL.appendingPathComponent("v1/models")),
           let response = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data),
           let match = response.data.first(where: { $0.id == preferred || $0.id.localizedCaseInsensitiveContains(needle) }) {
            return match.id
        }
        return preferred
    }

    private func setServerStartProcess(_ process: Process) {
        processLock.lock(); defer { processLock.unlock() }
        serverStartProcess = process
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalModelError.invalidResponse("LM Studio HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
    }

    private func isInstalled(_ model: LocalModel) async throws -> Bool {
        guard let executable = executableURL() else { return false }
        let process = Process(); let output = Pipe()
        process.executableURL = executable; process.arguments = ["ls"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let listing = String(data: data, encoding: .utf8) ?? ""
        let needle = model.identifier.split(separator: "/").last.map(String.init) ?? model.identifier
        return process.terminationStatus == 0 && listing.localizedCaseInsensitiveContains(needle)
    }

    private func cleanup(id: String, pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
        processLock.lock(); downloads[id] = nil; processLock.unlock()
    }

    private func register(_ process: Process, for id: String) -> Bool {
        processLock.lock(); defer { processLock.unlock() }
        guard downloads[id] == nil else { return false }
        downloads[id] = process
        return true
    }

    private static func lastPercentage(in text: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: #"(\d{1,3})(?:\.\d+)?%"#),
              let match = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range]).map { min(100, $0) }
    }
}

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    let model: String
    let messages: [Message]
    let stream: Bool
}
private struct OpenAIChatStreamResponse: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]?
    let error: APIError?

    struct APIError: Decodable { let message: String }
}
private struct LMStudioModelsResponse: Decodable {
    struct Model: Decodable { let key: String }
    let models: [Model]
}
private struct OpenAIModelsResponse: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}

private final class SynchronizedText: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) -> String {
        lock.lock(); defer { lock.unlock() }
        storage += text
        return storage
    }

    var value: String {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
