import AppKit
import Foundation

enum NexFinderCollisionPolicy: String, Codable, Sendable {
    case error
    case replace
    /// `overwrite` is the conventional user-facing term for the existing
    /// replace behavior.  It remains confirmation-gated and never removes a
    /// nonempty directory, but accepting it keeps native function calls from
    /// being discarded solely for choosing a natural synonym.
    case overwrite
    case keepBoth = "keep_both"
}

enum NexFinderError: LocalizedError, Equatable {
    case pathOutsideAllowedRoots(String)
    case missingPath(String)
    case invalidDirectory(String)
    case invalidName(String)
    case collision(String)
    case unsupportedFile(String)
    case finderUnavailable
    case appleScript(String)

    var errorDescription: String? {
        switch self {
        case .pathOutsideAllowedRoots(let path): "The path is outside Nexus's allowed file roots: \(path)."
        case .missingPath(let path): "The path does not exist: \(path)."
        case .invalidDirectory(let path): "A valid directory is required: \(path)."
        case .invalidName(let name): "The file or folder name is invalid: \(name)."
        case .collision(let path): "A file already exists at \(path). Choose an explicit collision policy."
        case .unsupportedFile(let path): "The file cannot be searched as text: \(path)."
        case .finderUnavailable: "Finder is unavailable."
        case .appleScript(let message): "Finder automation failed: \(message)"
        }
    }
}

struct NexFinderSearchRequest: Sendable {
    let rootPath: String
    let nameContains: String?
    let fileExtension: String?
    let contentContains: String?
    let modifiedAfter: Date?
    let modifiedBefore: Date?
    let minimumSize: Int64?
    let maximumSize: Int64?
    let limit: Int
}

actor NexFinderFileService {
    private let allowedRoots: [URL]
    private let trashDirectoryOverride: URL?
    private let fileManager = FileManager.default

    init(allowedRoots: [URL]? = nil, trashDirectoryOverride: URL? = nil) {
        let manager = FileManager.default
        self.allowedRoots = allowedRoots ?? [
            manager.homeDirectoryForCurrentUser,
            manager.temporaryDirectory,
            URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        ]
        self.trashDirectoryOverride = trashDirectoryOverride
    }

    func search(_ request: NexFinderSearchRequest) throws -> [URL] {
        let root = try existingURL(request.rootPath, requireDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var matches: [URL] = []
        while let raw = enumerator.nextObject() as? URL, matches.count < min(max(request.limit, 1), 200) {
            let values = try? raw.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                let resolved = raw.resolvingSymlinksInPath().standardizedFileURL
                guard containsAllowed(resolved) else {
                    enumerator.skipDescendants()
                    continue
                }
            }
            guard let candidate = try? existingURL(raw.path), matchesRequest(candidate, values: values, request: request) else { continue }
            matches.append(candidate)
        }
        return matches.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func createFolder(parentPath: String, name: String, collisionPolicy: NexFinderCollisionPolicy) throws -> URL {
        try validateName(name)
        let parent = try existingURL(parentPath, requireDirectory: true)
        let destination = try destinationURL(parent.appendingPathComponent(name, isDirectory: true))
        let resolved = try resolveCollision(destination, policy: collisionPolicy, isDirectory: true)
        if !fileManager.fileExists(atPath: resolved.path) {
            try fileManager.createDirectory(at: resolved, withIntermediateDirectories: false)
        }
        return resolved
    }

    func copy(sourcePath: String, destinationDirectory: String, collisionPolicy: NexFinderCollisionPolicy) throws -> URL {
        let source = try existingURL(sourcePath)
        let directory = try existingURL(destinationDirectory, requireDirectory: true)
        let proposed = try destinationURL(directory.appendingPathComponent(source.lastPathComponent))
        let destination = try resolveCollision(proposed, policy: collisionPolicy, isDirectory: source.hasDirectoryPath)
        if source != destination { try fileManager.copyItem(at: source, to: destination) }
        return destination
    }

    func move(sourcePath: String, destinationDirectory: String, collisionPolicy: NexFinderCollisionPolicy) throws -> URL {
        let source = try existingURL(sourcePath)
        let directory = try existingURL(destinationDirectory, requireDirectory: true)
        let proposed = try destinationURL(directory.appendingPathComponent(source.lastPathComponent))
        let destination = try resolveCollision(proposed, policy: collisionPolicy, isDirectory: source.hasDirectoryPath)
        if source != destination { try fileManager.moveItem(at: source, to: destination) }
        return destination
    }

    func rename(path: String, newName: String, collisionPolicy: NexFinderCollisionPolicy) throws -> URL {
        try validateName(newName)
        let source = try existingURL(path)
        let proposed = try destinationURL(source.deletingLastPathComponent().appendingPathComponent(newName))
        let destination = try resolveCollision(proposed, policy: collisionPolicy, isDirectory: source.hasDirectoryPath)
        if source != destination { try fileManager.moveItem(at: source, to: destination) }
        return destination
    }

    func trash(path: String) throws -> URL {
        let source = try existingURL(path)
        if let trashDirectoryOverride {
            let directory = try existingURL(trashDirectoryOverride.path, requireDirectory: true)
            let proposed = try destinationURL(directory.appendingPathComponent(source.lastPathComponent))
            let destination = try resolveCollision(proposed, policy: .keepBoth, isDirectory: source.hasDirectoryPath)
            try fileManager.moveItem(at: source, to: destination)
            return destination
        }
        var resultingURL: NSURL?
        try fileManager.trashItem(at: source, resultingItemURL: &resultingURL)
        return (resultingURL as URL?) ?? source
    }

    func validatedExistingURL(path: String) throws -> URL { try existingURL(path) }

    private func matchesRequest(
        _ url: URL,
        values: URLResourceValues?,
        request: NexFinderSearchRequest
    ) -> Bool {
        if let query = request.nameContains?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
           !url.lastPathComponent.localizedCaseInsensitiveContains(query) { return false }
        if let requestedExtension = request.fileExtension?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased(),
           !requestedExtension.isEmpty, url.pathExtension.lowercased() != requestedExtension { return false }
        if let after = request.modifiedAfter, (values?.contentModificationDate ?? .distantPast) < after { return false }
        if let before = request.modifiedBefore, (values?.contentModificationDate ?? .distantFuture) > before { return false }
        if let minimum = request.minimumSize, Int64(values?.fileSize ?? 0) < minimum { return false }
        if let maximum = request.maximumSize, Int64(values?.fileSize ?? 0) > maximum { return false }
        if let content = request.contentContains, !content.isEmpty {
            guard values?.isRegularFile == true,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count <= 2_000_000,
                  let text = String(data: data, encoding: .utf8),
                  text.localizedCaseInsensitiveContains(content) else { return false }
        }
        return true
    }

    private func existingURL(_ path: String, requireDirectory: Bool = false) throws -> URL {
        let lexical = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: lexical.path, isDirectory: &isDirectory) else { throw NexFinderError.missingPath(path) }
        guard !requireDirectory || isDirectory.boolValue else { throw NexFinderError.invalidDirectory(path) }
        let resolved = lexical.resolvingSymlinksInPath().standardizedFileURL
        guard containsAllowed(resolved) else { throw NexFinderError.pathOutsideAllowedRoots(path) }
        return resolved
    }

    private func destinationURL(_ url: URL) throws -> URL {
        let parent = try existingURL(url.deletingLastPathComponent().path, requireDirectory: true)
        let destination = parent.appendingPathComponent(url.lastPathComponent, isDirectory: url.hasDirectoryPath).standardizedFileURL
        guard containsAllowed(destination) else { throw NexFinderError.pathOutsideAllowedRoots(url.path) }
        return destination
    }

    private func resolveCollision(_ destination: URL, policy: NexFinderCollisionPolicy, isDirectory: Bool) throws -> URL {
        guard fileManager.fileExists(atPath: destination.path) else { return destination }
        switch policy {
        case .error: throw NexFinderError.collision(destination.path)
        case .replace, .overwrite:
            var existingIsDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: destination.path, isDirectory: &existingIsDirectory), existingIsDirectory.boolValue,
               !(try fileManager.contentsOfDirectory(atPath: destination.path)).isEmpty {
                throw NexFinderError.collision(destination.path)
            }
            try fileManager.removeItem(at: destination)
            return destination
        case .keepBoth:
            let stem = destination.deletingPathExtension().lastPathComponent
            let pathExtension = destination.pathExtension
            let parent = destination.deletingLastPathComponent()
            for suffix in 2...10_000 {
                let filename = pathExtension.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(pathExtension)"
                let candidate = parent.appendingPathComponent(filename, isDirectory: isDirectory)
                if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
            throw NexFinderError.collision(destination.path)
        }
    }

    private func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains("\0") else {
            throw NexFinderError.invalidName(name)
        }
    }

    private func containsAllowed(_ url: URL) -> Bool {
        allowedRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }.contains { root in
            url.path == root.path || url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
        }
    }
}

final class NexFinderApplicationController: @unchecked Sendable {
    func openFinder() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else { throw NexFinderError.finderUnavailable }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func selection() throws -> [String] {
        var error: NSDictionary?
        let result = NSAppleScript(source: """
        tell application "Finder"
            set selectedItems to selection
            set output to ""
            repeat with selectedItem in selectedItems
                set output to output & POSIX path of (selectedItem as alias) & linefeed
            end repeat
            return output
        end tell
        """)?.executeAndReturnError(&error)
        if let error { throw NexFinderError.appleScript(error[NSAppleScript.errorMessage] as? String ?? error.description) }
        return (result?.stringValue ?? "").split(whereSeparator: { $0.isNewline }).map(String.init)
    }
}

actor NexFinderActionCatalog {
    private let files: NexFinderFileService
    private let application: NexFinderApplicationController
    private var registered = false

    init(files: NexFinderFileService = NexFinderFileService(), application: NexFinderApplicationController = NexFinderApplicationController()) {
        self.files = files
        self.application = application
    }

    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }
        for registration in registrations() {
            try await registry.register(manifest: registration.manifest, handler: registration.handler)
        }
        registered = true
    }

    private struct Registration {
        let manifest: NexComputerActionManifest
        let handler: NexRegisteredTool.Handler
    }

    private func registrations() -> [Registration] {
        let files = files
        let application = application
        return [
            .init(manifest: Self.openFinderManifest, handler: { _, _ in
                try await application.openFinder(); return Self.result(display: "Opened Finder.", paths: [])
            }),
            .init(manifest: Self.searchManifest, handler: { arguments, context in
                guard let root = arguments["root"]?.string else { throw NexToolError.missingField("root") }
                await context.reportProgress("Searching files…", nil)
                let paths = try await files.search(.init(
                    rootPath: root,
                    nameContains: arguments["nameContains"]?.string,
                    fileExtension: arguments["extension"]?.string,
                    contentContains: arguments["contentContains"]?.string,
                    modifiedAfter: Self.date(arguments["modifiedAfter"]?.string),
                    modifiedBefore: Self.date(arguments["modifiedBefore"]?.string),
                    minimumSize: arguments["minimumSize"]?.integer.map(Int64.init),
                    maximumSize: arguments["maximumSize"]?.integer.map(Int64.init),
                    limit: arguments["limit"]?.integer ?? 50
                ))
                return Self.result(display: "Found \(paths.count) item\(paths.count == 1 ? "" : "s").", paths: paths.map(\.path))
            }),
            .init(manifest: Self.openManifest, handler: { arguments, _ in
                let url = try await files.validatedExistingURL(path: Self.path(arguments))
                guard application.open(url) else { throw NexToolError.executionFailed(code: "open_failed", message: "macOS could not open \(url.path).") }
                return Self.result(display: "Opened \(url.lastPathComponent).", paths: [url.path])
            }),
            .init(manifest: Self.revealManifest, handler: { arguments, _ in
                let url = try await files.validatedExistingURL(path: Self.path(arguments)); application.reveal(url)
                return Self.result(display: "Revealed \(url.lastPathComponent) in Finder.", paths: [url.path])
            }),
            .init(manifest: Self.createFolderManifest, handler: { arguments, _ in
                let url = try await files.createFolder(parentPath: Self.parent(arguments), name: Self.name(arguments), collisionPolicy: Self.policy(arguments))
                return Self.result(display: "Created folder \(url.lastPathComponent).", paths: [url.path])
            }),
            .init(manifest: Self.copyManifest, handler: { arguments, _ in
                let url = try await files.copy(sourcePath: Self.path(arguments), destinationDirectory: Self.destination(arguments), collisionPolicy: Self.policy(arguments))
                return Self.result(display: "Copied to \(url.path).", paths: [url.path])
            }),
            .init(manifest: Self.moveManifest, handler: { arguments, _ in
                let url = try await files.move(sourcePath: Self.path(arguments), destinationDirectory: Self.destination(arguments), collisionPolicy: Self.policy(arguments))
                return Self.result(display: "Moved to \(url.path).", paths: [url.path])
            }),
            .init(manifest: Self.renameManifest, handler: { arguments, _ in
                let url = try await files.rename(path: Self.path(arguments), newName: Self.name(arguments), collisionPolicy: Self.policy(arguments))
                return Self.result(display: "Renamed to \(url.lastPathComponent).", paths: [url.path])
            }),
            .init(manifest: Self.trashManifest, handler: { arguments, _ in
                let url = try await files.trash(path: Self.path(arguments))
                return Self.result(display: "Moved the item to Trash.", paths: [url.path])
            }),
            .init(manifest: Self.selectionManifest, handler: { _, _ in
                var paths: [String] = []
                for path in try application.selection() {
                    paths.append(try await files.validatedExistingURL(path: path).path)
                }
                return Self.result(display: "Finder has \(paths.count) selected item\(paths.count == 1 ? "" : "s").", paths: paths)
            })
        ]
    }

    private static func path(_ arguments: [String: NexJSONValue]) throws -> String { guard let value = arguments["path"]?.string else { throw NexToolError.missingField("path") }; return value }
    private static func parent(_ arguments: [String: NexJSONValue]) throws -> String { guard let value = arguments["parent"]?.string else { throw NexToolError.missingField("parent") }; return value }
    private static func destination(_ arguments: [String: NexJSONValue]) throws -> String { guard let value = arguments["destinationDirectory"]?.string else { throw NexToolError.missingField("destinationDirectory") }; return value }
    private static func name(_ arguments: [String: NexJSONValue]) throws -> String { guard let value = arguments["name"]?.string else { throw NexToolError.missingField("name") }; return value }
    private static func policy(_ arguments: [String: NexJSONValue]) throws -> NexFinderCollisionPolicy {
        let raw = arguments["collisionPolicy"]?.string ?? "error"
        guard let value = NexFinderCollisionPolicy(rawValue: raw) else { throw NexToolError.invalidEnum(field: "collisionPolicy", allowed: ["error", "replace", "overwrite", "keep_both"]) }
        return value
    }
    private static func date(_ raw: String?) -> Date? { raw.flatMap { ISO8601DateFormatter().date(from: $0) } }
    private static func result(display: String, paths: [String]) -> NexJSONValue {
        .object([
            "display": .string(display),
            "status": .string("completed"),
            "paths": .array(paths.map(NexJSONValue.string)),
            "count": .number(Double(paths.count))
        ])
    }

    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "paths": .init(.stringArray, required: true), "count": .init(.integer, required: true)])
    private static let finderPermission = [NexComputerPermissionRequirement(id: "automation.com.apple.finder", permission: .automation)]
    private static let collision = NexToolFieldSchema(
        .string,
        description: "Collision behavior. Use keep_both to preserve an existing destination and create a distinct generated copy; use overwrite only when replacing the existing destination is intended.",
        allowedValues: ["error", "replace", "overwrite", "keep_both"]
    )
    private static let pathInput = NexToolInputSchema(fields: ["path": .init(.string, required: true)])
    private static let openFinderManifest = manifest("finder.activate", "Open or activate Finder.", ["Open Finder"], .init(fields: [:]), .low, .never, [], .nativeAPI)
    private static let searchManifest = manifest("finder.search", "Search an allowed local folder by filename, extension (including Markdown), text content, modification date, byte size, and bounded result count.", ["Find PDFs named application", "Find a Markdown file in this folder", "Search this folder for text"], .init(fields: [
        "root": .init(.string, required: true, description: "Absolute existing local folder to search. Preserve every supplied path segment, including spaces."), "nameContains": .init(.string), "extension": .init(.string), "contentContains": .init(.string),
        "modifiedAfter": .init(.string), "modifiedBefore": .init(.string), "minimumSize": .init(.integer, minimum: 0), "maximumSize": .init(.integer, minimum: 0), "limit": .init(.integer, minimum: 1, maximum: 200)
    ]), .low, .never, [], .nativeAPI, aliases: ["find files", "find PDFs", "search folder files"])
    private static let openManifest = manifest("finder.open", "Open a specific existing file or folder using its default macOS application.", ["Open this file"], pathInput, .low, .never, [], .nativeAPI)
    private static let revealManifest = manifest("finder.reveal", "Reveal a specific existing file or folder in Finder.", ["Show this file in Finder"], pathInput, .low, .never, [], .nativeAPI)
    private static let createFolderManifest = manifest("finder.create_folder", "Create one folder under an allowed existing parent with an explicit collision policy.", ["Create a Results folder"], .init(fields: ["parent": .init(.string, required: true), "name": .init(.string, required: true), "collisionPolicy": collision]), .high, .always, [], .nativeAPI)
    private static let copyManifest = mutation("finder.copy", "Copy one file or folder into an allowed directory while preserving filesystem metadata.", ["Copy this file into Results", "Duplicate this generated file in the same folder"])
    private static let moveManifest = mutation("finder.move", "Move one file or folder into an allowed directory with explicit collision handling.", ["Move this file into the Archive folder"])
    private static let renameManifest = manifest("finder.rename", "Rename one file or folder in place with explicit collision handling.", ["Rename this file"], .init(fields: ["path": .init(.string, required: true), "name": .init(.string, required: true), "collisionPolicy": collision]), .high, .always, [], .nativeAPI)
    private static let trashManifest = manifest("finder.trash", "Move one specific file or folder to the macOS Trash.", ["Move this file to Trash"], pathInput, .high, .always, [], .nativeAPI)
    private static let selectionManifest = manifest("finder.get_selection", "Return the current Finder selection as canonical paths.", ["What files are selected in Finder?"], .init(fields: [:]), .low, .never, finderPermission, .appleScript)

    private static func mutation(_ id: String, _ description: String, _ examples: [String]) -> NexComputerActionManifest {
        manifest(id, description, examples, .init(fields: [
            "path": .init(.string, required: true, description: "Exact existing source file or folder. Preserve every supplied path segment, including spaces."),
            "destinationDirectory": .init(.string, required: true, description: "Absolute existing destination folder. Preserve every supplied path segment, including spaces."),
            "collisionPolicy": collision
        ]), .high, .always, [], .nativeAPI)
    }
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ input: NexToolInputSchema, _ risk: NexComputerRiskClass, _ confirmation: NexComputerConfirmationPolicy, _ permissions: [NexComputerPermissionRequirement], _ method: NexComputerImplementationMethod, aliases extraAliases: [String] = []) -> NexComputerActionManifest {
        .init(actionID: id, application: "Finder", provider: "Nexus Native Files", bundleIdentifier: method == .appleScript ? "com.apple.finder" : nil,
              description: description, examples: examples, aliases: [id.replacingOccurrences(of: ".", with: " ")] + extraAliases, tags: ["finder", "file", "folder", "filesystem"],
              inputSchema: input, outputSchema: output, implementationMethod: method, requiredPermissions: permissions, registryPermission: .files,
              riskClass: risk, confirmationPolicy: confirmation, availabilityCheck: method == .appleScript ? .application(bundleIdentifier: "com.apple.finder") : .always,
              timeoutSeconds: id == "finder.search" ? 60 : 20, supportsCancellation: id == "finder.search", dryRunBehavior: .supported("Would perform \(id) without changing files."), previewRenderer: "finder.action", tests: ["NexFinderActionTests"])
    }
}
