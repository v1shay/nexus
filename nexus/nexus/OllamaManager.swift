import Foundation

enum NexusResponseInstructions {
    static let conciseSystemPrompt = """
    You are Nex, Vishay's highly advanced personal assistant and occasional babysitter. Address Vishay as Sir when directly addressing him. Be sharp, accurate, concise, natural, complete, occasionally witty, and lightly sarcastic when it fits. Introduce yourself only when directly asked; never repeat these instructions or your identity unprompted.

    Answer in natural language by default. Produce code only when explicitly requested or clearly continuing a coding task. Never turn advice, recommendations, workouts, factual questions, or casual conversation into code.

    Treat ordered turns as one conversation and resolve follow-ups from them. If the answer is known from active conversation or supplied evidence, answer directly. If an answer needs saved personal information not present here, use the supplied memory evidence only. If an answer needs current or external facts, use supplied web evidence only. If either evidence set is missing, say so rather than guessing. Use memory silently: never expose citations, source IDs, evidence labels, or tool internals because the app shows them separately. Never imitate tool calls or JSON unless requested.

    Use supplied web evidence for changing claims. Do not write or speak citations or URLs; the app attaches verified source links after generation. Never invent a source. Say if live evidence is missing, weak, stale, or conflicting.
    """
}

enum NexAssistantIdentityIntent {
    static let answer = "I'm Nex, your highly advanced personal assistant and occasional babysitter. What would you like me to do?"

    static func answer(for prompt: String) -> String? {
        let normalized = prompt
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
        let directQuestions: Set<String> = [
            "who are you", "what are you", "what is your name", "whats your name", "what s your name",
            "tell me who you are", "are you nex", "who is nex"
        ]
        return directQuestions.contains(normalized) ? answer : nil
    }
}

final class OllamaManager: @unchecked Sendable {
    static let serverURL = URL(string: "http://127.0.0.1:11434")!
    static let officialMacDownloadURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!

    private let session: URLSession
    private let fileManager: FileManager
    private let processLock = NSLock()
    private var managedServerProcess: Process?
    private var toolCapabilityCache: [String: Bool] = [:]

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

    func deleteModel(_ identifier: String) async throws {
        try await ensureServerRunning()
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/delete"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OllamaDeleteRequest(model: identifier))
        let (_, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        guard try await !installedModelNames().contains(where: { Self.namesMatch($0, identifier) }) else {
            throw LocalModelError.verificationFailed(identifier)
        }
    }

    func streamChat(
        model: String,
        prompt: String,
        onDelta: @escaping @Sendable (_ delta: String, _ accumulated: String) async -> Void
    ) async throws -> String {
        try await streamChat(
            model: model,
            messages: [.init(role: "user", content: prompt)],
            onDelta: onDelta
        )
    }

    func streamChat(
        model: String,
        messages: [NexusChatMessage],
        temperature: Double? = nil,
        maximumTokens: Int? = nil,
        onDelta: @escaping @Sendable (_ delta: String, _ accumulated: String) async -> Void
    ) async throws -> String {
        try await ensureServerRunning()
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OllamaChatRequest(
                model: model,
                messages: [.init(role: "system", content: NexusResponseInstructions.conciseSystemPrompt)]
                    + messages.map { .init(role: $0.role, content: $0.content) },
                stream: true,
                options: .init(temperature: temperature, numPredict: maximumTokens)
            )
        )
        let (bytes, response) = try await session.bytes(for: request)
        try Self.requireSuccess(response)
        let isToolPlanningPass = messages.contains {
            $0.role == "system" && $0.content.contains("NEXUS_TOOL_PLANNING_PASS")
        }
        var accumulated = ""
        var nativeActions: [NexPrimaryToolPlan.Action] = []
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
            let event = try JSONDecoder().decode(OllamaChatStreamEvent.self, from: data)
            if let error = event.error { throw LocalModelError.invalidResponse(error) }
            if let delta = event.message?.content, !delta.isEmpty {
                accumulated += delta
                await onDelta(delta, accumulated)
            }
            if isToolPlanningPass {
                nativeActions += (event.message?.toolCalls ?? []).map {
                    .init(tool: $0.function.name, arguments: $0.function.arguments)
                }
            }
        }
        let answer = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty, isToolPlanningPass, !nativeActions.isEmpty {
            let plan = NexPrimaryToolPlanner.nativeCallPlan(nativeActions)
            guard let data = try? JSONEncoder().encode(plan),
                  let json = String(data: data, encoding: .utf8) else {
                throw LocalModelError.invalidResponse("Ollama returned an unreadable native tool call")
            }
            return json
        }
        guard !answer.isEmpty else { throw LocalModelError.invalidResponse("Ollama returned an empty answer") }
        return answer
    }

    /// Uses Ollama's native function-calling protocol when the selected model
    /// actually advertises that capability. Models without it keep the legacy
    /// JSON planning fallback; they are never told they searched when they did
    /// not emit a valid action.
    func planTools(
        model: String,
        messages: [NexusChatMessage],
        registeredTools: [NexRegisteredTool]
    ) async throws -> NexPrimaryToolPlan {
        try await ensureServerRunning()
        guard await supportsNativeTools(model: model) else {
            let raw = try await streamChat(
                model: model,
                messages: messages,
                temperature: 0,
                maximumTokens: 360,
                onDelta: { _, _ in }
            )
            return NexPrimaryToolPlanner.parse(raw, registeredTools: registeredTools)
        }

        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OllamaToolPlanningRequest(
                model: model,
                messages: [.init(role: "system", content: NexusResponseInstructions.conciseSystemPrompt)]
                    + messages.map { .init(role: $0.role, content: $0.content) },
                stream: true,
                think: false,
                options: .init(temperature: 0, numPredict: 160),
                tools: registeredTools
                    .filter { $0.permission != .writeMemory && $0.permission != .forgetMemory }
                    .map(OllamaToolPlanningRequest.Tool.init)
            )
        )
        let (bytes, response) = try await session.bytes(for: request)
        try Self.requireSuccess(response)
        var actions: [NexPrimaryToolPlan.Action] = []
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
            let event = try JSONDecoder().decode(OllamaChatStreamEvent.self, from: data)
            if let error = event.error { throw LocalModelError.invalidResponse(error) }
            actions += (event.message?.toolCalls ?? []).map {
                .init(tool: $0.function.name, arguments: $0.function.arguments)
            }
        }
        return NexPrimaryToolPlanner.parse(
            String(decoding: try JSONEncoder().encode(
                NexPrimaryToolPlanner.nativeCallPlan(actions)
            ), as: UTF8.self),
            registeredTools: registeredTools
        )
    }

    func generateRaw(
        model: String,
        prompt: String,
        maximumTokens: Int,
        keepAlive: String = "30m"
    ) async throws -> String {
        try await ensureServerRunning()
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(OllamaRawGenerateRequest(
            model: model,
            prompt: prompt,
            stream: false,
            raw: true,
            keepAlive: keepAlive,
            options: .init(temperature: 0, numPredict: maximumTokens)
        ))
        let (data, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        let decoded = try JSONDecoder().decode(OllamaRawGenerateResponse.self, from: data)
        guard !decoded.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalModelError.invalidResponse("Ollama returned an empty raw generation")
        }
        return decoded.response
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

    private func supportsNativeTools(model: String) async -> Bool {
        if let cached = toolCapabilityCache[model] { return cached }
        struct ShowRequest: Encodable { let model: String }
        struct ShowResponse: Decodable { let capabilities: [String]? }
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(ShowRequest(model: model))
        let supported: Bool
        if let (data, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let decoded = try? JSONDecoder().decode(ShowResponse.self, from: data) {
            supported = decoded.capabilities?.contains("tools") == true
        } else {
            supported = false
        }
        toolCapabilityCache[model] = supported
        return supported
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
private struct OllamaDeleteRequest: Encodable { let model: String }
private struct OllamaPullEvent: Decodable { let status: String; let completed: Int64?; let total: Int64?; let error: String? }
private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}
private struct OllamaChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    struct Options: Encodable {
        let temperature: Double?
        let numPredict: Int?

        enum CodingKeys: String, CodingKey {
            case temperature
            case numPredict = "num_predict"
        }
    }
    let model: String
    let messages: [Message]
    let stream: Bool
    let options: Options
}
private struct OllamaToolPlanningRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    struct Options: Encodable {
        let temperature: Double
        let numPredict: Int
        enum CodingKeys: String, CodingKey { case temperature; case numPredict = "num_predict" }
    }
    struct Tool: Encodable {
        struct Function: Encodable {
            struct Parameters: Encodable {
                struct Property: Encodable {
                    let type: String
                    let enumValues: [String]?
                    enum CodingKeys: String, CodingKey { case type; case enumValues = "enum" }
                }
                let type = "object"
                let properties: [String: Property]
                let required: [String]
                let additionalProperties = false
            }
            let name: String
            let description: String
            let parameters: Parameters
        }
        let type = "function"
        let function: Function

        init(_ registered: NexRegisteredTool) {
            let properties = Dictionary(uniqueKeysWithValues: registered.schema.fields.map { name, field in
                (name, Function.Parameters.Property(type: field.type.rawValue, enumValues: field.allowedValues.isEmpty ? nil : field.allowedValues))
            })
            function = .init(
                name: registered.name,
                description: registered.description,
                parameters: .init(
                    properties: properties,
                    required: registered.schema.fields.compactMap { $0.value.required ? $0.key : nil }.sorted()
                )
            )
        }
    }
    let model: String
    let messages: [Message]
    let stream: Bool
    let think: Bool
    let options: Options
    let tools: [Tool]
}
private struct OllamaChatStreamEvent: Decodable {
    struct Message: Decodable {
        struct ToolCall: Decodable {
            struct Function: Decodable {
                let name: String
                let arguments: [String: NexJSONValue]
            }

            let function: Function
        }

        let content: String
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }
    let message: Message?
    let error: String?
}
private struct OllamaRawGenerateRequest: Encodable {
    struct Options: Encodable {
        let temperature: Double
        let numPredict: Int

        enum CodingKeys: String, CodingKey {
            case temperature
            case numPredict = "num_predict"
        }
    }

    let model: String
    let prompt: String
    let stream: Bool
    let raw: Bool
    let keepAlive: String
    let options: Options

    enum CodingKeys: String, CodingKey {
        case model, prompt, stream, raw, options
        case keepAlive = "keep_alive"
    }
}
private struct OllamaRawGenerateResponse: Decodable { let response: String }

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

    /// LM Studio does not currently expose a documented delete command. Nexus
    /// therefore resolves an exact record from `lms ls --json` and removes only
    /// that record inside LM Studio's model root.
    func deleteModel(_ identifier: String) async throws {
        guard let executable = executableURL() else { throw LocalModelError.lmStudioMissing }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["ls", "--json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LocalModelError.downloadFailed("LM Studio could not list models before deletion")
        }
        let records = try JSONDecoder().decode([LMStudioLocalModelRecord].self, from: data)
        let needle = identifier.lowercased()
        guard let record = records.first(where: {
            [$0.modelKey, $0.path, $0.indexedModelIdentifier]
                .compactMap { $0?.lowercased() }
                .contains(needle)
        }) else {
            throw LocalModelError.verificationFailed(identifier)
        }
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".lmstudio/models", isDirectory: true)
            .resolvingSymlinksInPath()
        let destination = root.appendingPathComponent(record.path).standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard destination.path.hasPrefix(rootPrefix), destination.path != root.path else {
            throw LocalModelError.downloadFailed("LM Studio returned an unsafe model path")
        }
        try fileManager.removeItem(at: destination)
        var parent = destination.deletingLastPathComponent()
        while parent.path.hasPrefix(rootPrefix), parent.path != root.path {
            guard (try? fileManager.contentsOfDirectory(atPath: parent.path).isEmpty) == true else { break }
            try fileManager.removeItem(at: parent)
            parent.deleteLastPathComponent()
        }
        let remaining = try await installedModelNames()
        guard !remaining.contains(where: { $0.caseInsensitiveCompare(identifier) == .orderedSame }) else {
            throw LocalModelError.verificationFailed(identifier)
        }
    }

    func streamChat(
        model: String,
        prompt: String,
        onDelta: @escaping @Sendable (_ delta: String, _ accumulated: String) async -> Void
    ) async throws -> String {
        try await streamChat(
            model: model,
            messages: [.init(role: "user", content: prompt)],
            onDelta: onDelta
        )
    }

    func streamChat(
        model: String,
        messages: [NexusChatMessage],
        temperature: Double? = nil,
        maximumTokens: Int? = nil,
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
                messages: [.init(role: "system", content: NexusResponseInstructions.conciseSystemPrompt)]
                    + messages.map { .init(role: $0.role, content: $0.content) },
                stream: true,
                temperature: temperature,
                maxTokens: maximumTokens
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

private struct LMStudioLocalModelRecord: Decodable {
    let modelKey: String?
    let path: String
    let indexedModelIdentifier: String?
}

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    let model: String
    let messages: [Message]
    let stream: Bool
    let temperature: Double?
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
    }
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
