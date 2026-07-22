import Foundation

/// Owns the workspace lifecycle for managed NexCLI tasks.  The model can
/// describe a build, but it never chooses where files are created.
@MainActor
final class NexCLIWorkspaceManager {
    static let shared = NexCLIWorkspaceManager()

    struct Workspace: Equatable, Sendable {
        let url: URL
        let displayName: String

        static func == (lhs: Workspace, rhs: Workspace) -> Bool {
            lhs.url.standardizedFileURL.path == rhs.url.standardizedFileURL.path
                && lhs.displayName == rhs.displayName
        }
    }

    private struct Manifest: Codable {
        static let schemaVersion = 1

        var schema = schemaVersion
        var currentRelativePath: String
        /// Retained so existing manifests stay decodable. New workspaces no
        /// longer rotate automatically after a task completes.
        var folderNumber: Int
        var sealed = false
        var displayName: String
        var updatedAt = Date()
    }

    private let fileManager: FileManager
    private let vaultURLProvider: () -> URL

    init(
        fileManager: FileManager = .default,
        vaultURLProvider: @escaping () -> URL = { NexVaultLocation.defaultURL() }
    ) {
        self.fileManager = fileManager
        self.vaultURLProvider = vaultURLProvider
    }

    /// Called once per ordinary Nexus launch. The selected workspace is
    /// intentionally persistent: restarting or rebuilding Nexus never moves
    /// an ongoing project into a new folder.
    func prepareForNexusLaunch() throws -> Workspace {
        let root = try prepareVaultRoot()
        var manifest = try loadManifest(root: root)
        if manifest == nil {
            let (next, number) = try nextFolder(in: root, after: 0)
            manifest = Manifest(
                currentRelativePath: relativePath(for: next, root: root),
                folderNumber: number,
                displayName: next.lastPathComponent
            )
        }
        guard var manifest else { throw NexCLIWorkspaceError.unavailable }
        let workspaceURL = try safeWorkspaceURL(relativePath: manifest.currentRelativePath, root: root)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        if manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            manifest.displayName = workspaceURL.lastPathComponent
        }
        manifest.updatedAt = .now
        try save(manifest, root: root)
        return .init(url: workspaceURL, displayName: manifest.displayName)
    }

    /// Returns the already-prepared workspace. This intentionally does not
    /// rotate it: only a subsequent Nexus launch may open a fresh folder.
    func currentWorkspace() throws -> Workspace {
        let root = try prepareVaultRoot()
        guard let manifest = try loadManifest(root: root) else {
            return try prepareForNexusLaunch()
        }
        let url = try safeWorkspaceURL(relativePath: manifest.currentRelativePath, root: root)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return .init(url: url, displayName: manifest.displayName)
    }

    /// A completed task stays in the active workspace. This preserves project
    /// context for follow-up tasks such as “continue” or “fix the last app”.
    @discardableResult
    func completeBuild(title: String, filesChanged: [String]) throws -> Workspace {
        _ = title
        _ = filesChanged
        return try currentWorkspace()
    }

    /// Changes the active workspace only after the user has explicitly asked
    /// Nex to do so through the registered `nex_cli_set_workspace` tool. The
    /// model supplies a display name; this service owns the vault-relative
    /// path and refuses every path outside the managed workspaces root.
    @discardableResult
    func setWorkspace(named requestedName: String) throws -> Workspace {
        let root = try prepareVaultRoot()
        let displayName = folderName(from: requestedName)
        let url = try safeWorkspaceURL(
            relativePath: "90 System/NexCLI Workspaces/\(displayName)",
            root: root
        )
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)

        let existing = try loadManifest(root: root)
        let folderNumber = existing?.folderNumber ?? 1
        try save(
            .init(
                currentRelativePath: relativePath(for: url, root: root),
                folderNumber: folderNumber,
                sealed: false,
                displayName: displayName,
                updatedAt: .now
            ),
            root: root
        )
        return .init(url: url, displayName: displayName)
    }

    private func prepareVaultRoot() throws -> URL {
        let root = vaultURLProvider().standardizedFileURL.resolvingSymlinksInPath()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workspacesRoot(root), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: manifestURL(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        return root
    }

    private func workspacesRoot(_ root: URL) -> URL {
        root.appendingPathComponent("90 System/NexCLI Workspaces", isDirectory: true)
    }

    private func manifestURL(_ root: URL) -> URL {
        root.appendingPathComponent(".nex/nex-cli-workspace.json")
    }

    private func loadManifest(root: URL) throws -> Manifest? {
        let url = manifestURL(root)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        // `save` deliberately emits an iCloud-friendly ISO-8601 timestamp.
        // The default decoder expects a numeric timestamp, which made every
        // existing workspace manifest look malformed after the first launch.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.schema == Manifest.schemaVersion else {
            throw NexCLIWorkspaceError.unsupportedSchema(manifest.schema)
        }
        return manifest
    }

    private func save(_ manifest: Manifest, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL(root), options: .atomic)
    }

    private func nextFolder(in root: URL, after sequence: Int) throws -> (URL, Int) {
        let base = workspacesRoot(root)
        let existing = (try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        let highest = existing.compactMap { url -> Int? in
            let name = url.lastPathComponent
            guard name.hasPrefix("Folder "), let number = Int(name.dropFirst("Folder ".count)) else { return nil }
            return number
        }.max() ?? 0
        var number = max(highest, sequence) + 1
        var candidate = base.appendingPathComponent("Folder \(number)", isDirectory: true)
        while fileManager.fileExists(atPath: candidate.path) {
            number += 1
            candidate = base.appendingPathComponent("Folder \(number)", isDirectory: true)
        }
        return (candidate, number)
    }

    private func safeWorkspaceURL(relativePath: String, root: URL) throws -> URL {
        // Normalize away NSURL's directory-marker slash. The manifest stores
        // paths, while newly created directories can otherwise return a URL
        // with a trailing slash; those two URLs compare unequal even though
        // they identify the same workspace.
        let candidate = URL(fileURLWithPath: root.appendingPathComponent(relativePath).path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let base = workspacesRoot(root).standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate.path == base || candidate.path.hasPrefix(base + "/") else { throw NexCLIWorkspaceError.unsafePath }
        return candidate
    }

    private func relativePath(for url: URL, root: URL) -> String {
        String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func folderName(from title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let filtered = title.unicodeScalars.map { allowed.contains($0) ? String($0) : " " }.joined()
        let compact = filtered
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(compact.prefix(56))
        return prefix.isEmpty || prefix.localizedCaseInsensitiveCompare("Nex task") == .orderedSame ? "Nex Build" : prefix
    }
}

enum NexCLIWorkspaceError: LocalizedError, Equatable {
    case unavailable
    case unsafePath
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Nex could not prepare its coding workspace."
        case .unsafePath: "Nex refused an unsafe coding workspace path."
        case .unsupportedSchema(let schema): "NexCLI workspace schema \(schema) is not supported."
        }
    }
}
