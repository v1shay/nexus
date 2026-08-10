import Foundation

/// Local same-user control plane for the *running* Nexus app. The CLI writes
/// requests only; the signed GUI process performs them on its own controller.
struct NexusHeadlessControlRequest: Codable, Sendable { let id: UUID; let command: String; let arguments: [String: String] }
struct NexusHeadlessControlReply: Codable, Sendable { let ok: Bool; let result: [String: String]; let error: String? }

enum NexusHeadlessControlCodec {
    static func jsonString<T: Encodable>(_ value: T) -> String {
        String(data: (try? JSONEncoder.cli.encode(value)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    /// The control plane carries one JSON object as a string because its
    /// request envelope intentionally contains only small string values.
    /// Decode it at the app boundary so a headless command uses the same
    /// strongly-typed computer runtime as the visible Nexus UI.
    static func toolArguments(json: String) -> [String: NexJSONValue]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return try? object.mapValues(nexJSON)
    }

    private static func nexJSON(_ value: Any) throws -> NexJSONValue {
        switch value {
        case let value as String:
            .string(value)
        case let value as NSNumber:
            CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [Any]:
            .array(try value.map(nexJSON))
        case let value as [String: Any]:
            .object(try value.mapValues(nexJSON))
        case is NSNull:
            .null
        default:
            throw CLIError.invalidJSON
        }
    }
}

enum NexusHeadlessControlPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nexus/HeadlessControl", isDirectory: true)
    static let requests = root.appendingPathComponent("requests", isDirectory: true)
    static let replies = root.appendingPathComponent("replies", isDirectory: true)
    static func prepare() throws {
        try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: replies, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

final class NexusHeadlessControlHost {
    private weak var controller: NotchController?
    private let controllerLock = NSLock()
    private var task: Task<Void, Never>?
    init() {}

    func attach(controller: NotchController) {
        controllerLock.lock()
        self.controller = controller
        controllerLock.unlock()
    }
    func start() {
        guard task == nil, (try? NexusHeadlessControlPaths.prepare()) != nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled { await self?.drain(); try? await Task.sleep(for: .milliseconds(120)) }
        }
    }
    func stop() { task?.cancel(); task = nil }

    private func currentController() -> NotchController? {
        controllerLock.lock()
        defer { controllerLock.unlock() }
        return controller
    }

    private func drain() async {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(at: NexusHeadlessControlPaths.requests, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url), let request = try? JSONDecoder().decode(NexusHeadlessControlRequest.self, from: data) else { try? manager.removeItem(at: url); continue }
            try? manager.removeItem(at: url)
            // A model request can legitimately take minutes.  Do not make it
            // block status, settings, or cancellation requests in the same
            // live control plane; the GUI remains the single executor.
            Task { [weak self] in
                let reply: NexusHeadlessControlReply
                if let controller = self?.currentController() {
                    reply = await controller.performHeadlessControl(request)
                } else {
                    reply = .init(ok: false, result: ["state": "starting"], error: "Nexus is starting.")
                }
                let destination = NexusHeadlessControlPaths.replies.appendingPathComponent("\(request.id.uuidString).json")
                if let data = try? JSONEncoder().encode(reply) { try? data.write(to: destination, options: .atomic) }
            }
        }
    }
}

enum NexusHeadlessControlClient {
    static func run(arguments: [String]) async -> Int32 {
        guard let command = arguments.first else { return fail("Usage: nexusctl <status|nexcli-status|prompt|cancel|models|model-select|permissions|permission-open|permission-repair|memory-status|memory-save|settings|settings-set|tools|tool-execute|tool-dry-run|tool-confirm|tool-cancel-confirmation|connect-enable|connect-role|connect-route>") }
        var values: [String: String] = [:]
        if ["prompt", "model-select", "permission-open", "connect-enable", "connect-role", "connect-route"].contains(command) {
            guard arguments.count > 1 else { return fail("Missing value for \(command).") }
            values[command == "prompt" ? "text" : "value"] = arguments.dropFirst().joined(separator: " ")
        }
        if command == "settings-set" {
            guard arguments.count == 3 else { return fail("Usage: nexusctl settings-set <key> <value>") }
            values["key"] = arguments[1]
            values["value"] = arguments[2]
        }
        if command == "tool-execute" || command == "tool-dry-run" {
            guard arguments.count == 4, arguments[2] == "--json" else {
                return fail("Usage: nexusctl \(command) <action> --json <object>")
            }
            values["action"] = arguments[1]
            values["json"] = arguments[3]
        }
        if command == "tool-confirm" || command == "tool-cancel-confirmation" {
            guard arguments.count == 2 else {
                return fail("Usage: nexusctl \(command) <pending-action-id>")
            }
            values["actionId"] = arguments[1]
        }
        do {
            try NexusHeadlessControlPaths.prepare()
            let request = NexusHeadlessControlRequest(id: UUID(), command: command, arguments: values)
            try JSONEncoder().encode(request).write(to: NexusHeadlessControlPaths.requests.appendingPathComponent("\(request.id.uuidString).json"), options: .atomic)
            let replyURL = NexusHeadlessControlPaths.replies.appendingPathComponent("\(request.id.uuidString).json")
            let polls = command == "prompt" ? 1_750 : 750
            for _ in 0..<polls {
                if let data = try? Data(contentsOf: replyURL), let reply = try? JSONDecoder().decode(NexusHeadlessControlReply.self, from: data) {
                    try? FileManager.default.removeItem(at: replyURL)
                    if !reply.ok, reply.error == "Nexus is starting." {
                        try await Task.sleep(for: .milliseconds(120))
                        continue
                    }
                    let output = (try? JSONEncoder().encode(reply)) ?? Data("{\"ok\":false}".utf8)
                    FileHandle.standardOutput.write(output); FileHandle.standardOutput.write(Data("\n".utf8))
                    return reply.ok ? 0 : 2
                }
                try await Task.sleep(for: .milliseconds(120))
            }
            return fail("No running Nexus control host replied. Run ./scripts/build-nexus.sh --run first.")
        } catch { return fail(error.localizedDescription) }
    }
    private static func fail(_ message: String) -> Int32 { print("{\"ok\":false,\"error\":\"\(message.replacingOccurrences(of: "\\\"", with: "'"))\"}"); return 2 }
}

struct NexComputerCLIEnvironment: Sendable {
    let tools: NexToolRegistry
    let registry: NexComputerRegistry
    let runtime: NexComputerRuntime
    let search: NexToolSearchService
    let connectors: NexConnectorManager

    static func live() async throws -> Self {
        let tools = NexToolRegistry()
        let registry = NexComputerRegistry(toolRegistry: tools)
        let connectors = NexConnectorManager()
        try await NexTerminalActionCatalog().register(on: registry)
        try await NexFinderActionCatalog().register(on: registry)
        try await NexSpotifyActionCatalog().register(on: registry)
        try await NexMessagesActionCatalog().register(on: registry)
        try await NexPhotosActionCatalog().register(on: registry)
        try await NexVSCodeActionCatalog().register(on: registry)
        try await NexCodexActionCatalog().register(on: registry)
        try await NexObsidianActionCatalog().register(on: registry)
        try await NexGitHubActionCatalog().register(on: registry)
        try await NexSystemActionCatalog().register(on: registry)
        try await NexXcodeActionCatalog().register(on: registry)
        try await NexPreviewActionCatalog().register(on: registry)
        try await NexApplicationActionCatalog().register(on: registry)
        try await NexBrowserActionCatalog().register(on: registry)
        try await NexChromeTabActionCatalog().register(on: registry)
        // The notch registers these media tools at startup. Include them in
        // the CLI audit environment as well so semantic routing diagnostics
        // exercise the same public capability surface as the running app.
        let youtube = await MainActor.run {
            NexYouTubeToolController(registry: tools) { _, _ in false }
        }
        try await youtube.registerIfNeeded()
        // This standalone process must not read the login Keychain while it
        // is merely listing, planning, or dry-running tools. A stale ACL can
        // otherwise make every headless command hang before it produces a
        // structured permission result. Account-bound execution is routed
        // through the running app's authenticated connector flow.
        try await connectors.registerDisconnectedCapabilities(on: registry)
        let search = NexToolSearchService(registry: tools, computerRegistry: registry)
        try await search.registerIfNeeded()
        return .init(tools: tools, registry: registry, runtime: NexComputerRuntime(registry: registry), search: search, connectors: connectors)
    }
}

enum NexComputerCLI {
    static func run(arguments: [String], environment: NexComputerCLIEnvironment? = nil) async -> Int32 {
        do {
            let env: NexComputerCLIEnvironment
            if let environment { env = environment } else { env = try await .live() }
            guard let command = arguments.first else { throw CLIError.usage }
            let output: Any
            switch command {
            case "discover":
                let availability = await env.registry.availabilitySnapshot()
                let manifests = await env.registry.manifests()
                let extraTools = await additionalRegisteredTools(in: env, manifests: manifests)
                output = manifests.map { manifest in
                    Self.manifestJSON(manifest, availability: availability[manifest.actionID])
                } + extraTools.map { tool in
                    Self.registeredToolJSON(tool, availability: registeredToolAvailability(tool))
                }
            case "apps":
                output = Self.foundationJSON(await env.runtime.execute(actionID: "applications.list", arguments: [:]).data)
            case "tools":
                let manifests = await env.registry.manifests()
                let extraTools = await additionalRegisteredTools(in: env, manifests: manifests)
                output = (manifests.map { Self.manifestJSON($0) } + extraTools.map { Self.registeredToolJSON($0) })
                    .sorted { ($0["action"] as? String ?? "") < ($1["action"] as? String ?? "") }
            case "search":
                guard arguments.count >= 2 else { throw CLIError.missing("query") }
                output = try Self.object(try JSONEncoder.cli.encode(await env.search.search(query: arguments.dropFirst().joined(separator: " "), availabilityPolicy: .includeUnavailable)))
            case "plan":
                let rawArguments = Array(arguments.dropFirst())
                let prompt = rawArguments.prefix { $0 != "--model" }.joined(separator: " ")
                guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CLIError.missing("query") }
                let model = Self.value(after: "--model", in: rawArguments) ?? "gpt-oss:latest"
                output = try await plan(prompt: prompt, model: model, environment: env)
            case "audit-discovery":
                output = try await discoveryAudit(environment: env)
            case "audit-plan":
                let auditArguments = Array(arguments.dropFirst())
                let model = Self.value(after: "--model", in: auditArguments) ?? "gpt-oss:latest"
                let offset = Self.integer(after: "--offset", in: auditArguments) ?? 0
                let limit = Self.integer(after: "--limit", in: auditArguments)
                output = try await modelPlanAudit(model: model, offset: offset, limit: limit, environment: env)
            case "describe":
                guard let action = arguments.dropFirst().first else { throw CLIError.missing("action") }
                if await env.registry.contains(actionID: action) {
                    output = Self.manifestJSON(try await env.registry.manifest(actionID: action))
                } else if let tool = await env.tools.definitions().first(where: { $0.name == action }) {
                    output = Self.registeredToolJSON(tool, availability: registeredToolAvailability(tool))
                } else {
                    throw NexToolError.notFound(action)
                }
            case "execute", "dry-run":
                guard let action = arguments.dropFirst().first else { throw CLIError.missing("action") }
                let json = Self.value(after: "--json", in: arguments) ?? "{}"
                guard let data = json.data(using: .utf8), let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError.invalidJSON }
                let args = try raw.mapValues(Self.nexJSON)
                let envelope: NexComputerResultEnvelope
                if await env.registry.contains(actionID: action) {
                    envelope = await env.runtime.execute(
                        actionID: action,
                        arguments: args,
                        options: .init(dryRun: command == "dry-run", invocation: .app)
                    )
                } else {
                    envelope = await executeRegisteredTool(
                        action: action,
                        arguments: args,
                        dryRun: command == "dry-run",
                        tools: env.tools
                    )
                }
                output = try Self.object(JSONEncoder.cli.encode(envelope))
            case "permissions":
                let manifests = await env.registry.manifests()
                output = manifests.flatMap { manifest in manifest.requiredPermissions.map { ["action": manifest.actionID, "permission": $0.id, "recovery": $0.recovery ?? ""] } }
            case "confirm", "cancel":
                guard let actionID = arguments.dropFirst().first else { throw CLIError.missing("action_id") }
                let tool = command == "confirm" ? "confirm_action" : "cancel_action"
                output = Self.foundationJSON(try await env.tools.execute(name: tool, arguments: ["actionId": .string(actionID)], invocation: .app))
            case "connectors":
                output = try await connectorCommand(Array(arguments.dropFirst()))
            case "doctor":
                output = await doctor(env)
            default: throw CLIError.unknown(command)
            }
            printJSON(output)
            return 0
        } catch {
            printJSON(["ok": false, "error": error.localizedDescription])
            return 2
        }
    }

    private static func connectorCommand(_ arguments: [String]) async throws -> Any {
        let management = NexConnectorManagementService()
        let command = arguments.first ?? "status"
        switch command {
        case "status", "list": return try management.status().map(Self.connectorJSON)
        case "doctor": return try management.doctor()
        case "disconnect":
            guard arguments.count > 1, let provider = NexConnectorProvider(rawValue: arguments[1].lowercased()) else { throw CLIError.missing("provider") }
            try management.disconnect(provider); return ["ok": true, "provider": provider.rawValue, "status": "disconnected"]
        case "connect":
            guard arguments.count > 1, let provider = NexConnectorProvider(rawValue: arguments[1].lowercased()) else { throw CLIError.missing("provider") }
            await MainActor.run { NexConnectorAuthController.shared.connectWithEnabledScopes(provider) }
            return ["ok": true, "provider": provider.rawValue, "status": "authorization_opened"]
        default: throw CLIError.unknown("connectors \(command)")
        }
    }

    /// Exercises the exact native-function planning path used by the notch,
    /// while keeping the action itself unexecuted. This makes model-routing
    /// regressions inspectable without touching Messages, browser state, or
    /// any other user data.
    private static func plan(
        prompt: String,
        model: String,
        environment: NexComputerCLIEnvironment
    ) async throws -> Any {
        let discovery = await environment.search.search(query: prompt)
        var definitions = await environment.search.definitions(for: discovery)
        let allDefinitions = await environment.tools.definitions()
        if let searchTool = allDefinitions.first(where: { $0.name == NexToolSearchService.actionName }) {
            definitions.append(searchTool)
        }
        definitions.sort { $0.name < $1.name }
        let messages = NexPrimaryToolPlanner.planningMessages(
            context: [.init(role: "user", content: prompt)],
            tools: definitions
        )
        let planned = try await OllamaManager().planTools(
            model: model,
            messages: messages,
            registeredTools: definitions
        )
        let result = NexPrimaryToolPlanner.groundingActions(
            in: planned,
            userPrompt: prompt,
            registeredTools: definitions
        )
        return [
            "model": model,
            "query": prompt,
            "discovery": try object(JSONEncoder.cli.encode(discovery)),
            "plan": try object(JSONEncoder.cli.encode(result))
        ]
    }

    /// Checks the complete registered surface against the natural-language
    /// examples that ship with each tool. This is intentionally read-only:
    /// it proves discovery and the model's available-action boundary without
    /// reading Messages, changing files, or contacting a connector.
    private static func discoveryAudit(environment: NexComputerCLIEnvironment) async throws -> Any {
        // `search_tools` deliberately never returns itself: it is the
        // discovery mechanism, not a candidate capability. Exclude that
        // meta-tool from the self-discovery invariant.
        let definitions = await environment.tools.definitions()
            .filter { $0.name != NexToolSearchService.actionName }
        var results: [[String: Any]] = []
        for definition in definitions.sorted(by: { $0.name < $1.name }) {
            guard let prompt = definition.examples.first,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                results.append([
                    "tool": definition.name,
                    "prompt": "",
                    "discovered": false,
                    "candidates": [],
                    "reason": "No natural-language example is registered."
                ])
                continue
            }
            let discovery = await environment.search.search(
                query: prompt,
                availabilityPolicy: .includeUnavailable
            )
            let candidates = discovery.candidates.map(\.tool)
            results.append([
                "tool": definition.name,
                "prompt": prompt,
                "discovered": candidates.contains(definition.name),
                "candidates": candidates
            ])
        }
        let passed = results.filter { $0["discovered"] as? Bool == true }.count
        return [
            "tools": results.count,
            "passed": passed,
            "failed": results.count - passed,
            "results": results
        ]
    }

    /// Runs the same native-function planning pass used by Nexus for every
    /// registered tool example, without executing any tool. The result
    /// distinguishes a direct selection from a legitimate discovery-first or
    /// missing-argument outcome, rather than treating an empty plan as a
    /// silent success.
    private static func modelPlanAudit(
        model: String,
        offset: Int,
        limit: Int?,
        environment: NexComputerCLIEnvironment
    ) async throws -> Any {
        let allDefinitions = await environment.tools.definitions()
        let definitions = allDefinitions
            .filter { $0.name != NexToolSearchService.actionName }
            .sorted { $0.name < $1.name }
        let safeOffset = max(0, offset)
        let remaining = definitions.dropFirst(safeOffset)
        let auditedDefinitions = limit.map { Array(remaining.prefix(max(0, $0))) } ?? Array(remaining)
        var results: [[String: Any]] = []

        for expected in auditedDefinitions {
            guard let prompt = expected.examples.first,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                results.append([
                    "tool": expected.name,
                    "prompt": "",
                    "outcome": "no_example",
                    "selected": [],
                    "latency_ms": 0
                ])
                continue
            }
            // This audit measures the full model-routing path—not only the
            // Ollama request—so it includes semantic discovery and argument
            // grounding as experienced by a real Nexus prompt.
            let startedAt = Date()
            let discovery = await environment.search.search(query: prompt)
            var allowed = await environment.search.definitions(for: discovery)
            if let searchTool = allDefinitions.first(where: { $0.name == NexToolSearchService.actionName }) {
                allowed.append(searchTool)
            }
            allowed.sort { $0.name < $1.name }
            do {
                let planned = try await OllamaManager().planTools(
                    model: model,
                    messages: NexPrimaryToolPlanner.planningMessages(
                        context: [.init(role: "user", content: prompt)],
                        tools: allowed
                    ),
                    registeredTools: allowed
                )
                let selected = NexPrimaryToolPlanner.groundingActions(
                    in: planned,
                    userPrompt: prompt,
                    registeredTools: allowed
                ).actions.map(\.tool)
                let outcome: String
                if selected.contains(expected.name) { outcome = "selected" }
                else if selected.contains(NexToolSearchService.actionName) { outcome = "needs_second_pass" }
                else if selected.isEmpty { outcome = "no_action" }
                else { outcome = "other_action" }
                results.append([
                    "tool": expected.name,
                    "prompt": prompt,
                    "outcome": outcome,
                    "selected": selected,
                    "discovered": discovery.candidates.map(\.tool),
                    "latency_ms": Int(Date().timeIntervalSince(startedAt) * 1_000)
                ])
            } catch {
                results.append([
                    "tool": expected.name,
                    "prompt": prompt,
                    "outcome": "planning_error",
                    "selected": [],
                    "error": error.localizedDescription,
                    "latency_ms": Int(Date().timeIntervalSince(startedAt) * 1_000)
                ])
            }
        }

        let counts = Dictionary(grouping: results, by: { $0["outcome"] as? String ?? "unknown" })
            .mapValues(\.count)
        return [
            "model": model,
            "total_tools": definitions.count,
            "offset": safeOffset,
            "tools": results.count,
            "outcomes": counts,
            "results": results
        ]
    }

    private static func doctor(_ env: NexComputerCLIEnvironment) async -> [String: Any] {
        let manifests = await env.registry.manifests(), availability = await env.registry.availabilitySnapshot()
        let extraTools = await additionalRegisteredTools(in: env, manifests: manifests)
        let extraAvailability = extraTools.map { registeredToolAvailability($0) }
        let permissions = Set(manifests.flatMap { $0.requiredPermissions.map(\.id) })
        let previews = Set(manifests.map(\.previewRenderer))
        let connectorStatus = await env.connectors.allDocuments()
            .map { document in
                let state = document.connected ? "connected" : "not connected"
                return "\(document.provider.capitalized): \(state)"
            }
            .sorted()
        let browserRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Nexus/Browser")
        return [
            "ok": true,
            "tools": manifests.count + extraTools.count,
            "available_tools": availability.values.filter(\.isAvailable).count + extraAvailability.filter(\.isAvailable).count,
            "headless_unavailable_tools": extraTools.enumerated().compactMap { index, tool in
                let state = extraAvailability[index]
                return state.isAvailable ? nil : ["action": tool.name, "reason": state.reason ?? "Unavailable.", "recovery": state.recovery ?? ""]
            },
            "permissions_declared": permissions.sorted(), "preview_renderers": previews.sorted(),
            "browser_profile": browserRoot.map { FileManager.default.fileExists(atPath: $0.path) ? "ready" : "not provisioned (created lazily after confirmation)" } ?? "unavailable",
            "connectors": connectorStatus,
            "safety": "Read-only diagnostics only; no messages, files, calls, pushes, purchases, or personal data were changed."
        ]
    }

    private static func manifestJSON(_ manifest: NexComputerActionManifest, availability: NexComputerAvailability? = nil) -> [String: Any] {
        var value: [String: Any] = [
            "action": manifest.actionID,
            "application": manifest.application,
            "provider": manifest.provider,
            "description": manifest.description,
            "examples": manifest.examples,
            "input_schema": (try? object(JSONEncoder.cli.encode(manifest.inputSchema))) ?? [:],
            "required_permissions": manifest.requiredPermissions.map {
                ["id": $0.id, "permission": $0.permission.rawValue, "recovery": $0.recovery ?? ""]
            },
            "risk": manifest.riskClass.rawValue,
            "confirmation": manifest.confirmationPolicy.rawValue,
            "implementation": manifest.implementationMethod.rawValue,
            "preview": manifest.previewRenderer
        ]
        if let availability { value["available"] = availability.isAvailable; value["unavailable_reason"] = availability.reason ?? "" }
        return value
    }

    /// The conversational registry also owns a few non-computer actions,
    /// notably public YouTube discovery and `search_tools`. The headless CLI
    /// must list and execute the same registry the planner sees; otherwise it
    /// would advertise a valid model action and reject it as unknown.
    private static func additionalRegisteredTools(
        in environment: NexComputerCLIEnvironment,
        manifests: [NexComputerActionManifest]
    ) async -> [NexRegisteredTool] {
        let computerActions = Set(manifests.map(\.actionID))
        return await environment.tools.definitions().filter { !computerActions.contains($0.name) }
    }

    private static func registeredToolAvailability(_ tool: NexRegisteredTool) -> NexComputerAvailability {
        switch tool.name {
        case "youtube_play", "youtube_play_current", "youtube_fullscreen":
            return .unavailable(
                "Headless Nexus has no media-overlay host.",
                recovery: "Use the Nexus app to present or control YouTube playback."
            )
        default:
            return .available
        }
    }

    private static func registeredToolJSON(
        _ tool: NexRegisteredTool,
        availability: NexComputerAvailability? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "action": tool.name,
            "application": tool.application,
            "provider": tool.provider,
            "description": tool.description,
            "examples": tool.examples,
            "input_schema": (try? object(JSONEncoder.cli.encode(tool.schema))) ?? [:],
            "tool_permission": tool.permission.rawValue,
            "risk": "managed_by_tool",
            "confirmation": "managed_by_tool",
            "implementation": "tool_registry",
            "preview": ""
        ]
        if let availability {
            value["available"] = availability.isAvailable
            value["unavailable_reason"] = availability.reason ?? ""
        }
        return value
    }

    private static func executeRegisteredTool(
        action: String,
        arguments: [String: NexJSONValue],
        dryRun: Bool,
        tools: NexToolRegistry
    ) async -> NexComputerResultEnvelope {
        let startedAt = Date()
        let executionID = UUID()
        guard let tool = await tools.definitions().first(where: { $0.name == action }) else {
            return registeredToolFailure(
                action: action,
                executionID: executionID,
                startedAt: startedAt,
                code: "TOOL_NOT_FOUND",
                message: "Unknown tool: \(action)."
            )
        }
        let availability = registeredToolAvailability(tool)
        guard availability.isAvailable else {
            return registeredToolFailure(
                action: action,
                executionID: executionID,
                startedAt: startedAt,
                code: "UNAVAILABLE",
                message: availability.reason ?? "Action is unavailable.",
                recovery: availability.recovery,
                status: .unavailable
            )
        }
        guard !dryRun else {
            return registeredToolFailure(
                action: action,
                executionID: executionID,
                startedAt: startedAt,
                code: "DRY_RUN_UNSUPPORTED",
                message: "\(action) does not declare a standalone dry-run contract."
            )
        }
        do {
            let result = try await tools.execute(name: action, arguments: arguments, invocation: .app)
            return .init(
                schemaVersion: NexComputerResultEnvelope.currentSchemaVersion,
                executionID: executionID,
                ok: true,
                action: action,
                status: .completed,
                data: result,
                display: result.object?["display"]?.string ?? tool.completionLabel,
                warnings: [],
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                error: nil
            )
        } catch {
            let actionFailure = error as? NexComputerActionFailure
            let toolError = error as? NexToolError
            return registeredToolFailure(
                action: action,
                executionID: executionID,
                startedAt: startedAt,
                code: actionFailure?.code ?? toolError?.code ?? "EXECUTION_FAILED",
                message: actionFailure?.message ?? error.localizedDescription,
                permission: actionFailure?.permission,
                recovery: actionFailure?.recovery,
                retryable: actionFailure?.retryable ?? false
            )
        }
    }

    private static func registeredToolFailure(
        action: String,
        executionID: UUID,
        startedAt: Date,
        code: String,
        message: String,
        permission: String? = nil,
        recovery: String? = nil,
        retryable: Bool = false,
        status: NexComputerExecutionStatus = .failed
    ) -> NexComputerResultEnvelope {
        .init(
            schemaVersion: NexComputerResultEnvelope.currentSchemaVersion,
            executionID: executionID,
            ok: false,
            action: action,
            status: status,
            data: .object([:]),
            display: message,
            warnings: [],
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
            error: .init(code: code, message: message, permission: permission, recovery: recovery, retryable: retryable)
        )
    }
    private static func connectorJSON(_ status: NexConnectorPublicStatus) -> [String: Any] { ["provider": status.id.rawValue, "connected": status.connected, "healthy": status.healthy, "account": status.account ?? "", "scopes": status.scopes, "detail": status.detail] }
    private static func value(after option: String, in arguments: [String]) -> String? { guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }; return arguments[index + 1] }
    private static func integer(after option: String, in arguments: [String]) -> Int? {
        guard let value = value(after: option, in: arguments) else { return nil }
        return Int(value)
    }
    private static func object(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data) }
    private static func foundationJSON(_ value: NexJSONValue) -> Any { (try? object(JSONEncoder.cli.encode(value))) ?? NSNull() }
    private static func nexJSON(_ value: Any) throws -> NexJSONValue {
        switch value {
        case let value as String:
            .string(value)
        case let value as NSNumber:
            CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [Any]:
            .array(try value.map(nexJSON))
        case let value as [String: Any]:
            .object(try value.mapValues(nexJSON))
        case is NSNull:
            .null
        default:
            throw CLIError.invalidJSON
        }
    }
    private static func printJSON(_ value: Any) { guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { print("{\"ok\":false,\"error\":\"output encoding failed\"}"); return }; print(text) }
}

private enum CLIError: LocalizedError {
    case usage, missing(String), invalidJSON, unknown(String)
    var errorDescription: String? { switch self { case .usage: "Usage: nex-computer <discover|apps|tools|search|plan|audit-discovery|audit-plan|describe|execute|dry-run|permissions|doctor|connectors>"; case .missing(let value): "Missing \(value)."; case .invalidJSON: "--json must contain one JSON object."; case .unknown(let value): "Unknown command: \(value)." } }
}
private extension JSONEncoder { static var cli: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder } }
