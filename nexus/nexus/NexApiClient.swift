import Foundation

/// Typed client for Nex's task API. This deliberately talks only to `/nex/*`;
/// it does not fall back to OpenCode session or chat routes.
actor NexApiClient {
    struct Model: Codable, Equatable, Sendable {
        let providerID: String
        let modelID: String

        static let localCodingDefault = Self(providerID: "ollama", modelID: "gpt-oss:latest")
    }

    struct TaskRequest: Sendable {
        let directory: URL
        let prompt: String
        let title: String?
        let agent: String
        let model: Model
        let idempotencyKey: UUID
    }

    struct AcceptedTask: Decodable, Sendable {
        let taskId: String
        let streamUrl: String
        let resultUrl: String
    }

    struct Tool: Decodable, Equatable, Sendable {
        let name: String
        let title: String?
        let state: String
    }

    struct Event: Decodable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case queued
            case thinking
            case toolStarted
            case toolCompleted
            case textDelta
            case completed
            case failed
            case awaitingPermission
            case other
        }

        let taskId: String
        let type: String
        let status: String
        let message: String
        let tool: Tool?
        let data: [String: NexAPIJSONValue]

        /// Gateway event spelling can evolve without coupling the overlay to
        /// the HTTP service. Callers consume this stable, semantic surface.
        var kind: Kind {
            switch (type, status) {
            case (_, "queued"): .queued
            case (_, "awaiting_permission"): .awaitingPermission
            case (_, "completed"), ("task.completed", _): .completed
            case (_, "failed"), ("task.failed", _): .failed
            case (let type, _) where type.contains("tool.started"): .toolStarted
            case (let type, _) where type.contains("tool.completed"): .toolCompleted
            case (let type, _) where type.contains("text.delta"): .textDelta
            case (_, "thinking"), (_, "using_tool"): .thinking
            default: .other
            }
        }
    }

    struct Result: Decodable, Sendable {
        let taskId: String
        let status: String
        let finalText: String
        let directory: String
        let filesChanged: [String]
        let tools: [NexAPIJSONValue]
        let error: String?
    }

    private struct Payload: Encodable {
        let directory: String
        let prompt: String
        let agent: String
        let model: Model
        let title: String?
        let idempotencyKey: String
    }

    private let baseURL: URL
    private let username: String
    private let password: String?
    private let session: URLSession

    init(baseURL: URL, username: String, password: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.session = session
    }

    func create(_ task: TaskRequest) async throws -> AcceptedTask {
        let directory = Self.canonicalDirectory(task.directory)
        var request = try makeRequest(path: "/nex/tasks", directory: directory)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(
            directory: directory,
            prompt: task.prompt,
            agent: task.agent,
            model: task.model,
            title: task.title,
            idempotencyKey: task.idempotencyKey.uuidString
        ))
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(AcceptedTask.self, from: data)
    }

    func events(for task: AcceptedTask, directory: URL, receive: @escaping @Sendable (Event) async -> Void) async throws {
        let canonical = Self.canonicalDirectory(directory)
        var request = try makeRequest(path: task.streamUrl, directory: canonical)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        try validate(response: response, data: nil)
        for try await line in bytes.lines {
            guard line.hasPrefix("data:"),
                  let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = try? JSONDecoder().decode(Event.self, from: data),
                  event.taskId == task.taskId else { continue }
            await receive(event)
            if [.completed, .failed].contains(event.kind) || event.status == "cancelled" { return }
        }
    }

    func result(for task: AcceptedTask, directory: URL) async throws -> Result {
        let request = try makeRequest(path: task.resultUrl, directory: Self.canonicalDirectory(directory))
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Result.self, from: data)
    }

    private func makeRequest(path: String, directory: String) throws -> URLRequest {
        let url: URL
        if let absolute = URL(string: path), absolute.scheme != nil {
            url = absolute
        } else {
            url = baseURL.appending(path: path)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NexApiClientError.invalidURL
        }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "directory" }
        query.append(.init(name: "directory", value: directory))
        components.queryItems = query
        guard let resolved = components.url else { throw NexApiClientError.invalidURL }
        var request = URLRequest(url: resolved)
        request.timeoutInterval = 30
        // Current Nex accepts the query parameter. The header is retained for
        // compatibility with older workers during a rolling update.
        request.setValue(directory, forHTTPHeaderField: "x-opencode-directory")
        if let password, !password.isEmpty {
            request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func canonicalDirectory(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw NexApiClientError.invalidResponse("Nex returned no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw NexApiClientError.invalidResponse("Nex task API returned \(http.statusCode). \(body.prefix(240))")
        }
    }
}

enum NexAPIJSONValue: Decodable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: NexAPIJSONValue]), array([NexAPIJSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode([String: NexAPIJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([NexAPIJSONValue].self)) }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

enum NexApiClientError: LocalizedError {
    case invalidURL
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Nex task API produced an invalid URL."
        case .invalidResponse(let message): message
        }
    }
}
