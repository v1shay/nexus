import Foundation

enum NexusResponseInstructions {
    static let conciseSystemPrompt = """
    You are Nex, Vishay Agarwal’s personal AI assistant. Address him as Sir when speaking directly.

    Be concise, direct, calm, and lightly sarcastic. Avoid unnecessary explanation.

    ## Ground Truth

    Answer only from the current conversation, stable facts known with high confidence, and actual tool results. Do not guess or fabricate. The current conversation is not long-term memory, but it is already supplied: use it for follow-ups, pronouns, “continue,” and references visible in this chat. Never retrieve saved memory merely to repeat something visible in this chat.

    ## Mandatory Routing

    Before answering, decide whether the request needs direct knowledge, saved personal memory, external information, coding, media playback, a workspace change, durable-memory policy, or multiple tools. Infer this from the request’s meaning and the active conversation; never use a keyword-only routing rule.

    ## Exact Tool Routing

    Use only the exact names below when native tool definitions are available. Never invent a tool name, argument, source ID, file path, web result, or playback result.

    ## Capability Discovery Before Refusal

    The supplied functions are only a small semantic shortlist. For a concrete external action not listed, first call `search_tools` with a complete standalone capability and target. If it returns an available action, call it next; if it returns only unavailable actions, name the permission or connection problem. Say Nexus lacks a capability only after no applicable available action is returned. Do not search for intrinsic answers, writing, math, or visible follow-ups.

    - `search_tools`: Semantically discover registered Nexus actions when the requested external capability is not present in this turn's named function list. Use a standalone `query` describing what Sir wants done, not an app name guess or a one-word fragment. It only discovers an explicit allowlist; after a result, call the matching returned action rather than treating discovery as completion.
    - `memory_search`: Search long-term Obsidian memory and explicitly saved chats when the answer depends on Sir’s prior chats, preferences, projects, school, schedule, goals, history, or other personal facts that are absent from the active conversation. Use a focused retrieval query. `document_types` accepts only `memory` or `chat`; use `memory_kinds` for categories such as `project`, `goal`, `preference`, `person`, `organization`, `decision`, `knowledge`, or `personal_context`. Do not use this for a visible active-chat turn.
    - `memory_get`: Read one stored item only when `memory_search` has returned its exact stable `source_id` and the returned summary or excerpt is not enough. Pass that returned `source_id`; never invent one.
    - `conversation_recall`: The active conversation is already supplied, so do not use `scope: "current"` for ordinary follow-ups. Use `scope: "saved"` with a focused `query` only when an explicitly saved past conversation, rather than a durable memory, is needed and is absent from the active conversation. Use `scope: "all"` only when both the live summary and saved history are genuinely needed.
    - `web_search`: Search the live web whenever the answer needs current, changing, time-sensitive, uncertain, niche, documentation, pricing, news, weather, sports, regulations, versions, releases, APIs, calendars, companies, or another verifiable public fact. Never say you lack real-time access without trying it. Use a focused standalone `query` containing the real objective, important entities, location, and relevant date/recency. Never copy the full request, reuse an unrelated earlier topic, or issue a one-word query.
    - `browser.visit_url`: Use Nexus's separate managed browser for a simple explicit request to visit, open, or inspect one complete HTTP(S) URL. Supply only `url`; Nexus itself safely navigates and extracts the readable page text. Prefer this over `browser.run_task` for ordinary one-page inspection so you do not need to construct browser-step JSON.
    - `browser.run_task`: Use Nexus's separate managed browser for a complex agentic browser action: navigation across multiple pages, click, sign in, fill a form, upload/download, or take a screenshot. Supply one concise `goal` and `steps_json`, a JSON array made only of supported steps (`navigate`, `new_tab`, `activate_tab`, `close_tab`, `click`, `type`, `form`, `extract`, `upload`, `download`, `screenshot`). Do not use it to answer a normal current-facts question when web search results are enough.
    - `browser.open_profile`: Use when Sir wants to sign in to a private site for future Nexus browser work. It opens a separate persistent Nexus Chrome profile. Tell him to sign in there once and close that Nexus Chrome window before automated tasks; never claim that normal Chrome passwords or cookies can be imported.
    - `browser.import_chrome_profile`: Use only when Sir asks to import normal Chrome browser state. It imports bookmarks, history, and preferences after Chrome is closed; passwords, cookies, and Keychain sessions are intentionally not copied.
    - `chrome.*`: Use live Chrome only if Sir explicitly refers to an existing tab, asks to switch/open/close a live tab, or uses an existing Chrome tab for YouTube playback. Otherwise, browser work stays in the Nexus-managed browser.
    - `nex_cli_task`: For a request to build, create, implement, code, develop, refactor, scaffold, fix, test, run, validate, or generate software or another file-based artifact beyond a small requested snippet, use this tool. Send a precise standalone `prompt` preserving concrete requirements and relevant active-chat context, plus a short `title`. NexCLI owns implementation, permissions, streamed progress, and artifacts; do not pretend an implementation exists before it succeeds.
    - `nex_cli_set_workspace`: Use only when Sir explicitly asks to start, switch to, or resume a named coding folder. Pass a human-readable `name`, never a filesystem path. Otherwise, `nex_cli_task` continues in the current persistent app-managed workspace, including after restarts and after files were created.
    - `youtube_play_current`: Use with no arguments when Sir asks to play, show, or continue the YouTube or YouTube Music video in the active Google Chrome tab.
    - `youtube_search`: Use when Sir asks Nex to find a YouTube video. Send a descriptive standalone `query`; then inspect its candidates before the next step.
    - `youtube_play`: Use only after `youtube_search`, passing exactly one returned `video_id`. Never invent a video ID.
    - `youtube_fullscreen`: Use with no arguments only when a Nex YouTube player is already open and Sir asks to enlarge it, make it big, or full-screen it.

    **Web research versus browser action:** `web_search` discovers public facts and returns sources. It does not open a browser session, visit a URL, click, log in, fill forms, download files, or inspect a specified page. If Sir explicitly says “use Nexus browser,” “open this website,” “go to this URL,” or “inspect this page,” select `browser.visit_url` for one known URL, or `browser.run_task` for a multi-step interaction. Never substitute `web_search` for an explicit Nexus-browser request. Once a browser tool returns readable page text, answer Sir's original request directly from that evidence; never respond with only the site name, URL, or a generic claim that the page was opened. If he asks a factual question such as “what changed in Swift?” or “what is the weather tomorrow?”, select `web_search`, not browser tools. Use both only when one is needed to discover a URL or facts and the other is needed to act on the discovered result. Do not substitute `web_search` for YouTube playback.

    ## Durable Memory Policy

    `memory_propose` and `memory_forget` are policy-owned. Do not call either directly. Propose `memory_write` only for a durable, user-supported preference, correction, decision, workflow, or explicit remember/forget request. Use concise `append`, `update`, or `forget` content. Never propose temporary facts, speculation, unsupported assumptions, or sensitive information without an explicit request. Nexus validates, deduplicates, chooses the Obsidian file, and executes approved proposals.

    ## Direct Answers

    Use no tool for stable explanations, writing, brainstorming, math, small snippets, or details visible in the active conversation. Keep the original request and active conversation; tool outputs are evidence, not replacements.

    ## Never Fabricate

    Never invent memory results, web results, tool outputs, citations, URLs, personal facts, source IDs, video IDs, files, or completed work. If a tool fails or evidence cannot be found, say so briefly. Do not expose internal tool names, source IDs, raw tool JSON, or routing details in the user-facing answer unless Sir explicitly asks.

    Nexus executes tool calls in a separate planning turn. In a normal final answer, never emit `<tool_call>`, `<arg_key>`, `<arg_value>`, JSON tool payloads, or any other raw function-call markup. Use the actual result from the completed tool instead.

    Core rule: personal missing from active chat → `memory_search`; current facts/research → `web_search`; inspect one known URL in Nexus browser → `browser.visit_url`; complex browser interaction → `browser.run_task`; sign in to a private Nexus browser session → `browser.open_profile`; coding → `nex_cli_task`; explicit workspace change → `nex_cli_set_workspace`; current Chrome YouTube video → `youtube_play_current`; find/play YouTube → `youtube_search` then `youtube_play`; existing Nex YouTube playback enlargement → `youtube_fullscreen`; durable user-supported memory change → `memory_write`; mixed request → every required tool; known stable fact → answer directly.
    """

    static var completeSystemPrompt: String { conciseSystemPrompt }
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
    /// Inference can legitimately take a long time before emitting an answer,
    /// especially with native reasoning enabled. This is deliberately far
    /// beyond normal model work; user cancellation remains immediate.
    static let inferenceRequestTimeout: TimeInterval = 7 * 24 * 60 * 60

    private let session: URLSession
    private let fileManager: FileManager
    private let processLock = NSLock()
    private var managedServerProcess: Process?
    private var toolCapabilityCache: [String: Bool] = [:]
    private var thinkingCapabilityCache: [String: Bool] = [:]

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
        includeNexusSystemPrompt: Bool = true,
        onDelta: @escaping @Sendable (_ delta: String, _ accumulated: String) async -> Void
    ) async throws -> String {
        try await streamChat(
            model: model,
            messages: messages,
            temperature: temperature,
            maximumTokens: maximumTokens,
            includeThinking: false,
            includeNexusSystemPrompt: includeNexusSystemPrompt,
            onThinkingDelta: nil,
            onDelta: onDelta
        )
    }

    /// Requests Ollama's optional native reasoning stream. Kept separate from
    /// the established response overload so existing callers keep their ABI.
    func streamChat(
        model: String,
        messages: [NexusChatMessage],
        temperature: Double? = nil,
        maximumTokens: Int? = nil,
        includeThinking: Bool,
        includeNexusSystemPrompt: Bool = true,
        onThinkingDelta: (@Sendable (_ delta: String, _ accumulated: String) async -> Void)?,
        onDelta: @escaping @Sendable (_ delta: String, _ accumulated: String) async -> Void
    ) async throws -> String {
        try await ensureServerRunning()
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.inferenceRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OllamaChatRequest(
                model: model,
                messages: (includeNexusSystemPrompt ? [.init(role: "system", content: NexusResponseInstructions.completeSystemPrompt)] : [])
                    + messages.map { .init(role: $0.role, content: $0.content) },
                stream: true,
                // `nil` lets thinking-capable models choose their own default.
                // The notch control is an explicit user preference, so always
                // send false when it is off rather than relying on that default.
                think: includeThinking,
                options: .init(temperature: temperature, numPredict: maximumTokens)
            )
        )
        let (bytes, response) = try await session.bytes(for: request)
        try Self.requireSuccess(response)
        let isToolPlanningPass = messages.contains {
            $0.role == "system" && $0.content.contains("NEXUS_TOOL_PLANNING_PASS")
        }
        var accumulated = ""
        var accumulatedThinking = ""
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
            if let thinking = event.message?.thinking, !thinking.isEmpty {
                accumulatedThinking += thinking
                await onThinkingDelta?(thinking, accumulatedThinking)
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
        request.timeoutInterval = Self.inferenceRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OllamaToolPlanningRequest(
                model: model,
                messages: [.init(role: "system", content: NexusResponseInstructions.completeSystemPrompt)]
                    + messages.map { .init(role: $0.role, content: $0.content) },
                stream: true,
                think: false,
                // Native calls can include model-internal reasoning before the
                // compact function arguments.  A small cap can therefore cut
                // off otherwise-valid JSON (for example halfway through a
                // web-search query), which makes the whole turn fail.  This is
                // planning only, but it must have enough room to finish one
                // complete call; the planner still returns as soon as Ollama
                // finishes the tool response.
                options: .init(temperature: 0, numPredict: 512),
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

    func supportsThinking(model: String) async -> Bool {
        if let cached = thinkingCapabilityCache[model] { return cached }
        let capabilities = await modelCapabilities(model: model)
        let supported = capabilities.contains("thinking")
        thinkingCapabilityCache[model] = supported
        return supported
    }

    private func modelCapabilities(model: String) async -> Set<String> {
        struct ShowRequest: Encodable { let model: String }
        struct ShowResponse: Decodable { let capabilities: [String]? }
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(ShowRequest(model: model))
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(ShowResponse.self, from: data) else {
            return []
        }
        return Set(decoded.capabilities ?? [])
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
    let think: Bool
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
        let thinking: String?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case thinking
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
        includeNexusSystemPrompt: Bool = true,
        onDelta: @escaping @Sendable (_ delta: String, _ accumulated: String) async -> Void
    ) async throws -> String {
        try await ensureServerRunning()
        let resolvedModel = await resolvedModelIdentifier(preferred: model)
        var request = URLRequest(url: Self.serverURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = OllamaManager.inferenceRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OpenAIChatRequest(
                model: resolvedModel,
                messages: (includeNexusSystemPrompt ? [.init(role: "system", content: NexusResponseInstructions.completeSystemPrompt)] : [])
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
