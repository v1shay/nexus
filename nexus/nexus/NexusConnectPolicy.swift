import Foundation

struct NexusExecutableRule: Equatable, Sendable {
    let executableURL: URL
    let maximumArgumentCount: Int
    let allowedEnvironmentKeys: Set<String>
    let requiresApproval: Bool

    init(
        executableURL: URL,
        maximumArgumentCount: Int = 128,
        allowedEnvironmentKeys: Set<String> = [],
        requiresApproval: Bool = true
    ) {
        self.executableURL = executableURL
        self.maximumArgumentCount = maximumArgumentCount
        self.allowedEnvironmentKeys = allowedEnvironmentKeys
        self.requiresApproval = requiresApproval
    }
}

struct NexusExecutionPolicy: Sendable {
    let allowedCapabilities: Set<NexusCapability>
    let roots: [String: URL]
    let executables: [String: NexusExecutableRule]
    let maximumTimeoutSeconds: Double
    let maximumOutputBytes: Int

    init(
        allowedCapabilities: Set<NexusCapability>,
        roots: [String: URL],
        executables: [String: NexusExecutableRule],
        maximumTimeoutSeconds: Double = 600,
        maximumOutputBytes: Int = 32 * 1_024 * 1_024
    ) {
        self.allowedCapabilities = allowedCapabilities
        self.roots = roots
        self.executables = executables
        self.maximumTimeoutSeconds = maximumTimeoutSeconds
        self.maximumOutputBytes = maximumOutputBytes
    }

    static func defaultStudioPolicy(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> NexusExecutionPolicy {
        let roots = [
            "home": homeDirectory,
            "downloads": homeDirectory.appendingPathComponent("Downloads", isDirectory: true),
            "nexus": homeDirectory.appendingPathComponent("Nexus", isDirectory: true)
        ]
        let executables: [String: NexusExecutableRule] = [
            "git": .init(executableURL: URL(fileURLWithPath: "/usr/bin/git")),
            "swift": .init(executableURL: URL(fileURLWithPath: "/usr/bin/swift")),
            "xcodebuild": .init(executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild")),
            "python3": .init(executableURL: URL(fileURLWithPath: "/usr/bin/python3")),
            "rg": .init(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/rg"))
        ]
        return NexusExecutionPolicy(
            allowedCapabilities: Set(NexusCapability.allCases),
            roots: roots,
            executables: executables
        )
    }

    func require(_ capability: NexusCapability) throws {
        guard allowedCapabilities.contains(capability) else {
            throw NexusConnectError.policyDenied("\(capability.rawValue) is disabled")
        }
    }

    func resolve(_ reference: NexusFileReference) throws -> URL {
        guard let root = roots[reference.rootID],
              !reference.relativePath.hasPrefix("/"),
              !reference.relativePath.contains("\0"),
              !reference.relativePath.split(separator: "/").contains("..") else {
            throw NexusConnectError.pathOutsideAllowedRoots
        }
        let lexicalRoot = root.standardizedFileURL
        let lexicalCandidate = root
            .appendingPathComponent(reference.relativePath)
            .standardizedFileURL

        // Check the lexical path first, then resolve the nearest existing ancestor.
        // `URL.resolvingSymlinksInPath()` alone does not follow a symlink when a
        // requested child does not exist yet (a common write/create operation).
        guard contains(lexicalCandidate, in: lexicalRoot) else {
            throw NexusConnectError.pathOutsideAllowedRoots
        }

        let canonicalRoot = canonicalizingExistingAncestors(of: lexicalRoot)
        let canonicalCandidate = canonicalizingExistingAncestors(of: lexicalCandidate)
        guard contains(canonicalCandidate, in: canonicalRoot) else {
            throw NexusConnectError.pathOutsideAllowedRoots
        }
        return canonicalCandidate
    }

    func validateProcess(_ payload: NexusProcessPayload, approvalTokenIsValid: Bool) throws -> NexusExecutableRule {
        try require(.process)
        guard let rule = executables[payload.executableID] else {
            throw NexusConnectError.policyDenied("unknown executable ID")
        }
        let forbiddenShells = ["sh", "zsh", "bash", "fish", "dash"]
        guard !forbiddenShells.contains(payload.executableID.lowercased()),
              !forbiddenShells.contains(rule.executableURL.lastPathComponent.lowercased()) else {
            throw NexusConnectError.policyDenied("shell interpreters are not available")
        }
        guard payload.arguments.count <= rule.maximumArgumentCount else {
            throw NexusConnectError.policyDenied("too many process arguments")
        }
        guard Set(payload.environment.keys).isSubset(of: rule.allowedEnvironmentKeys) else {
            throw NexusConnectError.policyDenied("environment key is not allowed")
        }
        guard payload.timeoutSeconds > 0, payload.timeoutSeconds <= maximumTimeoutSeconds else {
            throw NexusConnectError.policyDenied("timeout exceeds the configured limit")
        }
        guard payload.maximumOutputBytes > 0, payload.maximumOutputBytes <= maximumOutputBytes else {
            throw NexusConnectError.policyDenied("output limit exceeds the configured limit")
        }
        if rule.requiresApproval, !approvalTokenIsValid {
            throw NexusConnectError.policyDenied("interactive approval is required")
        }
        if let directory = payload.workingDirectory { _ = try resolve(directory) }
        return rule
    }

    private func canonicalizingExistingAncestors(of url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missingComponents: [String] = []

        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { break }
            missingComponents.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }

        var resolved = existing.resolvingSymlinksInPath()
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }
}
