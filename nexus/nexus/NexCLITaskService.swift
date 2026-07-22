import Foundation
import Combine

struct NexCLITaskRecord: Identifiable, Equatable, Sendable {
    enum State: String, Sendable { case queued, running, awaitingPermission, completed, failed, cancelled }

    let id: String
    var title: String
    var status: String
    var detail: String
    var state: State
    var finalText: String = ""
    var outputURL: URL?
    var updatedAt = Date()
}

@MainActor
final class NexCLITaskController: ObservableObject {
    static let shared = NexCLITaskController()

    @Published private(set) var tasks: [NexCLITaskRecord] = []

    func receive(_ record: NexCLITaskRecord) {
        if let index = tasks.firstIndex(where: { $0.id == record.id }) {
            tasks[index] = record
        } else {
            tasks.insert(record, at: 0)
        }
    }
}

private actor NexCLITaskRecordStore {
    private var record: NexCLITaskRecord

    init(_ record: NexCLITaskRecord) { self.record = record }

    func apply(_ event: NexApiClient.Event) -> NexCLITaskRecord {
        record.status = event.message
        let toolLabel = event.tool.map { $0.title ?? $0.name }
        if event.kind == .textDelta, let delta = event.data["delta"]?.stringValue {
            record.finalText += delta
            record.detail = "NEX > \(record.finalText.suffix(180))"
        } else {
            record.detail = toolLabel.map { "NEX > \($0)" } ?? "NEX > \(event.message)"
        }
        record.state = switch event.status {
        case "awaiting_permission": .awaitingPermission
        case "completed": .completed
        case "failed": .failed
        case "cancelled": .cancelled
        default: .running
        }
        record.updatedAt = Date()
        return record
    }

    func current() -> NexCLITaskRecord { record }
}

/// Configuration is deliberately app-owned. A model is never allowed to
/// select a filesystem path, task server, or credential.
@MainActor
final class NexCLITaskSettings: ObservableObject {
    static let shared = NexCLITaskSettings()

    @Published var baseURL: String { didSet { persist() } }
    @Published var directory: String { didSet { persist() } }
    @Published var username: String { didSet { persist() } }
    @Published var usesManagedLocalService: Bool { didSet { persist() } }
    @Published var passwordInput = ""
    @Published private(set) var hasPassword: Bool

    private let defaults = UserDefaults.standard
    private let settingsKey = "nexus.nex-cli.settings.v1"
    private let passwordAccount = "task-gateway-password.v1"
    private let secrets = NexusKeychainSecretStore(service: "na.nexus.nex-cli")

    init() {
        let saved = defaults.dictionary(forKey: settingsKey) ?? [:]
        baseURL = saved["baseURL"] as? String ?? "http://127.0.0.1:4096"
        username = saved["username"] as? String ?? "opencode"
        let isManaged = saved["usesManagedLocalService"] as? Bool ?? true
        usesManagedLocalService = isManaged
        directory = saved["directory"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path
        if isManaged, let workspace = try? NexCLIWorkspaceManager.shared.currentWorkspace() {
            directory = workspace.url.path
        }
        hasPassword = isManaged || (saved["hasPassword"] as? Bool ?? false)
    }

    func save() throws {
        if usesManagedLocalService {
            directory = try NexCLIWorkspaceManager.shared.currentWorkspace().url.path
            try NexCLIHostManager.shared.installAndStart()
            persist()
            return
        }
        guard URL(string: normalizedBaseURL()) != nil else {
            throw LocalModelError.invalidResponse("Enter a valid Nex CLI server URL")
        }
        guard directory.hasPrefix("/") else {
            throw LocalModelError.invalidResponse("Choose an absolute Nex CLI workspace folder")
        }
        if !passwordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try secrets.set(Data(passwordInput.utf8), for: passwordAccount)
            passwordInput = ""
            hasPassword = true
        }
        persist()
    }

    fileprivate func configuration() throws -> NexCLITaskConfiguration {
        if usesManagedLocalService {
            directory = try NexCLIWorkspaceManager.shared.currentWorkspace().url.path
        }
        guard directory.hasPrefix("/") else {
            throw LocalModelError.invalidResponse("Choose an absolute Nex CLI workspace folder")
        }
        if usesManagedLocalService {
            return .init(
                baseURL: URL(string: "http://127.0.0.1:4096")!,
                directory: directory,
                username: "opencode",
                password: try NexCLILoopbackCredential.loadOrCreate(),
                model: .localCodingDefault
            )
        }
        guard let baseURL = URL(string: normalizedBaseURL()) else {
            throw LocalModelError.invalidResponse("Nex CLI server URL is invalid")
        }
        guard directory.hasPrefix("/") else {
            throw LocalModelError.invalidResponse("Nex CLI workspace must be an absolute path")
        }
        let password: String?
        if let data = try secrets.data(for: passwordAccount), let value = String(data: data, encoding: .utf8), !value.isEmpty {
            password = value
        } else {
            password = nil
        }
        return .init(baseURL: baseURL, directory: directory, username: username, password: password, model: .localCodingDefault)
    }

    private func normalizedBaseURL() -> String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func persist() {
        defaults.set([
            "baseURL": normalizedBaseURL(),
            "directory": directory.trimmingCharacters(in: .whitespacesAndNewlines),
            "username": username.trimmingCharacters(in: .whitespacesAndNewlines),
            "usesManagedLocalService": usesManagedLocalService,
            "hasPassword": hasPassword
        ], forKey: settingsKey)
    }

    func refreshManagedWorkspace() {
        guard usesManagedLocalService,
              let workspace = try? NexCLIWorkspaceManager.shared.currentWorkspace() else { return }
        directory = workspace.url.path
    }
}

private struct NexCLITaskConfiguration: Sendable {
    let baseURL: URL
    let directory: String
    let username: String
    let password: String?
    let model: NexApiClient.Model
}

/// Client for the Nex task gateway. It deliberately has no shell fallback:
/// if the local/remote Nex worker is unavailable, callers get a clear error
/// instead of Nexus quietly running arbitrary local commands.
actor NexCLITaskService {
    static let shared = NexCLITaskService()

    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func register(in registry: NexToolRegistry) async throws {
        try await registry.register(.init(
            name: "nex_cli_task",
            description: "Delegate any requested code, app, website, file-based build, code modification, run, test, or validation to NexCLI in Nexus's app-owned workspace. Use this instead of writing code in chat whenever the user wants an implementation or artifact. The task runs under Nex's own permission prompts; do not use it for explanations, brainstorming, or prose-only rewriting.",
            statusLabel: "Starting Nex CLI…",
            completionLabel: "Nex CLI task completed",
            spokenStatus: "Starting the coding task.",
            iconSystemName: "terminal",
            permission: .codeExecution,
            schema: .init(fields: [
                "prompt": .init(.string, required: true, description: "Standalone implementation brief for the coding agent."),
                "title": .init(.string, description: "Short human-readable task title.")
            ]),
            application: "NexCLI",
            provider: "Nex local coding agent",
            examples: ["Build a playable Snake game", "Fix and test this app", "Create a website from these requirements"],
            aliases: ["code this", "build an app", "implement this", "fix the code", "coding agent"],
            tags: ["code", "build", "implement", "debug", "test", "files", "app", "website"],
            supportedWorkflows: ["software implementation", "code modification", "test and validation", "file-based artifact creation"]
        ) { arguments, context in
            guard let prompt = arguments["prompt"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
                throw NexToolError.missingField("prompt")
            }
            let title = arguments["title"]?.string
            return try await Self.shared.run(prompt: prompt, title: title, context: context)
        })
        try await registry.register(.init(
            name: "nex_cli_set_workspace",
            description: "Change NexCLI's persistent, app-managed coding workspace only when the user explicitly asks to start, switch to, or resume a named coding folder. The app converts the requested name into a safe folder under the Nex vault; never use this to choose an arbitrary filesystem path.",
            statusLabel: "Switching coding workspace…",
            completionLabel: "Coding workspace ready",
            spokenStatus: "Switching the coding workspace.",
            iconSystemName: "folder",
            permission: .codeExecution,
            schema: .init(fields: [
                "name": .init(.string, required: true, description: "Human-readable managed workspace name, never an arbitrary path.")
            ]),
            application: "NexCLI",
            provider: "Nex local coding agent",
            examples: ["Switch to the Atlas project folder", "Start a new coding workspace named Portfolio"],
            aliases: ["switch coding folder", "change workspace", "resume project folder"],
            tags: ["workspace", "folder", "project", "code"],
            supportedWorkflows: ["explicit managed workspace switching"]
        ) { arguments, _ in
            guard let name = arguments["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw NexToolError.missingField("name")
            }
            let workspace = try await MainActor.run {
                let workspace = try NexCLIWorkspaceManager.shared.setWorkspace(named: name)
                NexCLITaskSettings.shared.refreshManagedWorkspace()
                return workspace
            }
            return .object([
                "workspace_folder": .string(workspace.url.path),
                "workspace_name": .string(workspace.displayName),
                "status": .string("active")
            ])
        })
    }

    /// Native-console entry point. It uses the exact managed `/nex/tasks`
    /// worker and SSE stream used by Nexus tool calls, rather than spawning a
    /// second shell or scraping an external terminal window.
    func runFromConsole(prompt: String) async throws {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { return }
        let context = NexToolExecutionContext(executionID: UUID()) { _, _ in }
        _ = try await run(prompt: cleanPrompt, title: cleanPrompt, context: context)
    }

    private func run(prompt: String, title: String?, context: NexToolExecutionContext) async throws -> NexJSONValue {
        let configuration = try await MainActor.run { try NexCLITaskSettings.shared.configuration() }
        if configuration.baseURL.host == "127.0.0.1", configuration.baseURL.port == 4096 {
            try await NexCLIHostManager.shared.ensureReady()
        }
        let client = NexApiClient(
            baseURL: configuration.baseURL,
            username: configuration.username,
            password: configuration.password,
            session: session
        )
        let directory = URL(fileURLWithPath: configuration.directory)
        let accepted = try await client.create(.init(
            directory: directory,
            prompt: prompt,
            title: title,
            agent: "nex-local",
            model: configuration.model,
            idempotencyKey: context.executionID
        ))
        var record = NexCLITaskRecord(
            id: accepted.taskId,
            title: title ?? "Nex CLI task",
            status: "Starting…",
            detail: "NEX > \(title ?? "task")",
            state: .queued
        )
        await update(record)
        await context.reportProgress(record.detail, nil)
        let recordStore = NexCLITaskRecordStore(record)
        try await client.events(for: accepted, directory: directory) { event in
            let updated = await recordStore.apply(event)
            await self.update(updated)
            await context.reportProgress(updated.detail, event.status == "completed" ? 1 : nil)
        }
        let snapshot = try await client.result(for: accepted, directory: directory)
        record = await recordStore.current()
        // A failed gateway task may still contain a model-proposed filename in
        // its tool history.  Never seal or rename the active workspace unless
        // Nex reports a completed task; otherwise a retry would be forced into
        // a fresh folder even though no build actually succeeded.
        let completedWorkspace = try await MainActor.run {
            if snapshot.status == "completed" {
                return try NexCLIWorkspaceManager.shared.completeBuild(
                    title: title ?? prompt,
                    filesChanged: snapshot.filesChanged
                )
            }
            return try NexCLIWorkspaceManager.shared.currentWorkspace()
        }
        record.finalText = snapshot.finalText
        record.state = snapshot.status == "completed" ? .completed : (snapshot.status == "cancelled" ? .cancelled : .failed)
        record.status = record.state == .completed ? "Task completed" : (snapshot.error ?? "Task did not complete")
        record.detail = record.status
        record.outputURL = playableOutput(from: snapshot, workspaceURL: completedWorkspace.url)
        record.updatedAt = Date()
        await update(record)
        await context.reportProgress(record.status, 1)
        var result: [String: NexJSONValue] = [
            "task_id": .string(snapshot.taskId),
            "final_text": .string(snapshot.finalText),
            "files_changed": .array(snapshot.filesChanged.map(NexJSONValue.string)),
            "status": .string(snapshot.status),
            "workspace_folder": .string(completedWorkspace.url.path)
        ]
        if let outputURL = record.outputURL { result["output_url"] = .string(outputURL.absoluteString) }
        if let error = snapshot.error { result["error"] = .string(error) }
        return .object(result)
    }

    private func playableOutput(from snapshot: NexApiClient.Result, workspaceURL: URL) -> URL? {
        guard let file = snapshot.filesChanged.first(where: { $0.lowercased().hasSuffix("index.html") }) else { return nil }
        let relative: String
        if file.hasPrefix(snapshot.directory + "/") {
            relative = String(file.dropFirst(snapshot.directory.count + 1))
        } else {
            relative = file.hasPrefix("/") ? URL(fileURLWithPath: file).lastPathComponent : file
        }
        return workspaceURL.appendingPathComponent(relative)
    }

    private func update(_ record: NexCLITaskRecord) async {
        await MainActor.run { NexCLITaskController.shared.receive(record) }
    }

}
