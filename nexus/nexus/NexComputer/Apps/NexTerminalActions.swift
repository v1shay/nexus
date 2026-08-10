import AppKit
import Foundation

enum NexTerminalPromptState: String, Codable, Sendable {
    case none
    case yesNo = "yes_no"
    case interactive
}

struct NexTerminalSessionSnapshot: Equatable, Sendable {
    let id: UUID
    let command: String
    let workingDirectory: String
    let stdout: String
    let stderr: String
    let promptState: NexTerminalPromptState
    let isRunning: Bool
    let exitStatus: Int32?
    let durationMilliseconds: Int
}

enum NexTerminalError: LocalizedError, Equatable {
    case invalidExecutable(String)
    case executableNotAllowed(String)
    case shellSyntaxRejected(String)
    case invalidWorkingDirectory(String)
    case environmentKeyNotAllowed(String)
    case invalidEnvironmentEntry(String)
    case sessionNotFound(UUID)
    case sessionNotRunning(UUID)
    case responseNotAllowed(String)
    case terminalUnavailable
    case appleScript(String)

    var errorDescription: String? {
        switch self {
        case .invalidExecutable(let value): "The executable is invalid: \(value)."
        case .executableNotAllowed(let value): "The executable is outside Nexus's allowed command roots: \(value)."
        case .shellSyntaxRejected(let value): "Shell syntax is not accepted. Pass an executable and argv separately: \(value)."
        case .invalidWorkingDirectory(let value): "The working directory is unavailable or outside allowed roots: \(value)."
        case .environmentKeyNotAllowed(let key): "Environment key \(key) is not allowed."
        case .invalidEnvironmentEntry(let value): "Environment entry must use KEY=VALUE: \(value)."
        case .sessionNotFound: "That Nexus terminal session no longer exists."
        case .sessionNotRunning: "That Nexus terminal session is no longer running."
        case .responseNotAllowed: "Only y, yes, n, no, or enter can answer an interactive prompt."
        case .terminalUnavailable: "Terminal.app is not installed."
        case .appleScript(let message): "Terminal automation failed: \(message)"
        }
    }
}

actor NexTerminalSessionManager {
    typealias ProgressReporter = @Sendable (String, Double?) async -> Void

    private enum OutputStream { case stdout, stderr }

    private final class Session: @unchecked Sendable {
        let id: UUID
        let process: Process
        let standardInput: Pipe
        let standardOutput: Pipe
        let standardError: Pipe
        let command: String
        let workingDirectory: String
        let startedAt: Date
        var stdout = ""
        var stderr = ""
        var promptState: NexTerminalPromptState = .none
        var finishedAt: Date?
        var exitStatus: Int32?

        init(
            id: UUID,
            process: Process,
            standardInput: Pipe,
            standardOutput: Pipe,
            standardError: Pipe,
            command: String,
            workingDirectory: String,
            startedAt: Date
        ) {
            self.id = id
            self.process = process
            self.standardInput = standardInput
            self.standardOutput = standardOutput
            self.standardError = standardError
            self.command = command
            self.workingDirectory = workingDirectory
            self.startedAt = startedAt
        }
    }

    private static let executableRoots = ["/bin", "/usr/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
    private static let environmentAllowlist: Set<String> = ["LANG", "LC_ALL", "LC_CTYPE", "TERM", "NO_COLOR", "CI"]
    private static let maximumOutputBytes = 1_000_000
    /// A command that neither finishes nor presents a bounded interactive
    /// prompt must still yield its stable session ID. That makes the public
    /// get-output and cancel actions reachable for long-running work instead
    /// of trapping the caller inside the original run request.
    private static let initialObservationWindow = Duration.milliseconds(750)

    private let allowedWorkingRoots: [URL]
    private var sessions: [UUID: Session] = [:]

    init(
        allowedWorkingRoots: [URL]? = nil
    ) {
        let fileManager = FileManager.default
        self.allowedWorkingRoots = allowedWorkingRoots ?? [
            fileManager.homeDirectoryForCurrentUser,
            fileManager.temporaryDirectory,
            URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        ]
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environmentEntries: [String],
        progress: @escaping ProgressReporter
    ) async throws -> NexTerminalSessionSnapshot {
        let executableURL = try resolveExecutable(executable)
        try validateArguments(arguments)
        let directoryURL = try resolveWorkingDirectory(workingDirectory)
        let environment = try makeEnvironment(environmentEntries)
        let id = UUID()
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directoryURL
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        let command = ([executableURL.path] + arguments).map(Self.displayArgument).joined(separator: " ")
        let session = Session(
            id: id,
            process: process,
            standardInput: standardInput,
            standardOutput: standardOutput,
            standardError: standardError,
            command: command,
            workingDirectory: directoryURL.path,
            startedAt: Date()
        )
        sessions[id] = session

        let manager = self
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await manager.append(data, stream: .stdout, sessionID: id, progress: progress) }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await manager.append(data, stream: .stderr, sessionID: id, progress: progress) }
        }
        process.terminationHandler = { process in
            Task { await manager.finish(sessionID: id, exitStatus: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            sessions[id] = nil
            throw NexToolError.executionFailed(code: "terminal_launch_failed", message: error.localizedDescription)
        }
        await progress("Running \(executableURL.lastPathComponent)…", nil)
        await withTaskCancellationHandler {
            await waitForCompletionOrPrompt(sessionID: id)
        } onCancel: {
            Task { await self.cancel(sessionID: id) }
        }
        guard let snapshot = snapshot(sessionID: id) else { throw NexTerminalError.sessionNotFound(id) }
        return snapshot
    }

    func snapshot(sessionID: UUID) -> NexTerminalSessionSnapshot? {
        guard let session = sessions[sessionID] else { return nil }
        let end = session.finishedAt ?? Date()
        return .init(
            id: session.id,
            command: session.command,
            workingDirectory: session.workingDirectory,
            stdout: session.stdout,
            stderr: session.stderr,
            promptState: session.promptState,
            isRunning: session.exitStatus == nil,
            exitStatus: session.exitStatus,
            durationMilliseconds: max(0, Int(end.timeIntervalSince(session.startedAt) * 1_000))
        )
    }

    func respond(sessionID: UUID, response: String) throws {
        guard let session = sessions[sessionID] else { throw NexTerminalError.sessionNotFound(sessionID) }
        guard session.exitStatus == nil, session.process.isRunning else { throw NexTerminalError.sessionNotRunning(sessionID) }
        guard session.promptState != .none else { throw NexTerminalError.responseNotAllowed(response) }
        let normalized = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let payload: String
        switch normalized {
        case "y", "yes", "n", "no": payload = normalized + "\n"
        case "", "enter": payload = "\n"
        default: throw NexTerminalError.responseNotAllowed(response)
        }
        try session.standardInput.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        session.promptState = .none
    }

    func cancel(sessionID: UUID) {
        guard let session = sessions[sessionID], session.exitStatus == nil else { return }
        session.process.terminate()
    }

    private func append(
        _ data: Data,
        stream: OutputStream,
        sessionID: UUID,
        progress: @escaping ProgressReporter
    ) async {
        guard let session = sessions[sessionID] else { return }
        let text = String(decoding: data, as: UTF8.self)
        switch stream {
        case .stdout: session.stdout = Self.bounded(session.stdout + text)
        case .stderr: session.stderr = Self.bounded(session.stderr + text)
        }
        session.promptState = Self.detectPrompt(in: session.stdout + "\n" + session.stderr)
        let label = stream == .stdout ? "Terminal output" : "Terminal error output"
        await progress("\(label): \(Self.lastReadableLine(text))", nil)
    }

    private func finish(sessionID: UUID, exitStatus: Int32) {
        guard let session = sessions[sessionID] else { return }
        session.standardOutput.fileHandleForReading.readabilityHandler = nil
        session.standardError.fileHandleForReading.readabilityHandler = nil
        session.process.terminationHandler = nil
        session.exitStatus = exitStatus
        session.finishedAt = Date()
        session.promptState = .none
    }

    private func waitForCompletionOrPrompt(sessionID: UUID) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.initialObservationWindow)
        while !Task.isCancelled,
              clock.now < deadline,
              let session = sessions[sessionID],
              session.exitStatus == nil,
              session.promptState == .none {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func resolveExecutable(_ requested: String) throws -> URL {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Self.containsShellSyntax(trimmed) else {
            throw NexTerminalError.invalidExecutable(requested)
        }
        let candidates: [URL]
        if trimmed.hasPrefix("/") {
            candidates = [URL(fileURLWithPath: trimmed)]
        } else {
            guard !trimmed.contains("/") else { throw NexTerminalError.invalidExecutable(requested) }
            candidates = Self.executableRoots.map { URL(fileURLWithPath: $0).appendingPathComponent(trimmed) }
        }
        guard let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw NexTerminalError.invalidExecutable(requested)
        }
        let resolved = match.resolvingSymlinksInPath().standardizedFileURL
        guard Self.executableRoots.contains(where: { Self.contains(resolved, in: URL(fileURLWithPath: $0, isDirectory: true)) }) else {
            throw NexTerminalError.executableNotAllowed(resolved.path)
        }
        return resolved
    }

    private func validateArguments(_ arguments: [String]) throws {
        for argument in arguments where Self.containsShellSyntax(argument) {
            throw NexTerminalError.shellSyntaxRejected(argument)
        }
    }

    private func resolveWorkingDirectory(_ requested: String?) throws -> URL {
        let fileManager = FileManager.default
        let fallback = allowedWorkingRoots.first ?? fileManager.temporaryDirectory
        let candidate = requested.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fallback
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NexTerminalError.invalidWorkingDirectory(candidate.path)
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard allowedWorkingRoots.contains(where: { Self.contains(resolved, in: $0.resolvingSymlinksInPath().standardizedFileURL) }) else {
            throw NexTerminalError.invalidWorkingDirectory(candidate.path)
        }
        return resolved
    }

    private func makeEnvironment(_ entries: [String]) throws -> [String: String] {
        var environment: [String: String] = [
            "PATH": Self.executableRoots.joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "TERM": "dumb"
        ]
        for entry in entries {
            guard let separator = entry.firstIndex(of: "=") else { throw NexTerminalError.invalidEnvironmentEntry(entry) }
            let key = String(entry[..<separator])
            let value = String(entry[entry.index(after: separator)...])
            guard Self.environmentAllowlist.contains(key) else { throw NexTerminalError.environmentKeyNotAllowed(key) }
            guard !value.contains("\0"), !value.contains("\n"), value.count <= 2_048 else {
                throw NexTerminalError.invalidEnvironmentEntry(entry)
            }
            environment[key] = value
        }
        return environment
    }

    private static func contains(_ child: URL, in root: URL) -> Bool {
        child.path == root.path || child.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    private static func containsShellSyntax(_ value: String) -> Bool {
        value.range(of: #"(;|&&|\|\||`|\$\(|\r|\n|<|>)"#, options: .regularExpression) != nil
    }

    private static func displayArgument(_ value: String) -> String {
        value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? value : "“\(value)”"
    }

    private static func bounded(_ value: String) -> String {
        guard value.utf8.count > maximumOutputBytes else { return value }
        return String(value.suffix(maximumOutputBytes / 2))
    }

    private static func lastReadableLine(_ value: String) -> String {
        value.split(whereSeparator: { $0.isNewline }).last.map(String.init)?.prefix(180).description ?? "Received output"
    }

    private static func detectPrompt(in output: String) -> NexTerminalPromptState {
        let tail = String(output.suffix(512)).lowercased()
        if tail.range(of: #"(\[y/n\]|\(y/n\)|\[yes/no\]|\(yes/no\)|continue\?)\s*$"#, options: .regularExpression) != nil {
            return .yesNo
        }
        if tail.range(of: #"(password:|passphrase:|press enter|input:)\s*$"#, options: .regularExpression) != nil {
            return .interactive
        }
        return .none
    }
}

final class NexTerminalApplicationController: @unchecked Sendable {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func open() async throws {
        guard let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw NexTerminalError.terminalUnavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await workspace.openApplication(at: url, configuration: configuration)
    }

    func openTab() throws -> String {
        try runAppleScript("""
        tell application "Terminal"
            activate
            if not (exists window 1) then
                set nexusTab to do script ""
            else
                set nexusTab to do script "" in front window
            end if
            return tty of nexusTab
        end tell
        """)
    }

    func activeSession() throws -> String {
        try runAppleScript("""
        tell application "Terminal"
            if not (exists window 1) then return ""
            return tty of selected tab of front window
        end tell
        """)
    }

    func write(command: String, toTTY tty: String) throws {
        guard !tty.isEmpty else { throw NexTerminalError.appleScript("A target Terminal session is required.") }
        _ = try runAppleScript("""
        tell application "Terminal"
            set targetTabs to every tab of every window whose tty is "\(Self.escape(tty))"
            if (count of targetTabs) is 0 then error "Terminal session was not found."
            do script "\(Self.escape(command))" in item 1 of targetTabs
            activate
        end tell
        return "\(Self.escape(tty))"
        """)
    }

    private func runAppleScript(_ source: String) throws -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            throw NexTerminalError.appleScript(error[NSAppleScript.errorMessage] as? String ?? error.description)
        }
        return result?.stringValue ?? ""
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

actor NexTerminalActionCatalog {
    private let sessions: NexTerminalSessionManager
    private let application: NexTerminalApplicationController
    private var registered = false

    init(
        sessions: NexTerminalSessionManager = NexTerminalSessionManager(),
        application: NexTerminalApplicationController = NexTerminalApplicationController()
    ) {
        self.sessions = sessions
        self.application = application
    }

    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }
        try await registry.register(manifest: Self.openManifest) { [application] _, _ in
            try await application.open()
            return .object(["display": .string("Opened Terminal."), "status": .string("opened")])
        }
        try await registry.register(manifest: Self.openTabManifest) { [application] _, _ in
            let tty = try application.openTab()
            return .object(["display": .string("Opened a new Terminal tab."), "sessionId": .string(tty)])
        }
        try await registry.register(manifest: Self.activeSessionManifest) { [application] _, _ in
            let tty = try application.activeSession()
            return .object([
                "display": .string(tty.isEmpty ? "Terminal has no active session." : "Active Terminal session: \(tty)"),
                "sessionId": .string(tty),
                "status": .string(tty.isEmpty ? "unavailable" : "active")
            ])
        }
        try await registry.register(manifest: Self.writeManifest) { [application] arguments, _ in
            guard let command = arguments["command"]?.string else { throw NexToolError.missingField("command") }
            guard let sessionID = arguments["sessionId"]?.string else { throw NexToolError.missingField("sessionId") }
            try application.write(command: command, toTTY: sessionID)
            return .object([
                "display": .string("Wrote the confirmed command to Terminal session \(sessionID)."),
                "sessionId": .string(sessionID),
                "status": .string("submitted")
            ])
        }
        try await registry.register(manifest: Self.runManifest) { [sessions] arguments, context in
            guard let executable = arguments["executable"]?.string else { throw NexToolError.missingField("executable") }
            let snapshot = try await sessions.run(
                executable: executable,
                arguments: arguments["arguments"]?.strings ?? [],
                workingDirectory: arguments["workingDirectory"]?.string,
                environmentEntries: arguments["environment"]?.strings ?? [],
                progress: context.reportProgress
            )
            return Self.snapshotJSON(snapshot)
        }
        try await registry.register(manifest: Self.outputManifest) { [sessions] arguments, _ in
            let id = try Self.sessionUUID(arguments)
            guard let snapshot = await sessions.snapshot(sessionID: id) else { throw NexTerminalError.sessionNotFound(id) }
            return Self.snapshotJSON(snapshot)
        }
        try await registry.register(manifest: Self.respondManifest) { [sessions] arguments, _ in
            let id = try Self.sessionUUID(arguments)
            guard let response = arguments["response"]?.string else { throw NexToolError.missingField("response") }
            try await sessions.respond(sessionID: id, response: response)
            return .object(["display": .string("Answered the terminal prompt."), "sessionId": .string(id.uuidString), "status": .string("responded")])
        }
        try await registry.register(manifest: Self.cancelManifest) { [sessions] arguments, _ in
            let id = try Self.sessionUUID(arguments)
            await sessions.cancel(sessionID: id)
            return .object(["display": .string("Cancelled the Nexus terminal session."), "sessionId": .string(id.uuidString), "status": .string("cancelled")])
        }
        registered = true
    }

    private static func sessionUUID(_ arguments: [String: NexJSONValue]) throws -> UUID {
        guard let raw = arguments["sessionId"]?.string, let id = UUID(uuidString: raw) else {
            throw NexToolError.executionFailed(code: "invalid_session_id", message: "A valid Nexus terminal session ID is required.")
        }
        return id
    }

    private static func snapshotJSON(_ snapshot: NexTerminalSessionSnapshot) -> NexJSONValue {
        var object: [String: NexJSONValue] = [
            "display": .string(snapshot.exitStatus == 0 ? "Terminal command completed." : "Terminal command finished with status \(snapshot.exitStatus.map(String.init) ?? "running")."),
            "sessionId": .string(snapshot.id.uuidString),
            "command": .string(snapshot.command),
            "workingDirectory": .string(snapshot.workingDirectory),
            "stdout": .string(snapshot.stdout),
            "stderr": .string(snapshot.stderr),
            "promptState": .string(snapshot.promptState.rawValue),
            "status": .string(snapshot.isRunning ? "running" : "completed"),
            "durationMs": .number(Double(snapshot.durationMilliseconds))
        ]
        if let exitStatus = snapshot.exitStatus { object["exitStatus"] = .number(Double(exitStatus)) }
        return .object(object)
    }

    private static let terminalPermissions = [NexComputerPermissionRequirement(
        id: "automation.com.apple.Terminal",
        permission: .automation,
        recovery: "Open System Settings > Privacy & Security > Automation and allow Nexus to control Terminal."
    )]
    private static let terminalAvailability = NexComputerAvailabilityCheck.application(bundleIdentifier: "com.apple.Terminal")
    private static let simpleOutput = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true)])
    private static let sessionOutput = NexToolInputSchema(fields: ["display": .init(.string, required: true), "sessionId": .init(.string, required: true), "status": .init(.string)])
    private static let processOutput = NexToolInputSchema(fields: [
        "display": .init(.string, required: true), "sessionId": .init(.string, required: true),
        "command": .init(.string, required: true), "workingDirectory": .init(.string, required: true),
        "stdout": .init(.string, required: true), "stderr": .init(.string, required: true),
        "promptState": .init(.string, required: true), "status": .init(.string, required: true),
        "exitStatus": .init(.integer), "durationMs": .init(.integer, required: true)
    ])

    private static let openManifest = manifest(
        id: "terminal.open", description: "Open or activate Terminal.app without running a command.",
        examples: ["Open Terminal"], input: .init(fields: [:]), output: simpleOutput,
        permissions: [], risk: .low, confirmation: .never, implementation: .nativeAPI
    )
    private static let openTabManifest = manifest(
        id: "terminal.open_tab", description: "Open a new visible Terminal tab owned by an explicit Nexus request.",
        examples: ["Open a new terminal tab"], input: .init(fields: [:]), output: sessionOutput,
        permissions: terminalPermissions, risk: .low, confirmation: .never, implementation: .appleScript
    )
    private static let activeSessionManifest = manifest(
        id: "terminal.get_active_session", description: "Return the stable TTY identifier of Terminal's selected visible tab.",
        examples: ["Which terminal session is active?"], input: .init(fields: [:]), output: sessionOutput,
        permissions: terminalPermissions, risk: .low, confirmation: .never, implementation: .appleScript
    )
    private static let writeManifest = manifest(
        id: "terminal.write_to_session", description: "Write one confirmed command into a specifically identified visible Terminal TTY; never targets the merely focused window.",
        examples: ["Run this command in my visible terminal tab"],
        input: .init(fields: ["sessionId": .init(.string, required: true), "command": .init(.string, required: true)]), output: sessionOutput,
        permissions: terminalPermissions, risk: .high, confirmation: .always, implementation: .appleScript
    )
    private static let runManifest = manifest(
        id: "terminal.run_command", description: "Run an executable directly with a separate argv array in an isolated Nexus process and stream stdout and stderr. Returns a stable session ID after completion, a supported prompt, or brief startup observation so long-running work can be inspected or cancelled. Shell strings and metacharacters are rejected.",
        examples: ["Run git status in this project", "Print the current directory"],
        input: .init(fields: [
            "executable": .init(.string, required: true, description: "Executable name or allowed absolute executable path."),
            "arguments": .init(.stringArray, description: "Separate argv entries after executable; never repeat executable or use a shell command string."),
            "workingDirectory": .init(.string, description: "Existing directory under an allowed user or temporary root."),
            "environment": .init(.stringArray, description: "Allowlisted KEY=VALUE entries only.")
        ]), output: processOutput, permissions: [], risk: .high, confirmation: .always, implementation: .nativeAPI
    )
    private static let outputManifest = manifest(
        id: "terminal.get_output", description: "Read the current stdout, stderr, prompt state, and exit status of a Nexus-owned command session.",
        examples: ["Show output from that command"], input: .init(fields: ["sessionId": .init(.string, required: true)]), output: processOutput,
        permissions: [], risk: .low, confirmation: .never, implementation: .nativeAPI
    )
    private static let respondManifest = manifest(
        id: "terminal.respond_to_prompt", description: "Answer a detected Y/N or Enter prompt in a Nexus-owned command session.",
        examples: ["Answer yes to the terminal prompt"],
        input: .init(fields: ["sessionId": .init(.string, required: true), "response": .init(.string, required: true, allowedValues: ["y", "yes", "n", "no", "enter"])]),
        output: sessionOutput, permissions: [], risk: .high, confirmation: .always, implementation: .nativeAPI
    )
    private static let cancelManifest = manifest(
        id: "terminal.cancel", description: "Cancel one Nexus-owned running command session by stable session ID.",
        examples: ["Stop that terminal command"], input: .init(fields: ["sessionId": .init(.string, required: true)]), output: sessionOutput,
        permissions: [], risk: .low, confirmation: .never, implementation: .nativeAPI
    )

    private static func manifest(
        id: String,
        description: String,
        examples: [String],
        input: NexToolInputSchema,
        output: NexToolInputSchema,
        permissions: [NexComputerPermissionRequirement],
        risk: NexComputerRiskClass,
        confirmation: NexComputerConfirmationPolicy,
        implementation: NexComputerImplementationMethod
    ) -> NexComputerActionManifest {
        .init(
            actionID: id, application: "Terminal", provider: "Nexus Local Terminal",
            bundleIdentifier: implementation == .appleScript || id == "terminal.open" ? "com.apple.Terminal" : nil,
            description: description, examples: examples, aliases: [id.replacingOccurrences(of: ".", with: " ")],
            tags: ["terminal", "command", "process", "shell"], inputSchema: input, outputSchema: output,
            implementationMethod: implementation, requiredPermissions: permissions, registryPermission: .codeExecution,
            riskClass: risk, confirmationPolicy: confirmation,
            availabilityCheck: implementation == .appleScript || id == "terminal.open" ? terminalAvailability : .always,
            timeoutSeconds: id == "terminal.run_command" ? 120 : 15, supportsCancellation: id == "terminal.run_command",
            dryRunBehavior: .supported("Would perform \(id) without side effects."), previewRenderer: "terminal.action", tests: ["NexTerminalActionTests"]
        )
    }
}
