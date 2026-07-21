import Foundation

/// Owns the workspace lifecycle for managed NexCLI tasks.  The model can
/// describe a build, but it never chooses where files are created.
@MainActor
final class NexCLIWorkspaceManager {
    static let shared = NexCLIWorkspaceManager()

    struct Workspace: Equatable, Sendable {
        let url: URL
        let displayName: String
    }

    private struct Manifest: Codable {
        static let schemaVersion = 1

        var schema = schemaVersion
        var currentRelativePath: String
        /// Keeps the Folder N sequence stable even after a completed folder is
        /// renamed to the user-facing build title.
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

    /// Called once per ordinary Nexus launch. A completed workspace is sealed
    /// until this point, so rebuilding/reopening the app never interrupts an
    /// in-flight task or silently moves its working directory.
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
        } else if let existing = manifest, existing.sealed {
            let (next, number) = try nextFolder(in: root, after: existing.folderNumber)
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

    /// A task seals the workspace only after the gateway reports actual file
    /// changes. The next app launch will then allocate the next empty Folder N.
    @discardableResult
    func completeBuild(title: String, filesChanged: [String]) throws -> Workspace {
        guard !filesChanged.isEmpty else { return try currentWorkspace() }
        let root = try prepareVaultRoot()
        guard var manifest = try loadManifest(root: root) else { return try prepareForNexusLaunch() }
        let current = try safeWorkspaceURL(relativePath: manifest.currentRelativePath, root: root)
        let suggestedName = folderName(from: title)
        let renamed = try renameIfNeeded(current, to: suggestedName, root: root)
        manifest.currentRelativePath = relativePath(for: renamed, root: root)
        manifest.displayName = renamed.lastPathComponent
        manifest.sealed = true
        manifest.updatedAt = .now
        try save(manifest, root: root)
        return .init(url: renamed, displayName: manifest.displayName)
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
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
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

    private func renameIfNeeded(_ current: URL, to suggestedName: String, root: URL) throws -> URL {
        guard current.lastPathComponent.hasPrefix("Folder "), suggestedName != current.lastPathComponent else { return current }
        let base = workspacesRoot(root)
        var candidate = base.appendingPathComponent(suggestedName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent("\(suggestedName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.moveItem(at: current, to: candidate)
        return candidate
    }

    private func safeWorkspaceURL(relativePath: String, root: URL) throws -> URL {
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
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
