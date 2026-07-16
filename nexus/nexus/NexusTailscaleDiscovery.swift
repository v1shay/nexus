import Foundation

struct NexusCommandResult: Equatable, Sendable {
    let standardOutput: Data
    let standardError: Data
    let exitCode: Int32

    var outputString: String { String(decoding: standardOutput, as: UTF8.self) }
    var errorString: String { String(decoding: standardError, as: UTF8.self) }
}

protocol NexusCommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        timeoutSeconds: TimeInterval,
        maximumOutputBytes: Int
    ) async throws -> NexusCommandResult
}

extension NexusCommandRunning {
    func run(
        executable: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        maximumOutputBytes: Int
    ) async throws -> NexusCommandResult {
        try await run(
            executable: executable,
            arguments: arguments,
            environment: nil,
            workingDirectory: nil,
            timeoutSeconds: timeoutSeconds,
            maximumOutputBytes: maximumOutputBytes
        )
    }
}

final class NexusFoundationCommandRunner: NexusCommandRunning, @unchecked Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeoutSeconds: TimeInterval = 10,
        maximumOutputBytes: Int = 4 * 1_024 * 1_024
    ) async throws -> NexusCommandResult {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NexusConnectError.unavailable("missing executable at \(executable.path)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let capture = NexusCommandCapture(
                process: process,
                maximumOutputBytes: maximumOutputBytes,
                continuation: continuation
            )

            process.executableURL = executable
            process.arguments = arguments
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, supplied in supplied }
            }
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                capture.append(handle.availableData, isError: false)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                capture.append(handle.availableData, isError: true)
            }
            process.terminationHandler = { process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                capture.append(outputPipe.fileHandleForReading.readDataToEndOfFile(), isError: false)
                capture.append(errorPipe.fileHandleForReading.readDataToEndOfFile(), isError: true)
                capture.finish(exitCode: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                capture.fail(error)
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                capture.timeoutIfRunning()
            }
        }
    }
}

private final class NexusCommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let maximumOutputBytes: Int
    private var continuation: CheckedContinuation<NexusCommandResult, Error>?
    private var output = Data()
    private var errorOutput = Data()
    private var exceededLimit = false

    init(
        process: Process,
        maximumOutputBytes: Int,
        continuation: CheckedContinuation<NexusCommandResult, Error>
    ) {
        self.process = process
        self.maximumOutputBytes = maximumOutputBytes
        self.continuation = continuation
    }

    func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard continuation != nil, !exceededLimit else { return }
        let available = maximumOutputBytes - output.count - errorOutput.count
        guard available > 0 else {
            exceededLimit = true
            process.terminate()
            return
        }
        if isError {
            errorOutput.append(data.prefix(available))
        } else {
            output.append(data.prefix(available))
        }
        if data.count > available {
            exceededLimit = true
            process.terminate()
        }
    }

    func finish(exitCode: Int32) {
        let result: Result<NexusCommandResult, Error>
        lock.lock()
        guard let savedContinuation = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        if exceededLimit {
            result = .failure(NexusConnectError.requestFailed("command output exceeded its limit"))
        } else {
            result = .success(.init(standardOutput: output, standardError: errorOutput, exitCode: exitCode))
        }
        lock.unlock()
        savedContinuation.resume(with: result)
    }

    func fail(_ error: Error) {
        lock.lock()
        guard let savedContinuation = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()
        savedContinuation.resume(throwing: error)
    }

    func timeoutIfRunning() {
        lock.lock()
        let shouldTerminate = continuation != nil && process.isRunning
        lock.unlock()
        if shouldTerminate {
            process.terminate()
            fail(NexusConnectError.unavailable("Tailscale command timed out"))
        }
    }
}

struct NexusTailscalePeer: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let nodeKey: String
    let hostName: String
    let dnsName: String
    let operatingSystem: String
    let addresses: [String]
    let online: Bool
    let active: Bool
    let relayRegion: String?
    let currentEndpoint: String?
    let receivedBytes: UInt64
    let transmittedBytes: UInt64

    var connectionHost: String {
        let trimmedDNS = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
        return trimmedDNS.isEmpty ? (addresses.first ?? hostName) : trimmedDNS
    }
}

struct NexusTailscaleSnapshot: Equatable, Sendable {
    let backendState: String
    let localNodeName: String
    let peers: [NexusTailscalePeer]
}

struct NexusTailscaleRouteSample: Equatable, Sendable {
    let route: NexusConnectionRoute
    let roundTripMilliseconds: Double?
    let description: String
}

protocol NexusStudioDiscovering: Sendable {
    func discoverStudio(preferredNodeID: String?) async throws -> NexusTailscalePeer
    func routeSample(to peer: NexusTailscalePeer) async throws -> NexusTailscaleRouteSample
}

protocol NexusNodeDiscovering: Sendable {
    func snapshot() async throws -> NexusTailscaleSnapshot
    func routeSample(to peer: NexusTailscalePeer) async throws -> NexusTailscaleRouteSample
}

struct NexusTailscaleDiscovery: NexusStudioDiscovering, Sendable {
    private let runner: any NexusCommandRunning
    private let executableOverride: URL?

    init(runner: any NexusCommandRunning = NexusFoundationCommandRunner(), executableOverride: URL? = nil) {
        self.runner = runner
        self.executableOverride = executableOverride
    }

    func snapshot() async throws -> NexusTailscaleSnapshot {
        let result = try await runner.run(
            executable: try executableURL(),
            arguments: ["status", "--json"],
            timeoutSeconds: 8,
            maximumOutputBytes: 4 * 1_024 * 1_024
        )
        guard result.exitCode == 0 else {
            throw NexusConnectError.unavailable(result.errorString.nonEmpty ?? "Tailscale is not connected")
        }
        let status: TailscaleStatus
        do {
            status = try JSONDecoder().decode(TailscaleStatus.self, from: result.standardOutput)
        } catch {
            throw NexusConnectError.unavailable("Tailscale returned an unreadable status")
        }
        let peers = status.peers.map { nodeKey, peer in
            NexusTailscalePeer(
                id: peer.id.nonEmpty ?? nodeKey,
                nodeKey: nodeKey,
                hostName: peer.hostName,
                dnsName: peer.dnsName,
                operatingSystem: peer.operatingSystem,
                addresses: peer.addresses,
                online: peer.online,
                active: peer.active,
                relayRegion: peer.relayRegion.nonEmpty,
                currentEndpoint: peer.currentEndpoint.nonEmpty,
                receivedBytes: peer.receivedBytes,
                transmittedBytes: peer.transmittedBytes
            )
        }
        return NexusTailscaleSnapshot(
            backendState: status.backendState,
            localNodeName: status.localNode?.hostName ?? "",
            peers: peers.sorted { $0.hostName.localizedCaseInsensitiveCompare($1.hostName) == .orderedAscending }
        )
    }

    func discoverStudio(preferredNodeID: String? = nil) async throws -> NexusTailscalePeer {
        let status = try await snapshot()
        guard status.backendState.caseInsensitiveCompare("Running") == .orderedSame else {
            throw NexusConnectError.unavailable("Tailscale backend is \(status.backendState)")
        }
        let candidates = status.peers.filter {
            $0.online && ($0.operatingSystem.caseInsensitiveCompare("macOS") == .orderedSame ||
                          $0.operatingSystem.caseInsensitiveCompare("darwin") == .orderedSame)
        }
        guard let selected = candidates.max(by: {
            score($0, preferredNodeID: preferredNodeID) < score($1, preferredNodeID: preferredNodeID)
        }) else {
            throw NexusConnectError.unavailable("no online paired Mac was found on this tailnet")
        }
        return selected
    }

    func routeSample(to peer: NexusTailscalePeer) async throws -> NexusTailscaleRouteSample {
        let result = try await runner.run(
            executable: try executableURL(),
            arguments: ["ping", "--c", "3", "--timeout", "3s", peer.connectionHost],
            timeoutSeconds: 12,
            maximumOutputBytes: 64 * 1_024
        )
        let combined = result.outputString + "\n" + result.errorString
        guard result.exitCode == 0 else {
            throw NexusConnectError.unavailable(combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Self.parsePingOutput(combined)
    }

    static func parsePingOutput(_ output: String) -> NexusTailscaleRouteSample {
        let lower = output.lowercased()
        let route: NexusConnectionRoute
        if lower.contains("peer-relay") {
            route = .peerRelay
        } else if lower.contains("derp(") || lower.contains("via derp") {
            route = .derp
        } else if lower.contains("via ") && lower.contains(":") {
            route = .direct
        } else {
            route = .unknown
        }
        let values = matches(pattern: #"(?:in|time[=<])\s*([0-9]+(?:\.[0-9]+)?)\s*ms"#, in: lower)
            .compactMap(Double.init)
        let rtt = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        return .init(route: route, roundTripMilliseconds: rtt, description: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func executableURL() throws -> URL {
        if let executableOverride { return executableOverride }
        let candidates = [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ].map(URL.init(fileURLWithPath:))
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw NexusConnectError.unavailable("Tailscale is installed but its command-line client could not be found")
        }
        return executable
    }

    private func score(_ peer: NexusTailscalePeer, preferredNodeID: String?) -> Int {
        var result = 0
        if preferredNodeID == peer.id || preferredNodeID == peer.nodeKey { result += 10_000 }
        let name = "\(peer.hostName) \(peer.dnsName)".lowercased()
        if name.contains("mac studio") || name.contains("mac-studio") { result += 1_000 }
        if peer.active { result += 100 }
        if peer.currentEndpoint?.isEmpty == false { result += 25 }
        return result
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }
}

extension NexusTailscaleDiscovery: NexusNodeDiscovering {}

extension NexusTailscaleSnapshot {
    func exactPeer(for node: NexusPairedNode) throws -> NexusTailscalePeer {
        guard backendState.caseInsensitiveCompare("Running") == .orderedSame else {
            throw NexusConnectError.unavailable("Tailscale backend is \(backendState)")
        }
        let expectedEndpoint = node.endpoint.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let peer = peers.first { peer in
            let dns = peer.dnsName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let identityMatches = node.tailscaleNodeID.map {
                $0 == peer.id || $0 == peer.nodeKey
            } ?? false
            let endpointMatches = !expectedEndpoint.isEmpty && (
                dns == expectedEndpoint ||
                peer.hostName.lowercased() == expectedEndpoint ||
                peer.addresses.contains(expectedEndpoint)
            )
            return identityMatches || endpointMatches
        }
        guard let peer else {
            throw NexusConnectError.unavailable("\(node.displayName) is not installed or is not visible on this tailnet")
        }
        guard peer.online else {
            throw NexusConnectError.unavailable("\(node.displayName) is powered off, sleeping, or offline")
        }
        return peer
    }
}

private struct TailscaleStatus: Decodable {
    let backendState: String
    let localNode: TailscaleNode?
    let peers: [String: TailscaleNode]

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case localNode = "Self"
        case peers = "Peer"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backendState = try container.decodeIfPresent(String.self, forKey: .backendState) ?? "Unknown"
        localNode = try container.decodeIfPresent(TailscaleNode.self, forKey: .localNode)
        peers = try container.decodeIfPresent([String: TailscaleNode].self, forKey: .peers) ?? [:]
    }
}

private struct TailscaleNode: Decodable {
    let id: String
    let hostName: String
    let dnsName: String
    let operatingSystem: String
    let addresses: [String]
    let online: Bool
    let active: Bool
    let relayRegion: String
    let currentEndpoint: String
    let receivedBytes: UInt64
    let transmittedBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case hostName = "HostName"
        case dnsName = "DNSName"
        case operatingSystem = "OS"
        case addresses = "TailscaleIPs"
        case online = "Online"
        case active = "Active"
        case relayRegion = "Relay"
        case currentEndpoint = "CurAddr"
        case receivedBytes = "RxBytes"
        case transmittedBytes = "TxBytes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName) ?? ""
        dnsName = try container.decodeIfPresent(String.self, forKey: .dnsName) ?? ""
        operatingSystem = try container.decodeIfPresent(String.self, forKey: .operatingSystem) ?? ""
        addresses = try container.decodeIfPresent([String].self, forKey: .addresses) ?? []
        online = try container.decodeIfPresent(Bool.self, forKey: .online) ?? false
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        relayRegion = try container.decodeIfPresent(String.self, forKey: .relayRegion) ?? ""
        currentEndpoint = try container.decodeIfPresent(String.self, forKey: .currentEndpoint) ?? ""
        receivedBytes = try container.decodeIfPresent(UInt64.self, forKey: .receivedBytes) ?? 0
        transmittedBytes = try container.decodeIfPresent(UInt64.self, forKey: .transmittedBytes) ?? 0
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
