import Foundation

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
        try await connectors.reloadStoredConnections(registry: registry)
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
                output = await env.registry.manifests().map { manifest in Self.manifestJSON(manifest, availability: availability[manifest.actionID]) }
            case "apps":
                output = Self.foundationJSON(await env.runtime.execute(actionID: "applications.list", arguments: [:]).data)
            case "tools":
                output = await env.registry.manifests().map { Self.manifestJSON($0) }
            case "search":
                guard arguments.count >= 2 else { throw CLIError.missing("query") }
                output = try Self.object(try JSONEncoder.cli.encode(await env.search.search(query: arguments.dropFirst().joined(separator: " "), availabilityPolicy: .includeUnavailable)))
            case "describe":
                guard let action = arguments.dropFirst().first else { throw CLIError.missing("action") }
                output = Self.manifestJSON(try await env.registry.manifest(actionID: action))
            case "execute", "dry-run":
                guard let action = arguments.dropFirst().first else { throw CLIError.missing("action") }
                let json = Self.value(after: "--json", in: arguments) ?? "{}"
                guard let data = json.data(using: .utf8), let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CLIError.invalidJSON }
                let args = try raw.mapValues(Self.nexJSON)
                let envelope = await env.runtime.execute(actionID: action, arguments: args, options: .init(dryRun: command == "dry-run", invocation: .app))
                output = try Self.object(JSONEncoder.cli.encode(envelope))
            case "permissions":
                let manifests = await env.registry.manifests()
                output = manifests.flatMap { manifest in manifest.requiredPermissions.map { ["action": manifest.actionID, "permission": $0.id, "recovery": $0.recovery ?? ""] } }
            case "confirm", "cancel":
                guard let actionID = arguments.dropFirst().first else { throw CLIError.missing("action_id") }
                let tool = command == "confirm" ? "nex.confirm_action" : "nex.cancel_action"
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

    private static func doctor(_ env: NexComputerCLIEnvironment) async -> [String: Any] {
        let manifests = await env.registry.manifests(), availability = await env.registry.availabilitySnapshot()
        let permissions = Set(manifests.flatMap { $0.requiredPermissions.map(\.id) })
        let previews = Set(manifests.map(\.previewRenderer))
        let browserRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Nexus/Browser")
        return [
            "ok": true, "tools": manifests.count, "available_tools": availability.values.filter(\.isAvailable).count,
            "permissions_declared": permissions.sorted(), "preview_renderers": previews.sorted(),
            "browser_profile": browserRoot.map { FileManager.default.fileExists(atPath: $0.path) ? "ready" : "not provisioned (created lazily after confirmation)" } ?? "unavailable",
            "connectors": (try? NexConnectorManagementService().doctor()) ?? [],
            "safety": "Read-only diagnostics only; no messages, files, calls, pushes, purchases, or personal data were changed."
        ]
    }

    private static func manifestJSON(_ manifest: NexComputerActionManifest, availability: NexComputerAvailability? = nil) -> [String: Any] {
        var value: [String: Any] = ["action": manifest.actionID, "application": manifest.application, "provider": manifest.provider, "description": manifest.description, "risk": manifest.riskClass.rawValue, "confirmation": manifest.confirmationPolicy.rawValue, "implementation": manifest.implementationMethod.rawValue, "preview": manifest.previewRenderer]
        if let availability { value["available"] = availability.isAvailable; value["unavailable_reason"] = availability.reason ?? "" }
        return value
    }
    private static func connectorJSON(_ status: NexConnectorPublicStatus) -> [String: Any] { ["provider": status.id.rawValue, "connected": status.connected, "healthy": status.healthy, "account": status.account ?? "", "scopes": status.scopes, "detail": status.detail] }
    private static func value(after option: String, in arguments: [String]) -> String? { guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }; return arguments[index + 1] }
    private static func object(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data) }
    private static func foundationJSON(_ value: NexJSONValue) -> Any { (try? object(JSONEncoder.cli.encode(value))) ?? NSNull() }
    private static func nexJSON(_ value: Any) throws -> NexJSONValue { switch value { case let value as String: .string(value); case let value as Bool: .bool(value); case let value as NSNumber: .number(value.doubleValue); case let value as [Any]: .array(try value.map(nexJSON)); case let value as [String: Any]: .object(try value.mapValues(nexJSON)); case is NSNull: .null; default: throw CLIError.invalidJSON } }
    private static func printJSON(_ value: Any) { guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { print("{\"ok\":false,\"error\":\"output encoding failed\"}"); return }; print(text) }
}

private enum CLIError: LocalizedError {
    case usage, missing(String), invalidJSON, unknown(String)
    var errorDescription: String? { switch self { case .usage: "Usage: nex-computer <discover|apps|tools|search|describe|execute|dry-run|permissions|doctor|connectors>"; case .missing(let value): "Missing \(value)."; case .invalidJSON: "--json must contain one JSON object."; case .unknown(let value): "Unknown command: \(value)." } }
}
private extension JSONEncoder { static var cli: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder } }
