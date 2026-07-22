import AppKit
import Foundation
import Photos

// MARK: - Phase 9: Photos

struct NexPhotoSearchRequest: Equatable, Sendable {
    let query: String?
    let startDate: Date?
    let endDate: Date?
    let album: String?
    let mediaType: String?
    let favoritesOnly: Bool
    let latitude: Double?
    let longitude: Double?
    let radiusKilometers: Double?
    let person: String?
    let limit: Int
}

struct NexPhotoRecord: Equatable, Sendable {
    let id: String
    let filename: String
    let createdAt: Date?
    let mediaType: String
    let favorite: Bool
    let latitude: Double?
    let longitude: Double?
    let width: Int
    let height: Int
    let duration: Double
}

protocol NexPhotosProviding: Sendable {
    func open() async throws
    func search(_ request: NexPhotoSearchRequest) async throws -> [NexPhotoRecord]
    func openResult(id: String) async throws -> Bool
    func export(ids: [String], destination: URL) async throws -> [URL]
    func createAlbum(name: String) async throws -> String
    func add(ids: [String], toAlbumID albumID: String) async throws -> Int
}

enum NexPhotosError: LocalizedError, Equatable {
    case unavailable
    case unsupportedFilter(String)
    case invalidDestination
    case assetNotFound(String)
    case albumNotFound(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Photos is unavailable on this Mac."
        case .unsupportedFilter(let filter): "Photos does not expose deterministic \(filter) search to Nexus; no results were fabricated."
        case .invalidDestination: "The export destination must be an existing local directory."
        case .assetNotFound(let id): "Photo asset \(id) was not found."
        case .albumNotFound(let id): "Photos album \(id) was not found."
        case .operationFailed(let message): "Photos operation failed: \(message)"
        }
    }
}

final class NexPhotoKitProvider: NexPhotosProviding, @unchecked Sendable {
    func open() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") else {
            throw NexPhotosError.unavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func search(_ request: NexPhotoSearchRequest) async throws -> [NexPhotoRecord] {
        if let person = request.person, !person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NexPhotosError.unsupportedFilter("person")
        }
        if let query = request.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NexPhotosError.unsupportedFilter("semantic text")
        }

        let options = PHFetchOptions()
        var predicates: [NSPredicate] = []
        if let start = request.startDate { predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate)) }
        if let end = request.endDate { predicates.append(NSPredicate(format: "creationDate <= %@", end as NSDate)) }
        if request.favoritesOnly { predicates.append(NSPredicate(format: "favorite == YES")) }
        if let mediaType = request.mediaType {
            let value: Int
            switch mediaType {
            case "image": value = PHAssetMediaType.image.rawValue
            case "video": value = PHAssetMediaType.video.rawValue
            case "audio": value = PHAssetMediaType.audio.rawValue
            default: throw NexToolError.invalidEnum(field: "media_type", allowed: ["image", "video", "audio"])
            }
            predicates.append(NSPredicate(format: "mediaType == %d", value))
        }
        if !predicates.isEmpty { options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = min(max(request.limit * 4, request.limit), 1_000)

        let fetch: PHFetchResult<PHAsset>
        if let album = request.album, !album.isEmpty {
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            var matched: PHAssetCollection?
            collections.enumerateObjects { collection, _, stop in
                if collection.localIdentifier == album || collection.localizedTitle?.localizedCaseInsensitiveCompare(album) == .orderedSame {
                    matched = collection
                    stop.pointee = true
                }
            }
            guard let matched else { throw NexPhotosError.albumNotFound(album) }
            fetch = PHAsset.fetchAssets(in: matched, options: options)
        } else {
            fetch = PHAsset.fetchAssets(with: options)
        }

        var records: [NexPhotoRecord] = []
        fetch.enumerateObjects { asset, _, stop in
            if let latitude = request.latitude, let longitude = request.longitude {
                guard let location = asset.location else { return }
                let center = CLLocation(latitude: latitude, longitude: longitude)
                let radius = (request.radiusKilometers ?? 5) * 1_000
                guard location.distance(from: center) <= radius else { return }
            }
            let resource = PHAssetResource.assetResources(for: asset).first
            records.append(.init(
                id: asset.localIdentifier,
                filename: resource?.originalFilename ?? "",
                createdAt: asset.creationDate,
                mediaType: Self.mediaType(asset.mediaType),
                favorite: asset.isFavorite,
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                duration: asset.duration
            ))
            if records.count >= request.limit { stop.pointee = true }
        }
        return records
    }

    func openResult(id: String) async throws -> Bool {
        guard PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject != nil else {
            throw NexPhotosError.assetNotFound(id)
        }
        try await open()
        // PhotoKit exposes stable identifiers but no supported API for selecting
        // one asset in Photos. Report the limitation instead of coordinate-clicking.
        return false
    }

    func export(ids: [String], destination: URL) async throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard destination.isFileURL,
              FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw NexPhotosError.invalidDestination }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        var written: [URL] = []
        for id in ids {
            guard let asset = byID[id], let resource = PHAssetResource.assetResources(for: asset).first else {
                throw NexPhotosError.assetNotFound(id)
            }
            let target = Self.uniqueDestination(destination.appendingPathComponent(resource.originalFilename))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: nil) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            written.append(target)
        }
        return written
    }

    func createAlbum(name: String) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NexToolError.executionFailed(code: "invalid_album_name", message: "Album name cannot be empty.") }
        var placeholder: PHObjectPlaceholder?
        try await performChanges {
            placeholder = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: trimmed).placeholderForCreatedAssetCollection
        }
        guard let id = placeholder?.localIdentifier else { throw NexPhotosError.operationFailed("Photos did not return an album identifier.") }
        return id
    }

    func add(ids: [String], toAlbumID albumID: String) async throws -> Int {
        let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
        guard let album = albums.firstObject else { throw NexPhotosError.albumNotFound(albumID) }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count == ids.count else { throw NexPhotosError.operationFailed("One or more selected assets no longer exist.") }
        try await performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets)
        }
        return assets.count
    }

    private func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: NexPhotosError.operationFailed("Photos rejected the change.")) }
            }
        }
    }

    private static func mediaType(_ type: PHAssetMediaType) -> String {
        switch type { case .image: "image"; case .video: "video"; case .audio: "audio"; default: "unknown" }
    }

    private static func uniqueDestination(_ candidate: URL) -> URL {
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for index in 2...10_000 {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let url = candidate.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return candidate.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
}

actor NexPhotosActionCatalog {
    private let provider: any NexPhotosProviding
    private var registered = false

    init(provider: any NexPhotosProviding = NexPhotoKitProvider()) { self.provider = provider }

    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }
        let provider = provider
        try await registry.register(manifest: Self.openManifest) { _, _ in
            try await provider.open()
            return .object(["display": .string("Opened Photos."), "status": .string("opened"), "results": .array([]), "paths": .array([]), "id": .string("")])
        }
        try await registry.register(manifest: Self.searchManifest) { arguments, _ in
            let request = try Self.searchRequest(arguments)
            let records = try await provider.search(request)
            return Self.result(display: "Found \(records.count) matching Photos item\(records.count == 1 ? "" : "s").", status: "found", records: records)
        }
        try await registry.register(manifest: Self.openResultManifest) { arguments, _ in
            guard let id = arguments["id"]?.string else { throw NexToolError.missingField("id") }
            let focused = try await provider.openResult(id: id)
            return .object(["display": .string(focused ? "Opened the selected photo." : "Opened Photos. macOS does not expose supported exact-asset focusing."), "status": .string(focused ? "opened_result" : "opened_library"), "results": .array([]), "paths": .array([]), "id": .string(id)])
        }
        for manifest in [Self.exportManifest, Self.copyManifest] {
            try await registry.register(manifest: manifest) { arguments, _ in
                let ids = try Self.stringArray(arguments, key: "ids")
                guard let destination = arguments["destination"]?.string else { throw NexToolError.missingField("destination") }
                let urls = try await provider.export(ids: ids, destination: URL(fileURLWithPath: destination))
                return .object(["display": .string("Exported \(urls.count) Photos item\(urls.count == 1 ? "" : "s")."), "status": .string("exported"), "results": .array([]), "paths": .array(urls.map { .string($0.path) }), "id": .string("")])
            }
        }
        try await registry.register(manifest: Self.createAlbumManifest) { arguments, _ in
            guard let name = arguments["name"]?.string else { throw NexToolError.missingField("name") }
            let id = try await provider.createAlbum(name: name)
            return .object(["display": .string("Created Photos album “\(name)”."), "status": .string("album_created"), "results": .array([]), "paths": .array([]), "id": .string(id)])
        }
        try await registry.register(manifest: Self.addAlbumManifest) { arguments, _ in
            guard let albumID = arguments["album_id"]?.string else { throw NexToolError.missingField("album_id") }
            let count = try await provider.add(ids: Self.stringArray(arguments, key: "ids"), toAlbumID: albumID)
            return .object(["display": .string("Added \(count) Photos item\(count == 1 ? "" : "s") to the album."), "status": .string("album_updated"), "results": .array([]), "paths": .array([]), "id": .string(albumID)])
        }
        registered = true
    }

    private static func searchRequest(_ arguments: [String: NexJSONValue]) throws -> NexPhotoSearchRequest {
        let formatter = ISO8601DateFormatter()
        func date(_ key: String) throws -> Date? {
            guard let value = arguments[key]?.string, !value.isEmpty else { return nil }
            guard let parsed = formatter.date(from: value) else { throw NexToolError.executionFailed(code: "invalid_date", message: "\(key) must use an ISO-8601 timestamp.") }
            return parsed
        }
        return .init(query: arguments["query"]?.string, startDate: try date("start_date"), endDate: try date("end_date"), album: arguments["album"]?.string,
                     mediaType: arguments["media_type"]?.string, favoritesOnly: arguments["favorites"]?.bool ?? false,
                     latitude: arguments["latitude"]?.number, longitude: arguments["longitude"]?.number,
                     radiusKilometers: arguments["radius_km"]?.number, person: arguments["person"]?.string,
                     limit: arguments["limit"]?.integer ?? 20)
    }

    private static func stringArray(_ arguments: [String: NexJSONValue], key: String) throws -> [String] {
        guard case .array(let values) = arguments[key] else { throw NexToolError.missingField(key) }
        let strings = values.compactMap(\.string).filter { !$0.isEmpty }
        guard strings.count == values.count, !strings.isEmpty else { throw NexToolError.executionFailed(code: "invalid_photo_ids", message: "\(key) must contain one or more stable Photos IDs.") }
        return strings
    }

    private static func result(display: String, status: String, records: [NexPhotoRecord]) -> NexJSONValue {
        let formatter = ISO8601DateFormatter()
        return .object(["display": .string(display), "status": .string(status), "results": .array(records.map { record in
            .object(["id": .string(record.id), "filename": .string(record.filename), "created_at": .string(record.createdAt.map(formatter.string) ?? ""),
                     "media_type": .string(record.mediaType), "favorite": .bool(record.favorite), "latitude": .number(record.latitude ?? 0),
                     "longitude": .number(record.longitude ?? 0), "width": .number(Double(record.width)), "height": .number(Double(record.height)), "duration": .number(record.duration)])
        }), "paths": .array([]), "id": .string("")])
    }

    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "results": .init(.array, required: true), "paths": .init(.array, required: true), "id": .init(.string, required: true)])
    private static let openManifest = manifest("photos.open", "Open or activate Apple Photos.", ["Open Photos"], .init(fields: [:]))
    private static let searchManifest = manifest("photos.search", "Search Apple Photos by exact supported metadata. Person and semantic text filters fail honestly when unavailable.", ["Find favorite videos from last month", "Find photos near these coordinates"], .init(fields: [
        "query": .init(.string), "start_date": .init(.string), "end_date": .init(.string), "album": .init(.string), "media_type": .init(.string, allowedValues: ["image", "video", "audio"]),
        "favorites": .init(.boolean), "latitude": .init(.number, minimum: -90, maximum: 90), "longitude": .init(.number, minimum: -180, maximum: 180),
        "radius_km": .init(.number, minimum: 0.01, maximum: 500), "person": .init(.string), "limit": .init(.integer, minimum: 1, maximum: 250)
    ]))
    private static let openResultManifest = manifest("photos.open_result", "Open Photos for a previously returned stable asset ID; report if exact focusing is unavailable.", ["Open this photo result"], .init(fields: ["id": .init(.string, required: true)]))
    private static let exportManifest = manifest("photos.export", "Export selected Photos assets by stable ID to an existing destination directory.", ["Export these photos to Downloads"], .init(fields: ["ids": .init(.array, required: true), "destination": .init(.string, required: true)]), risk: .medium, confirmation: .always)
    private static let copyManifest = manifest("photos.copy_results", "Copy selected Photos results into an existing local destination without changing the Photos library.", ["Copy these results to my project"], .init(fields: ["ids": .init(.array, required: true), "destination": .init(.string, required: true)]), risk: .medium, confirmation: .always)
    private static let createAlbumManifest = manifest("photos.create_album", "Create a Photos album. Albums are Photos collections, never filesystem folders.", ["Create a Photos album named Robotics"], .init(fields: ["name": .init(.string, required: true)]), risk: .high, confirmation: .always)
    private static let addAlbumManifest = manifest("photos.add_to_album", "Add selected stable Photos asset IDs to an existing Photos album ID.", ["Add these photos to that album"], .init(fields: ["ids": .init(.array, required: true), "album_id": .init(.string, required: true)]), risk: .high, confirmation: .always)

    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ input: NexToolInputSchema, risk: NexComputerRiskClass = .low, confirmation: NexComputerConfirmationPolicy = .never) -> NexComputerActionManifest {
        .init(actionID: id, application: "Photos", provider: "PhotoKit", bundleIdentifier: "com.apple.Photos", description: description, examples: examples,
              aliases: [id.replacingOccurrences(of: ".", with: " ")], tags: ["photos", "images", "videos", "albums", "media"], inputSchema: input, outputSchema: output,
              implementationMethod: .nativeAPI, requiredPermissions: [.init(id: "photos.library", permission: .files)], registryPermission: .files,
              riskClass: risk, confirmationPolicy: confirmation, availabilityCheck: .application(bundleIdentifier: "com.apple.Photos"), timeoutSeconds: 120,
              supportsCancellation: false, dryRunBehavior: .supported("Would perform \(id) through PhotoKit."), previewRenderer: "photos.results", tests: ["NexPhotosActionTests"])
    }
}

// MARK: - Phase 10: Visual Studio Code

protocol NexVSCodeProviding: Sendable {
    func open() async throws
    func open(path: URL, line: Int?) async throws
    func runCommand(_ command: String) async throws
    func activeWorkspace() async -> URL?
    func search(workspace: URL, query: String, limit: Int) async throws -> [(URL, Int, String)]
    func edit(file: URL, oldText: String, newText: String, replaceAll: Bool) async throws -> String
}

enum NexVSCodeError: LocalizedError {
    case unavailable
    case invalidPath
    case workspaceRequired
    case textNotFound
    case broadEdit
    var errorDescription: String? {
        switch self {
        case .unavailable: "Visual Studio Code or its `code` CLI is not installed."
        case .invalidPath: "The requested VS Code path does not exist."
        case .workspaceRequired: "Open a workspace first or provide its absolute path."
        case .textNotFound: "The exact text to replace was not found."
        case .broadEdit: "The edit matches multiple locations; set replace_all explicitly to confirm the intended scope."
        }
    }
}

actor NexVSCodeCLIProvider: NexVSCodeProviding {
    private var workspace: URL?
    private let executable: URL?
    private static let allowedCommands: Set<String> = ["workbench.action.files.saveAll", "workbench.action.quickOpen", "workbench.action.showCommands", "workbench.view.explorer"]

    init(executable: URL? = NexVSCodeCLIProvider.discoverExecutable()) { self.executable = executable }

    func open() async throws {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: .init())
        } else if executable != nil { _ = try await process([]) }
        else { throw NexVSCodeError.unavailable }
    }

    func open(path: URL, line: Int?) async throws {
        guard FileManager.default.fileExists(atPath: path.path) else { throw NexVSCodeError.invalidPath }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
        if isDirectory.boolValue { workspace = path.standardizedFileURL }
        let target = line.map { "\(path.path):\($0)" } ?? path.path
        _ = try await process(["--reuse-window", "--goto", target])
    }

    func runCommand(_ command: String) async throws {
        guard Self.allowedCommands.contains(command) else { throw NexToolError.executionFailed(code: "unsupported_vscode_command", message: "VS Code command is not in Nexus's safe command allowlist.") }
        guard let encoded = command.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "vscode://command/\(encoded)") else {
            throw NexToolError.executionFailed(code: "invalid_vscode_command", message: "VS Code rejected the command URL.")
        }
        guard NSWorkspace.shared.open(url) else { throw NexVSCodeError.unavailable }
    }

    func activeWorkspace() async -> URL? { workspace }

    func search(workspace: URL, query: String, limit: Int) async throws -> [(URL, Int, String)] {
        guard !query.isEmpty else { throw NexToolError.executionFailed(code: "invalid_query", message: "Search query cannot be empty.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw NexVSCodeError.workspaceRequired }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var matches: [(URL, Int, String)] = []
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, (values.fileSize ?? 0) <= 2_000_000,
                  let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: .newlines).enumerated() where line.localizedCaseInsensitiveContains(query) {
                matches.append((file, index + 1, String(line.prefix(500))))
                if matches.count >= limit { return matches }
            }
        }
        return matches
    }

    func edit(file: URL, oldText: String, newText: String, replaceAll: Bool) async throws -> String {
        guard file.isFileURL, let data = try? Data(contentsOf: file) else { throw NexVSCodeError.invalidPath }
        let encoding: String.Encoding = String(data: data, encoding: .utf8) != nil ? .utf8 : .utf16
        guard let original = String(data: data, encoding: encoding) else { throw NexToolError.executionFailed(code: "unsupported_encoding", message: "Nexus could not safely decode the file.") }
        let count = original.components(separatedBy: oldText).count - 1
        guard count > 0 else { throw NexVSCodeError.textNotFound }
        guard count == 1 || replaceAll else { throw NexVSCodeError.broadEdit }
        let updated = replaceAll ? original.replacingOccurrences(of: oldText, with: newText) : original.replacingCharacters(in: original.range(of: oldText)!, with: newText)
        guard let output = updated.data(using: encoding) else { throw NexToolError.executionFailed(code: "encoding_failed", message: "Nexus could not preserve the file encoding.") }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).nex-\(UUID().uuidString)")
        try output.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        return Self.unifiedDiff(path: file.path, old: original, new: updated)
    }

    private func process(_ arguments: [String]) async throws -> String {
        guard let executable else { throw NexVSCodeError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process(); let pipe = Pipe()
            process.executableURL = executable; process.arguments = arguments; process.standardOutput = pipe; process.standardError = pipe
            process.terminationHandler = { process in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.terminationStatus == 0 ? continuation.resume(returning: output) : continuation.resume(throwing: NexToolError.executionFailed(code: "vscode_cli_failed", message: output))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    nonisolated static func discoverExecutable() -> URL? {
        ["/usr/local/bin/code", "/opt/homebrew/bin/code", "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"].map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func unifiedDiff(path: String, old: String, new: String) -> String {
        let oldLines = old.components(separatedBy: .newlines), newLines = new.components(separatedBy: .newlines)
        var lines = ["--- \(path)", "+++ \(path)"]
        for index in 0..<max(oldLines.count, newLines.count) {
            let lhs = index < oldLines.count ? oldLines[index] : nil, rhs = index < newLines.count ? newLines[index] : nil
            if lhs != rhs { if let lhs { lines.append("-\(lhs)") }; if let rhs { lines.append("+\(rhs)") } }
        }
        return lines.joined(separator: "\n")
    }
}

actor NexVSCodeActionCatalog {
    private let provider: any NexVSCodeProviding
    private var registered = false
    init(provider: any NexVSCodeProviding = NexVSCodeCLIProvider()) { self.provider = provider }

    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }; let provider = provider
        try await registry.register(manifest: Self.manifest("vscode.open", "Open or activate Visual Studio Code.", ["Open VS Code"], [:])) { _, _ in try await provider.open(); return Self.result("Opened VS Code.") }
        try await registry.register(manifest: Self.manifest("vscode.open_project", "Open an existing project directory in VS Code.", ["Open this project in VS Code"], ["path": .init(.string, required: true)])) { args, _ in
            guard let path = args["path"]?.string else { throw NexToolError.missingField("path") }; try await provider.open(path: URL(fileURLWithPath: path), line: nil); return Self.result("Opened the VS Code project.", path: path)
        }
        try await registry.register(manifest: Self.manifest("vscode.open_file", "Open an existing file at an optional line in VS Code.", ["Open this file at line 20"], ["path": .init(.string, required: true), "line": .init(.integer, minimum: 1)])) { args, _ in
            guard let path = args["path"]?.string else { throw NexToolError.missingField("path") }; try await provider.open(path: URL(fileURLWithPath: path), line: args["line"]?.integer); return Self.result("Opened the file in VS Code.", path: path)
        }
        try await registry.register(manifest: Self.manifest("vscode.search_workspace", "Search readable text files within an exact workspace directory.", ["Search this workspace for NotchGeometry"], ["workspace": .init(.string, required: true), "query": .init(.string, required: true), "limit": .init(.integer, minimum: 1, maximum: 100)])) { args, _ in
            guard let workspace = args["workspace"]?.string, let query = args["query"]?.string else { throw NexToolError.missingField("workspace") }
            let matches = try await provider.search(workspace: URL(fileURLWithPath: workspace), query: query, limit: args["limit"]?.integer ?? 30)
            return .object(["display": .string("Found \(matches.count) workspace match\(matches.count == 1 ? "" : "es")."), "status": .string("completed"), "path": .string(workspace), "diff": .string(""), "results": .array(matches.map { .object(["path": .string($0.0.path), "line": .number(Double($0.1)), "text": .string($0.2)]) })])
        }
        try await registry.register(manifest: Self.manifest("vscode.run_command", "Run one explicitly allowlisted VS Code workbench command through its URL scheme.", ["Show VS Code command palette"], ["command": .init(.string, required: true)], risk: .medium, confirmation: .always)) { args, _ in
            guard let command = args["command"]?.string else { throw NexToolError.missingField("command") }; try await provider.runCommand(command); return Self.result("Ran the VS Code command.")
        }
        try await registry.register(manifest: Self.manifest("vscode.get_active_workspace", "Return the workspace last opened by Nexus in VS Code; do not guess editor state.", ["Which VS Code workspace is active?"], [:])) { _, _ in
            let workspace = await provider.activeWorkspace(); return Self.result(workspace == nil ? "Nexus has not opened a VS Code workspace in this session." : "Active Nexus VS Code workspace: \(workspace!.path)", path: workspace?.path ?? "")
        }
        try await registry.register(manifest: Self.manifest("vscode.edit_file", "Perform an exact validated text replacement on disk, preserve encoding and line endings, and return a diff.", ["Replace this exact function in the file"], ["path": .init(.string, required: true), "old_text": .init(.string, required: true), "new_text": .init(.string, required: true), "replace_all": .init(.boolean)], risk: .high, confirmation: .always)) { args, _ in
            guard let path = args["path"]?.string, let old = args["old_text"]?.string, let new = args["new_text"]?.string else { throw NexToolError.missingField("path") }
            let diff = try await provider.edit(file: URL(fileURLWithPath: path), oldText: old, newText: new, replaceAll: args["replace_all"]?.bool ?? false)
            return .object(["display": .string("Updated the file deterministically."), "status": .string("completed"), "path": .string(path), "diff": .string(diff), "results": .array([])])
        }
        registered = true
    }

    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "path": .init(.string, required: true), "diff": .init(.string, required: true), "results": .init(.array, required: true)])
    private static func result(_ display: String, path: String = "") -> NexJSONValue { .object(["display": .string(display), "status": .string("completed"), "path": .string(path), "diff": .string(""), "results": .array([])]) }
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ fields: [String: NexToolFieldSchema], risk: NexComputerRiskClass = .low, confirmation: NexComputerConfirmationPolicy = .never) -> NexComputerActionManifest {
        .init(actionID: id, application: "Visual Studio Code", provider: "VS Code CLI", bundleIdentifier: "com.microsoft.VSCode", description: description, examples: examples,
              aliases: [id.replacingOccurrences(of: ".", with: " ")], tags: ["vscode", "code", "editor", "workspace", "developer"], inputSchema: .init(fields: fields), outputSchema: output,
              implementationMethod: .cli, registryPermission: risk == .low ? .files : .codeExecution, riskClass: risk, confirmationPolicy: confirmation,
              availabilityCheck: .executable(paths: ["/usr/local/bin/code", "/opt/homebrew/bin/code", "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"]), timeoutSeconds: 60,
              supportsCancellation: true, dryRunBehavior: .supported("Would perform \(id) through the VS Code CLI."), previewRenderer: "vscode.action", tests: ["NexVSCodeActionTests"])
    }
}
