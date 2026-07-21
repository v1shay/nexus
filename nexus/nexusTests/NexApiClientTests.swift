import Foundation
import XCTest
@testable import nexus

extension NexusGeometryTests {
    func testNexApiClientPreservesCanonicalWorkspaceInRouteAndPayload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NexApiClientURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let workspace = URL(fileURLWithPath: "/tmp/nex-api-client-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let expectedDirectory = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let observed = Locked<NexApiClientURLProtocol.Observed?>(nil)
        NexApiClientURLProtocol.handler = { request in
            observed.set(.init(request: request, body: NexApiClientURLProtocol.body(from: request)))
            return (200, "{\"taskId\":\"task-1\",\"streamUrl\":\"/nex/tasks/task-1/events\",\"resultUrl\":\"/nex/tasks/task-1\"}")
        }
        defer { NexApiClientURLProtocol.handler = nil }

        let client = NexApiClient(
            baseURL: URL(string: "http://127.0.0.1:4096")!,
            username: "opencode",
            password: "test-password",
            session: session
        )
        let accepted = try await client.create(.init(
            directory: workspace,
            prompt: "Build a small focus timer.",
            title: "Focus timer",
            agent: "nex-local",
            model: .localCodingDefault,
            idempotencyKey: UUID()
        ))

        XCTAssertEqual(accepted.taskId, "task-1")
        let request = try XCTUnwrap(observed.value?.request)
        XCTAssertEqual(request.url?.path, "/nex/tasks")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "directory" })?.value, expectedDirectory)
        let body = try XCTUnwrap(observed.value?.body)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["directory"] as? String, expectedDirectory)
        XCTAssertEqual(payload["agent"] as? String, "nex-local")
        XCTAssertEqual((payload["model"] as? [String: String])?["providerID"], "ollama")
        XCTAssertEqual((payload["model"] as? [String: String])?["modelID"], "gpt-oss:latest")
    }

    func testNexApiClientNormalizesRealGatewayEventNames() {
        let started = NexApiClient.Event(taskId: "task", type: "tool.started", status: "using_tool", message: "Writing files", tool: nil, data: [:])
        let text = NexApiClient.Event(taskId: "task", type: "text.delta", status: "thinking", message: "hello", tool: nil, data: ["delta": .string("hello")])
        let completed = NexApiClient.Event(taskId: "task", type: "task.completed", status: "completed", message: "Done", tool: nil, data: [:])
        XCTAssertEqual(started.kind, .toolStarted)
        XCTAssertEqual(text.kind, .textDelta)
        XCTAssertEqual(completed.kind, .completed)
    }
}

private final class NexApiClientURLProtocol: URLProtocol {
    struct Observed {
        let request: URLRequest
        let body: Data?
    }
    static var handler: ((URLRequest) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = handler(request)
        let url = request.url ?? URL(string: "http://127.0.0.1")!
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: response.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ value: Value) { lock.lock(); storage = value; lock.unlock() }
}
