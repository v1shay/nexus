import Darwin
import Foundation

/// The task worker is a background Nexus mode, not a child of the notch UI.
/// Keeping this separate means closing/rebuilding Nexus never kills an active
/// coding task, and launchd can restore it after login or an unexpected exit.
enum NexCLIHostProcess {
    static let argument = "--nex-cli-host"
    static let environmentKey = "NEXUS_NEXCLI_HOST"
    static var isCurrentProcess: Bool {
        let environmentFlag = environmentKey.withCString { key in
            guard let value = getenv(key) else { return false }
            return String(cString: value) == "1"
        }
        return CommandLine.arguments.contains(argument)
            || ProcessInfo.processInfo.environment[environmentKey] == "1"
            || environmentFlag
    }
}

struct NexCLIHostStatus: Codable, Equatable, Sendable {
    let processID: Int32
    let workerProcessID: Int32
    let state: String
    let detail: String?
    let runtime: String?
    let updatedAt: Date

    var isLive: Bool {
        guard processID > 0, Date().timeIntervalSince(updatedAt) < 20 else { return false }
        return Darwin.kill(processID, 0) == 0 || errno == EPERM
    }
}

/// A single credential is shared by the Nexus caller and its loopback worker.
/// It never appears in the LaunchAgent plist or in the Nex UI.
enum NexCLILoopbackCredential {
    private static let account = "managed-loopback-password.v1"
    private static let store = NexusKeychainSecretStore(service: "na.nexus.nex-cli")

    static func loadOrCreate() throws -> String {
        if let data = try store.data(for: account), let password = String(data: data, encoding: .utf8), !password.isEmpty {
            return password
        }
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        let password = Data(bytes).base64EncodedString()
        try store.set(Data(password.utf8), for: account)
        return password
    }
}

struct NexCLIHostManager: @unchecked Sendable {
    static let shared = NexCLIHostManager()
    static let label = "na.nexus.nex-cli-host"

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let executableURL: URL
    private let processRunner: @Sendable (URL, [String]) throws -> Void

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executableURL: URL? = nil,
        processRunner: (@Sendable (URL, [String]) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.executableURL = executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        self.processRunner = processRunner ?? { executable, arguments in try Self.run(executable, arguments) }
    }

    var launchAgentURL: URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    var supportDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/Nexus/NexCLI", isDirectory: true)
    }

    var statusURL: URL { supportDirectory.appendingPathComponent("status.json") }
    var lockURL: URL { supportDirectory.appendingPathComponent("worker.lock") }
    var standardOutputURL: URL { supportDirectory.appendingPathComponent("worker.log") }
    var standardErrorURL: URL { supportDirectory.appendingPathComponent("worker-error.log") }

    /// Read the last host record even when the LaunchAgent itself has been
    /// restarted. The worker PID is the authority for a reusable daemon;
    /// `processID` only identifies the small launchd supervisor.
    private func storedStatus() -> NexCLIHostStatus? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? NexusPayloadCoder.decoder.decode(NexCLIHostStatus.self, from: data)
    }

    func installAndStart() throws {
        guard !NexCLIHostProcess.isCurrentProcess else { return }
        _ = try NexCLILoopbackCredential.loadOrCreate()
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let expected = launchAgentPropertyList()
        let current = try? Data(contentsOf: launchAgentURL)
        if current != expected {
            if fileManager.fileExists(atPath: launchAgentURL.path) {
                try? processRunner(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", "gui/\(getuid())/\(Self.label)"])
            }
            try expected.write(to: launchAgentURL, options: .atomic)
            try processRunner(URL(fileURLWithPath: "/bin/launchctl"), ["bootstrap", "gui/\(getuid())", launchAgentURL.path])
        }
        try processRunner(URL(fileURLWithPath: "/bin/launchctl"), ["kickstart", "-k", "gui/\(getuid())/\(Self.label)"])
    }

    func currentStatus() -> NexCLIHostStatus? {
        guard let status = storedStatus(),
              status.isLive else { return nil }
        return status
    }

    /// The app-side client calls this immediately before creating a task. It
    /// reuses a healthy daemon and otherwise asks launchd to start exactly one
    /// managed worker, then waits for its authenticated Nex health endpoint.
    func ensureReady() async throws {
        let password = try NexCLILoopbackCredential.loadOrCreate()
        if await isManagedDaemonReady(password: password) { return }
        try reclaimKnownLegacyDaemonIfNeeded()
        try installAndStart()
        for _ in 0..<75 {
            try await Task.sleep(for: .milliseconds(400))
            if await isManagedDaemonReady(password: password) { return }
        }
        throw NexusConnectError.unavailable("Nex local daemon did not become ready. Nexus only accepts its managed NexCLI worker; check the NexCLI worker log and try again.")
    }

    /// A 200 health response alone is deliberately insufficient. An earlier
    /// version treated any Nex/OpenCode process on 4096 as ours, which let an
    /// old development server answer newer `/nex/tasks` requests with an
    /// incompatible JSON shape.
    func isManagedDaemonReady(password: String) async -> Bool {
        guard await Self.isHealthy(password: password),
              let status = storedStatus(),
              status.workerProcessID > 0,
              Self.isProcessAlive(status.workerProcessID),
              let listenerPID = Self.listenerProcessID(),
              listenerPID == status.workerProcessID,
              Self.parentProcessID(of: status.workerProcessID) == status.processID else { return false }
        return true
    }

    func managedWorkerProcessID() -> Int32? {
        guard let status = storedStatus(),
              status.workerProcessID > 0,
              Self.isProcessAlive(status.workerProcessID),
              Self.listenerProcessID() == status.workerProcessID,
              Self.parentProcessID(of: status.workerProcessID) == status.processID else { return nil }
        return status.workerProcessID
    }

    /// Port 4096 belongs to the managed local runtime. We only reclaim an
    /// identifiable legacy Nex development worker—not an arbitrary process
    /// which happens to listen on that port.
    func reclaimKnownLegacyDaemonIfNeeded() throws {
        guard let listenerPID = Self.listenerProcessID() else { return }
        if managedWorkerProcessID() == listenerPID { return }
        let commandLine = Self.commandLine(for: listenerPID) ?? ""
        guard Self.isKnownLegacyNexListener(commandLine: commandLine) else {
            throw NexusConnectError.unavailable("Port 4096 is already used by another local service. Quit that service or choose a different Nex CLI endpoint; Nexus will not replace an unknown process.")
        }
        guard Darwin.kill(listenerPID, SIGTERM) == 0 || errno == ESRCH else {
            throw NexusConnectError.unavailable("Nexus could not restart its older local NexCLI worker.")
        }
        for _ in 0..<20 {
            if Self.listenerProcessID() != listenerPID { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw NexusConnectError.unavailable("The older local NexCLI worker did not stop. Quit it once, then retry; Nexus will preserve your workspace.")
    }

    static func isKnownLegacyNexListener(commandLine: String) -> Bool {
        let normalized = commandLine.replacingOccurrences(of: "\n", with: " ")
        return normalized.contains("/Documents/nex-cli/packages/opencode/src/index.ts")
            && normalized.contains(" serve")
            && normalized.contains("--port 4096")
    }

    private static func isProcessAlive(_ processID: Int32) -> Bool {
        Darwin.kill(processID, 0) == 0 || errno == EPERM
    }

    private static func listenerProcessID() -> Int32? {
        guard let output = capture(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP:4096", "-sTCP:LISTEN", "-t"]
        ) else { return nil }
        return output.split(whereSeparator: \.isNewline).compactMap { Int32($0) }.first
    }

    private static func commandLine(for processID: Int32) -> String? {
        capture(executable: URL(fileURLWithPath: "/bin/ps"), arguments: ["-p", "\(processID)", "-o", "command="])
    }

    private static func parentProcessID(of processID: Int32) -> Int32? {
        guard let output = capture(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-p", "\(processID)", "-o", "ppid="]
        ) else { return nil }
        return Int32(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func capture(executable: URL, arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }

    static func isHealthy(password: String) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:4096/global/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        request.setValue("Basic \(Data("opencode:\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    func launchAgentPropertyList() -> Data {
        let propertyList: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executableURL.path, NexCLIHostProcess.argument],
            "EnvironmentVariables": [NexCLIHostProcess.environmentKey: "1"],
            "RunAtLoad": true,
            "KeepAlive": true,
            // The daemon's Bun child must leave with this host. Otherwise a
            // rebuild replaces the supervisor but leaves a stale listener on
            // 4096, which makes readiness intermittent and unsafe.
            "AbandonProcessGroup": false,
            "ProcessType": "Background",
            "ThrottleInterval": 5,
            "StandardOutPath": standardOutputURL.path,
            "StandardErrorPath": standardErrorURL.path
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)) ?? Data()
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NexusConnectError.unavailable("launchctl failed for \(arguments.first ?? executable.lastPathComponent) (\(process.terminationStatus))")
        }
    }
}

private struct NexCLIManagedRuntime: Sendable {
    let executable: URL
    let arguments: [String]
    let description: String
}

@MainActor
final class NexCLIHostDaemon {
    private let manager: NexCLIHostManager
    private let fileManager: FileManager
    private var worker: Process?
    private var monitor: Task<Void, Never>?
    private var terminationSignal: DispatchSourceSignal?
    private var isStopping = false
    private var ownsLock = false
    private var adoptedWorkerProcessID: Int32?

    init(manager: NexCLIHostManager = .shared, fileManager: FileManager = .default) {
        self.manager = manager
        self.fileManager = fileManager
    }

    func start() async {
        installTerminationHandler()
        do {
            let password = try NexCLILoopbackCredential.loadOrCreate()
            if await manager.isManagedDaemonReady(password: password) {
                adoptedWorkerProcessID = manager.managedWorkerProcessID()
                writeStatus(state: "ready", detail: nil, runtime: "managed Nex daemon")
                monitor = Task { [weak self] in await self?.monitorWorker(runtime: nil, password: password) }
                return
            }
            try manager.reclaimKnownLegacyDaemonIfNeeded()
            guard try acquireLock() else {
                writeStatus(state: "starting", detail: "Another Nex daemon is starting.", runtime: nil)
                monitor = Task { [weak self] in await self?.monitorWorker(runtime: nil, password: password) }
                return
            }
            let runtime = try resolveRuntime()
            try startWorker(runtime: runtime, password: password)
            writeStatus(state: "starting", detail: nil, runtime: runtime.description)
            monitor = Task { [weak self] in await self?.monitorWorker(runtime: runtime, password: password) }
        } catch {
            releaseLock()
            writeStatus(state: "failed", detail: error.localizedDescription, runtime: nil)
        }
    }

    func stop() {
        isStopping = true
        monitor?.cancel()
        monitor = nil
        if let process = worker, process.isRunning {
            process.terminate()
            _ = Darwin.kill(process.processIdentifier, SIGTERM)
        }
        worker = nil
        releaseLock()
    }

    private func installTerminationHandler() {
        guard terminationSignal == nil else { return }
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.stop()
            Darwin.exit(EXIT_SUCCESS)
        }
        source.resume()
        terminationSignal = source
    }

    private func resolveRuntime() throws -> NexCLIManagedRuntime {
        // Release builds package a compiled, signed NexCLI binary here. The
        // support location permits an updater to atomically replace it without
        // ever changing the LaunchAgent command line.
        if let bundled = Bundle.main.url(forResource: "nex", withExtension: nil, subdirectory: "NexCLI"), fileManager.isExecutableFile(atPath: bundled.path) {
            return .init(executable: bundled, arguments: ["serve"], description: "bundled NexCLI")
        }
        let installed = manager.supportDirectory.appendingPathComponent("runtime/nex")
        if fileManager.isExecutableFile(atPath: installed.path) {
            return .init(executable: installed, arguments: ["serve"], description: "managed NexCLI")
        }

        // Xcode/dev fallback: it is automatic and uses no terminal command,
        // while keeping production releases dependent only on their bundle.
        let sourceRoot = manager.supportDirectory
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Documents/nex-cli/packages/opencode/src/index.ts")
        let conventionalSource = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/nex-cli/packages/opencode/src/index.ts")
        let source = fileManager.fileExists(atPath: sourceRoot.path) ? sourceRoot : conventionalSource
        guard fileManager.fileExists(atPath: source.path), let bun = bunExecutable() else {
            throw NexusConnectError.unavailable("NexCLI runtime is not bundled with this build. Install a Nexus release that includes NexCLI.")
        }
        return .init(executable: bun, arguments: [source.path, "serve"], description: "local NexCLI development runtime")
    }

    private func bunExecutable() -> URL? {
        let candidates = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/bun"),
            URL(fileURLWithPath: "/opt/homebrew/bin/bun"),
            URL(fileURLWithPath: "/usr/local/bin/bun")
        ]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    private func startWorker(runtime: NexCLIManagedRuntime, password: String) throws {
        let process = Process()
        process.executableURL = runtime.executable
        process.arguments = runtime.arguments + ["--hostname", "127.0.0.1", "--port", "4096"]
        var environment = ProcessInfo.processInfo.environment
        environment["OPENCODE_SERVER_PASSWORD"] = password
        environment["OPENCODE_CONFIG_DIR"] = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nex", isDirectory: true).path
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
        process.standardOutput = FileHandle(forWritingAtPath: manager.standardOutputURL.path)
        process.standardError = FileHandle(forWritingAtPath: manager.standardErrorURL.path)
        try process.run()
        worker = process
    }

    private func monitorWorker(runtime: NexCLIManagedRuntime?, password: String) async {
        var activeRuntime = runtime
        for attempt in 0..<Int.max where !Task.isCancelled && !isStopping {
            if await workerResponds(password: password) {
                writeStatus(state: "ready", detail: nil, runtime: activeRuntime?.description ?? "managed Nex daemon")
            } else if worker?.isRunning == true {
                writeStatus(state: "starting", detail: "Starting local NexCLI…", runtime: activeRuntime?.description)
            } else if let activeRuntime {
                writeStatus(state: "restarting", detail: "Restarting local NexCLI…", runtime: activeRuntime.description)
                try? await Task.sleep(for: .seconds(min(20, max(1, attempt + 1))))
                guard !Task.isCancelled, !isStopping else { return }
                do { try startWorker(runtime: activeRuntime, password: password) }
                catch { writeStatus(state: "failed", detail: error.localizedDescription, runtime: activeRuntime.description) }
            } else {
                // This supervisor may have adopted an already-running managed
                // worker. If that worker exits, promote the supervisor into
                // the owner and restart it instead of waiting forever.
                do {
                    guard try acquireLock() else {
                        writeStatus(state: "starting", detail: "Waiting for the managed Nex daemon.", runtime: nil)
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                    activeRuntime = try resolveRuntime()
                    try startWorker(runtime: activeRuntime!, password: password)
                    writeStatus(state: "starting", detail: "Restarting local NexCLI…", runtime: activeRuntime?.description)
                } catch {
                    writeStatus(state: "failed", detail: error.localizedDescription, runtime: nil)
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func workerResponds(password: String) async -> Bool {
        await NexCLIHostManager.isHealthy(password: password)
    }

    private func acquireLock() throws -> Bool {
        try fileManager.createDirectory(at: manager.supportDirectory, withIntermediateDirectories: true)
        let descriptor = open(manager.lockURL.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        if descriptor >= 0 {
            let pid = "\(ProcessInfo.processInfo.processIdentifier)".data(using: .utf8)!
            _ = pid.withUnsafeBytes { write(descriptor, $0.baseAddress, pid.count) }
            close(descriptor)
            ownsLock = true
            return true
        }
        guard errno == EEXIST,
              let contents = try? String(contentsOf: manager.lockURL),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        if Darwin.kill(pid, 0) == 0 || errno == EPERM { return false }
        try? fileManager.removeItem(at: manager.lockURL)
        return try acquireLock()
    }

    private func releaseLock() {
        guard ownsLock else { return }
        try? fileManager.removeItem(at: manager.lockURL)
        ownsLock = false
    }

    private func writeStatus(state: String, detail: String?, runtime: String?) {
        let status = NexCLIHostStatus(
            processID: ProcessInfo.processInfo.processIdentifier,
            workerProcessID: worker?.processIdentifier ?? adoptedWorkerProcessID ?? 0,
            state: state,
            detail: detail,
            runtime: runtime,
            updatedAt: Date()
        )
        do {
            try fileManager.createDirectory(at: manager.supportDirectory, withIntermediateDirectories: true)
            try NexusPayloadCoder.encoder.encode(status).write(to: manager.statusURL, options: .atomic)
        } catch { NSLog("NexCLI host status write failed: %@", error.localizedDescription) }
    }
}
