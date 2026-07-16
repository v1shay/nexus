import Darwin
import Foundation

enum NexusConnectHostProcess {
    static let argument = "--nexus-connect-host"
    static var isCurrentProcess: Bool { CommandLine.arguments.contains(argument) }
}

struct NexusConnectHostStatus: Codable, Equatable, Sendable {
    let processID: Int32
    let nodeID: UUID
    let state: String
    let detail: String?
    let appVersion: String
    let protocolRange: NexusProtocolVersionRange
    let updatedAt: Date

    var isLive: Bool {
        guard processID > 0, Date().timeIntervalSince(updatedAt) < 20 else { return false }
        return Darwin.kill(processID, 0) == 0 || errno == EPERM
    }
}

protocol NexusPersistentHostManaging: Sendable {
    func installAndStart() throws
    func currentStatus() -> NexusConnectHostStatus?
}

/// Installs the signed Nexus executable as a per-user LaunchAgent. The agent is
/// a separate process in `--nexus-connect-host` mode, so closing the notch UI
/// cannot stop listeners or host-side model downloads.
struct NexusConnectHostManager: NexusPersistentHostManaging, @unchecked Sendable {
    static let label = "na.nexus.connect-host"

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
        self.processRunner = processRunner ?? { executable, arguments in
            try Self.run(executable, arguments)
        }
    }

    var launchAgentURL: URL {
        homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    var supportDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Application Support/Nexus/ConnectHost", isDirectory: true)
    }

    var statusURL: URL { supportDirectory.appendingPathComponent("status.json") }
    var standardOutputURL: URL { supportDirectory.appendingPathComponent("host.log") }
    var standardErrorURL: URL { supportDirectory.appendingPathComponent("host-error.log") }

    func installAndStart() throws {
        guard !NexusConnectHostProcess.isCurrentProcess else { return }
        // Never restart a healthy helper merely because the visible app was
        // rebuilt. It may own a multi-hour model pull.
        if currentStatus() != nil { return }
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let expected = launchAgentPropertyList()
        let current = try? Data(contentsOf: launchAgentURL)
        if current != expected {
            if fileManager.fileExists(atPath: launchAgentURL.path) {
                try? processRunner(URL(fileURLWithPath: "/bin/launchctl"), [
                    "bootout", "gui/\(getuid())/\(Self.label)"
                ])
            }
            try expected.write(to: launchAgentURL, options: .atomic)
            try processRunner(URL(fileURLWithPath: "/bin/launchctl"), [
                "bootstrap", "gui/\(getuid())", launchAgentURL.path
            ])
        }
        try processRunner(URL(fileURLWithPath: "/bin/launchctl"), [
            "kickstart", "-k", "gui/\(getuid())/\(Self.label)"
        ])
    }

    func currentStatus() -> NexusConnectHostStatus? {
        guard let data = try? Data(contentsOf: statusURL),
              let status = try? NexusPayloadCoder.decoder.decode(NexusConnectHostStatus.self, from: data),
              status.isLive else { return nil }
        return status
    }

    func launchAgentPropertyList() -> Data {
        let propertyList: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executableURL.path, NexusConnectHostProcess.argument],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 5,
            "StandardOutPath": standardOutputURL.path,
            "StandardErrorPath": standardErrorURL.path
        ]
        return (try? PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )) ?? Data()
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
            throw NexusConnectError.unavailable(
                "launchctl failed for \(arguments.first ?? executable.lastPathComponent) (\(process.terminationStatus))"
            )
        }
    }
}

/// The persistent host has one narrow responsibility: own the Connect listener
/// and host services. It does not create windows, agents, plans, or workflows.
@MainActor
final class NexusConnectHostDaemon {
    private let manager: NexusConnectHostManager
    private let vault: NexusIdentityVault
    private var listener: NexusConnectHostListener?
    private var heartbeat: Task<Void, Never>?

    init(
        manager: NexusConnectHostManager = NexusConnectHostManager(),
        secretStore: NexusSecretStore = NexusKeychainSecretStore()
    ) {
        self.manager = manager
        vault = NexusIdentityVault(store: secretStore, role: .studioHost)
    }

    func start() async {
        do {
            let identity = try vault.loadOrCreateIdentity()
            let executor = NexusHostServiceExecutor(
                nodeID: identity.deviceID,
                nodeName: Host.current().localizedName ?? "Nexus Host"
            )
            let listener = NexusConnectHostListener(vault: vault, executor: executor)
            self.listener = listener
            writeStatus(nodeID: identity.deviceID, state: "starting", detail: nil)
            try await listener.start()
            writeStatus(nodeID: identity.deviceID, state: "ready", detail: nil)
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    self?.writeStatus(nodeID: identity.deviceID, state: "ready", detail: nil)
                }
            }
        } catch {
            let nodeID = (try? vault.loadOrCreateIdentity().deviceID) ?? UUID()
            writeStatus(nodeID: nodeID, state: "failed", detail: error.localizedDescription)
            NSLog("NexusConnectHost failed: %@", error.localizedDescription)
        }
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        listener?.stop()
        listener = nil
    }

    private func writeStatus(nodeID: UUID, state: String, detail: String?) {
        let status = NexusConnectHostStatus(
            processID: ProcessInfo.processInfo.processIdentifier,
            nodeID: nodeID,
            state: state,
            detail: detail,
            appVersion: NexusAppMetadata.version,
            protocolRange: .local,
            updatedAt: Date()
        )
        do {
            try FileManager.default.createDirectory(
                at: manager.supportDirectory,
                withIntermediateDirectories: true
            )
            try NexusPayloadCoder.encoder.encode(status).write(to: manager.statusURL, options: .atomic)
        } catch {
            NSLog("NexusConnectHost status write failed: %@", error.localizedDescription)
        }
    }
}
