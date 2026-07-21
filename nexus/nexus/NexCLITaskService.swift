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

/// Configuration is deliberately app-owned. A model is never allowed to
/// select a filesystem path, task server, or credential.
@MainActor
final class NexCLITaskSettings: ObservableObject {
    static let shared = NexCLITaskSettings()

    @Published var baseURL: String { didSet { persist() } }
    @Published var directory: String { didSet { persist() } }
    @Published var username: String { didSet { persist() } }
    @Published var passwordInput = ""
    @Published private(set) var hasPassword: Bool

    private let defaults = UserDefaults.standard
    private let settingsKey = "nexus.nex-cli.settings.v1"
    private let passwordAccount = "task-gateway-password.v1"
    private let secrets = NexusKeychainSecretStore(service: "na.nexus.nex-cli")

    init() {
        let saved = defaults.dictionary(forKey: settingsKey) ?? [:]
        baseURL = saved["baseURL"] as? String ?? "http://127.0.0.1:4096"
        directory = saved["directory"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path
        username = saved["username"] as? String ?? "opencode"
        hasPassword = saved["hasPassword"] as? Bool ?? false
    }

    func save() throws {
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
        return .init(baseURL: baseURL, directory: directory, username: username, password: password)
    }

    private func normalizedBaseURL() -> String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func persist() {
        defaults.set([
            "baseURL": normalizedBaseURL(),
            "directory": directory.trimmingCharacters(in: .whitespacesAndNewlines),
            "username": username.trimmingCharacters(in: .whitespacesAndNewlines),
            "hasPassword": hasPassword
        ], forKey: settingsKey)
    }
}

private struct NexCLITaskConfiguration: Sendable {
    let baseURL: URL
    let directory: String
    let username: String
    let password: String?
}

private struct NexCLITaskAccepted: Decodable { let taskId: String; let streamUrl: String; let resultUrl: String }
private struct NexCLISnapshot: Decodable {
    let taskId: String
    let status: String
    let finalText: String
    let directory: String
    let filesChanged: [String]
    let error: String?
}
private struct NexCLIEvent: Decodable {
    struct Tool: Decodable { let name: String; let title: String?; let state: String }
    let taskId: String
    let type: String
    let status: String
    let message: String
    let tool: Tool?
    let data: [String: JSONValue]?
}

private enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }
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
            description: "Delegate a multi-file coding or app-building task to the configured Nex CLI workspace. Use when the user asks Nex to actually create, edit, run, or validate a project. The task runs under Nex's own permission prompts; do not use for an explanation or a small code snippet.",
            statusLabel: "Starting Nex CLI…",
            completionLabel: "Nex CLI task completed",
            spokenStatus: "Starting the coding task.",
            iconSystemName: "terminal",
            permission: .codeExecution,
            schema: .init(fields: [
                "prompt": .init(.string, required: true),
                "title": .init(.string)
            ])
        ) { arguments, context in
            guard let prompt = arguments["prompt"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
                throw NexToolError.missingField("prompt")
            }
            let title = arguments["title"]?.string
            return try await Self.shared.run(prompt: prompt, title: title, context: context)
        })
    }

    private func run(prompt: String, title: String?, context: NexToolExecutionContext) async throws -> NexJSONValue {
        let configuration = try await MainActor.run { try NexCLITaskSettings.shared.configuration() }
        var request = URLRequest(url: configuration.baseURL.appending(path: "/nex/tasks"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authenticate(&request, configuration: configuration)
        let payload: [String: Any] = [
            "directory": configuration.directory,
            "prompt": prompt,
            "title": title ?? "Nex task",
            "permissionMode": "ask",
            "idempotencyKey": context.executionID.uuidString
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let accepted = try JSONDecoder().decode(NexCLITaskAccepted.self, from: data)
        var record = NexCLITaskRecord(
            id: accepted.taskId,
            title: title ?? "Nex CLI task",
            status: "Starting…",
            detail: "NEX > \(title ?? "task")",
            state: .queued
        )
        await update(record)
        await context.reportProgress(record.detail, nil)
        try await stream(accepted: accepted, configuration: configuration, record: &record, context: context)
        let snapshot = try await fetchSnapshot(accepted: accepted, configuration: configuration)
        record.finalText = snapshot.finalText
        record.state = snapshot.status == "completed" ? .completed : (snapshot.status == "cancelled" ? .cancelled : .failed)
        record.status = record.state == .completed ? "Task completed" : (snapshot.error ?? "Task did not complete")
        record.detail = record.status
        record.outputURL = playableOutput(from: snapshot)
        record.updatedAt = Date()
        await update(record)
        await context.reportProgress(record.status, 1)
        var result: [String: NexJSONValue] = [
            "task_id": .string(snapshot.taskId),
            "final_text": .string(snapshot.finalText),
            "files_changed": .array(snapshot.filesChanged.map(NexJSONValue.string)),
            "status": .string(snapshot.status)
        ]
        if let outputURL = record.outputURL { result["output_url"] = .string(outputURL.absoluteString) }
        if let error = snapshot.error { result["error"] = .string(error) }
        return .object(result)
    }

    private func stream(
        accepted: NexCLITaskAccepted,
        configuration: NexCLITaskConfiguration,
        record: inout NexCLITaskRecord,
        context: NexToolExecutionContext
    ) async throws {
        guard let url = URL(string: accepted.streamUrl, relativeTo: configuration.baseURL) else {
            throw LocalModelError.invalidResponse("Nex CLI returned an invalid event stream URL")
        }
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authenticate(&request, configuration: configuration)
        let (bytes, response) = try await session.bytes(for: request)
        try validate(response: response, data: nil)
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"), let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = try? JSONDecoder().decode(NexCLIEvent.self, from: data) else { continue }
            guard event.taskId == accepted.taskId else { continue }
            apply(event: event, to: &record)
            await update(record)
            await context.reportProgress(record.detail, event.status == "completed" ? 1 : nil)
            if ["task.completed", "task.failed", "task.cancelled"].contains(event.type) { return }
        }
    }

    private func fetchSnapshot(accepted: NexCLITaskAccepted, configuration: NexCLITaskConfiguration) async throws -> NexCLISnapshot {
        guard let url = URL(string: accepted.resultUrl, relativeTo: configuration.baseURL) else {
            throw LocalModelError.invalidResponse("Nex CLI returned an invalid task result URL")
        }
        var request = URLRequest(url: url)
        authenticate(&request, configuration: configuration)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(NexCLISnapshot.self, from: data)
    }

    private func apply(event: NexCLIEvent, to record: inout NexCLITaskRecord) {
        record.status = event.message
        let toolLabel = event.tool.map { $0.title ?? $0.name }
        record.detail = toolLabel.map { "NEX > \($0)" } ?? "NEX > \(event.message)"
        record.state = switch event.status {
        case "awaiting_permission": .awaitingPermission
        case "completed": .completed
        case "failed": .failed
        case "cancelled": .cancelled
        default: .running
        }
        record.updatedAt = Date()
    }

    private func playableOutput(from snapshot: NexCLISnapshot) -> URL? {
        guard let file = snapshot.filesChanged.first(where: { $0.lowercased().hasSuffix("index.html") }) else { return nil }
        let candidate = file.hasPrefix("/") ? file : (snapshot.directory as NSString).appendingPathComponent(file)
        return URL(fileURLWithPath: candidate)
    }

    private func update(_ record: NexCLITaskRecord) async {
        await MainActor.run { NexCLITaskController.shared.receive(record) }
    }

    private func authenticate(_ request: inout URLRequest, configuration: NexCLITaskConfiguration) {
        guard let password = configuration.password, !password.isEmpty else { return }
        let raw = "\(configuration.username):\(password)"
        request.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw LocalModelError.invalidResponse("Nex CLI returned no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let message = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(240) ?? ""
            throw LocalModelError.invalidResponse("Nex CLI task server returned \(http.statusCode). \(message)")
        }
    }
}
