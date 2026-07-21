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
    var standardOutputURL: URL { supportDirectory.appendingPathComponent("worker.log") }
    var standardErrorURL: URL { supportDirectory.appendingPathComponent("worker-error.log") }

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
        guard let data = try? Data(contentsOf: statusURL),
              let status = try? NexusPayloadCoder.decoder.decode(NexCLIHostStatus.self, from: data),
              status.isLive else { return nil }
        return status
    }

    func launchAgentPropertyList() -> Data {
        let propertyList: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executableURL.path, NexCLIHostProcess.argument],
            "EnvironmentVariables": [NexCLIHostProcess.environmentKey: "1"],
            "RunAtLoad": true,
            "KeepAlive": true,
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
    private var isStopping = false

    init(manager: NexCLIHostManager = .shared, fileManager: FileManager = .default) {
        self.manager = manager
        self.fileManager = fileManager
    }

    func start() async {
        do {
            let password = try NexCLILoopbackCredential.loadOrCreate()
            let runtime = try resolveRuntime()
            try startWorker(runtime: runtime, password: password)
            writeStatus(state: "starting", detail: nil, runtime: runtime.description)
            monitor = Task { [weak self] in await self?.monitorWorker(runtime: runtime, password: password) }
        } catch {
            writeStatus(state: "failed", detail: error.localizedDescription, runtime: nil)
        }
    }

    func stop() {
        isStopping = true
        monitor?.cancel()
        monitor = nil
        worker?.terminate()
        worker = nil
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
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
        process.standardOutput = FileHandle(forWritingAtPath: manager.standardOutputURL.path)
        process.standardError = FileHandle(forWritingAtPath: manager.standardErrorURL.path)
        try process.run()
        worker = process
    }

    private func monitorWorker(runtime: NexCLIManagedRuntime, password: String) async {
        for attempt in 0..<Int.max where !Task.isCancelled && !isStopping {
            if await workerResponds() {
                writeStatus(state: "ready", detail: nil, runtime: runtime.description)
            } else if worker?.isRunning == true {
                writeStatus(state: "starting", detail: "Starting local NexCLI…", runtime: runtime.description)
            } else {
                writeStatus(state: "restarting", detail: "Restarting local NexCLI…", runtime: runtime.description)
                try? await Task.sleep(for: .seconds(min(20, max(1, attempt + 1))))
                guard !Task.isCancelled, !isStopping else { return }
                do { try startWorker(runtime: runtime, password: password) }
                catch { writeStatus(state: "failed", detail: error.localizedDescription, runtime: runtime.description) }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func workerResponds() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:4096/global/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    private func writeStatus(state: String, detail: String?, runtime: String?) {
        let status = NexCLIHostStatus(
            processID: ProcessInfo.processInfo.processIdentifier,
            workerProcessID: worker?.processIdentifier ?? 0,
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
