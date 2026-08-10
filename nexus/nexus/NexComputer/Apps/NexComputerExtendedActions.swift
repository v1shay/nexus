import AppKit
import Foundation
import PDFKit
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

// MARK: - Phase 11: Codex

struct NexCodexTaskSnapshot: Equatable, Sendable {
    let sessionID: String
    let status: String
    let finalText: String
    let filesChanged: [String]
    let testSummary: String
    let error: String?
}

protocol NexCodexProviding: Sendable {
    func open() async throws
    func run(prompt: String, workspace: URL, sessionID: String?, progress: @escaping @Sendable (String) async -> Void) async throws -> NexCodexTaskSnapshot
    func status(sessionID: String) async -> NexCodexTaskSnapshot?
    func cancel(sessionID: String) async throws
    func openSession(sessionID: String) async throws
}

enum NexCodexError: LocalizedError {
    case unavailable
    case invalidWorkspace
    case unknownSession
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "The installed Codex CLI could not be found."
        case .invalidWorkspace: "Codex requires an existing workspace directory."
        case .unknownSession: "That Codex session is not known on this Mac."
        case .failed(let message): "Codex failed: \(message)"
        }
    }
}

actor NexCodexCLIProvider: NexCodexProviding {
    private let executable: URL?
    private var snapshots: [String: NexCodexTaskSnapshot] = [:]
    private var running: [String: Process] = [:]
    init(executable: URL? = NexCodexCLIProvider.discoverExecutable()) { self.executable = executable }

    func open() async throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat") else { throw NexCodexError.unavailable }
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }

    func run(prompt: String, workspace: URL, sessionID: String?, progress: @escaping @Sendable (String) async -> Void) async throws -> NexCodexTaskSnapshot {
        guard let executable else { throw NexCodexError.unavailable }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw NexCodexError.invalidWorkspace }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("nex-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let fallbackID = sessionID ?? UUID().uuidString.lowercased()
        var arguments: [String]
        if let sessionID {
            arguments = ["exec", "resume", sessionID, "--json", "-o", outputURL.path, prompt]
        } else {
            arguments = ["exec", "--json", "-C", workspace.path, "-s", "workspace-write", "-o", outputURL.path, prompt]
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = workspace
        process.standardOutput = pipe; process.standardError = pipe
        running[fallbackID] = process
        snapshots[fallbackID] = .init(sessionID: fallbackID, status: "running", finalText: "", filesChanged: [], testSummary: "", error: nil)
        try process.run()
        var resolvedID = fallbackID, transcript = "", testLines: [String] = []
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                transcript += line + "\n"
                if let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let id = Self.findString(in: json, keys: ["session_id", "thread_id", "conversation_id"]), !id.isEmpty {
                        resolvedID = id
                        if running[resolvedID] == nil { running[resolvedID] = process }
                    }
                    if let message = Self.progressMessage(json) { await progress(message) }
                }
                if line.localizedCaseInsensitiveContains("test") || line.contains("BUILD SUCCEEDED") || line.contains("BUILD FAILED") { testLines.append(String(line.prefix(1_000))) }
            }
        } catch { process.terminate() }
        process.waitUntilExit(); running[fallbackID] = nil; running[resolvedID] = nil
        let final = (try? String(contentsOf: outputURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let files = Self.gitChanges(in: workspace)
        let failure = process.terminationStatus == 0 ? nil : String(transcript.suffix(2_000))
        let snapshot = NexCodexTaskSnapshot(sessionID: resolvedID, status: failure == nil ? "completed" : "failed", finalText: final, filesChanged: files, testSummary: testLines.suffix(20).joined(separator: "\n"), error: failure)
        snapshots[resolvedID] = snapshot; if resolvedID != fallbackID { snapshots[fallbackID] = snapshot }
        if let failure { throw NexCodexError.failed(failure) }
        return snapshot
    }

    func status(sessionID: String) async -> NexCodexTaskSnapshot? { snapshots[sessionID] }
    func cancel(sessionID: String) async throws {
        guard let process = running[sessionID], process.isRunning else { throw NexCodexError.unknownSession }
        process.interrupt(); try? await Task.sleep(for: .milliseconds(400)); if process.isRunning { process.terminate() }
        running[sessionID] = nil
        let prior = snapshots[sessionID]
        snapshots[sessionID] = .init(sessionID: sessionID, status: "cancelled", finalText: prior?.finalText ?? "", filesChanged: prior?.filesChanged ?? [], testSummary: prior?.testSummary ?? "", error: nil)
    }
    func openSession(sessionID: String) async throws { guard snapshots[sessionID] != nil else { throw NexCodexError.unknownSession }; try await open() }

    nonisolated static func discoverExecutable() -> URL? {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"].map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    private static func gitChanges(in workspace: URL) -> [String] {
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", workspace.path, "status", "--porcelain=v1"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }; process.waitUntilExit()
        return (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").split(separator: "\n").map { String($0.dropFirst(min(3, $0.count))) }
    }
    private static func findString(in value: Any, keys: Set<String>) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary { if keys.contains(key), let string = child as? String { return string }; if let found = findString(in: child, keys: keys) { return found } }
        } else if let array = value as? [Any] { for child in array { if let found = findString(in: child, keys: keys) { return found } } }
        return nil
    }
    private static func progressMessage(_ json: [String: Any]) -> String? {
        let payload = json["payload"] as? [String: Any] ?? json
        for key in ["message", "text", "detail"] { if let value = payload[key] as? String, !value.isEmpty { return String(value.prefix(500)) } }
        if let type = payload["type"] as? String { return type.replacingOccurrences(of: "_", with: " ").capitalized }
        return nil
    }
}

actor NexCodexActionCatalog {
    private let provider: any NexCodexProviding; private var registered = false
    init(provider: any NexCodexProviding = NexCodexCLIProvider()) { self.provider = provider }
    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }; let provider = provider
        try await registry.register(manifest: Self.manifest("codex.open", "Open the installed Codex application for visual review.", ["Open Codex"], [:])) { _, _ in try await provider.open(); return Self.result(display: "Opened Codex.") }
        for (id, description) in [("codex.start_task", "Start a persisted Codex task in an exact workspace and stream its real JSONL progress."), ("codex.continue_task", "Continue an existing stable Codex session with a new prompt and stream progress.")] {
            var fields: [String: NexToolFieldSchema] = ["workspace": .init(.string, required: true), "prompt": .init(.string, required: true)]
            if id.hasSuffix("continue_task") { fields["session_id"] = .init(.string, required: true) }
            try await registry.register(manifest: Self.manifest(id, description, [id.hasSuffix("continue_task") ? "Continue this Codex session" : "Have Codex implement this task"], fields, risk: .high, confirmation: .always)) { args, context in
                guard let workspace = args["workspace"]?.string, let prompt = args["prompt"]?.string else { throw NexToolError.missingField("workspace") }
                let snapshot = try await provider.run(prompt: prompt, workspace: URL(fileURLWithPath: workspace), sessionID: args["session_id"]?.string) { message in await context.reportProgress(message, nil) }
                return Self.result(snapshot: snapshot)
            }
        }
        try await registry.register(manifest: Self.manifest("codex.get_status", "Get the last known structured status for a stable Codex session ID.", ["Check this Codex task"], ["session_id": .init(.string, required: true)])) { args, _ in
            guard let id = args["session_id"]?.string else { throw NexToolError.missingField("session_id") }; guard let snapshot = await provider.status(sessionID: id) else { throw NexCodexError.unknownSession }; return Self.result(snapshot: snapshot)
        }
        try await registry.register(manifest: Self.manifest("codex.cancel_task", "Safely interrupt a running Codex session.", ["Cancel that Codex task"], ["session_id": .init(.string, required: true)], risk: .high, confirmation: .always)) { args, _ in
            guard let id = args["session_id"]?.string else { throw NexToolError.missingField("session_id") }; try await provider.cancel(sessionID: id); return Self.result(display: "Cancelled the Codex task.", sessionID: id, status: "cancelled")
        }
        try await registry.register(manifest: Self.manifest("codex.open_session", "Open Codex for visual review of a known stable session.", ["Open this Codex session"], ["session_id": .init(.string, required: true)])) { args, _ in
            guard let id = args["session_id"]?.string else { throw NexToolError.missingField("session_id") }; try await provider.openSession(sessionID: id); return Self.result(display: "Opened Codex for session review.", sessionID: id)
        }
        registered = true
    }
    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "session_id": .init(.string, required: true), "final_text": .init(.string, required: true), "files_changed": .init(.stringArray, required: true), "test_summary": .init(.string, required: true), "error": .init(.string, required: true)])
    private static func result(snapshot: NexCodexTaskSnapshot) -> NexJSONValue { result(display: snapshot.finalText.isEmpty ? "Codex task \(snapshot.status)." : snapshot.finalText, sessionID: snapshot.sessionID, status: snapshot.status, final: snapshot.finalText, files: snapshot.filesChanged, tests: snapshot.testSummary, error: snapshot.error ?? "") }
    private static func result(display: String, sessionID: String = "", status: String = "completed", final: String = "", files: [String] = [], tests: String = "", error: String = "") -> NexJSONValue { .object(["display": .string(display), "status": .string(status), "session_id": .string(sessionID), "final_text": .string(final), "files_changed": .array(files.map(NexJSONValue.string)), "test_summary": .string(tests), "error": .string(error)]) }
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ fields: [String: NexToolFieldSchema], risk: NexComputerRiskClass = .low, confirmation: NexComputerConfirmationPolicy = .never) -> NexComputerActionManifest {
        .init(actionID: id, application: "Codex", provider: "Codex CLI", bundleIdentifier: "com.openai.codex", description: description, examples: examples, aliases: [id.replacingOccurrences(of: ".", with: " ")], tags: ["codex", "coding", "agent", "developer", "task"], inputSchema: .init(fields: fields), outputSchema: output, implementationMethod: .cli, registryPermission: risk == .low ? .files : .codeExecution, riskClass: risk, confirmationPolicy: confirmation, availabilityCheck: .executable(paths: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]), timeoutSeconds: 300, supportsCancellation: true, dryRunBehavior: .supported("Would perform \(id) through the installed Codex CLI."), previewRenderer: "codex.task", tests: ["NexCodexActionTests"])
    }
}

// MARK: - Phase 12: Obsidian

struct NexObsidianNoteMatch: Equatable, Sendable { let relativePath: String; let title: String; let excerpt: String; let modifiedAt: Date? }

actor NexObsidianFileProvider {
    let root: URL
    init(root: URL = NexVaultLocation.defaultURL()) {
        let standardized = root.standardizedFileURL
        self.root = standardized.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    }
    func prepare() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func open() async throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") else { throw NexToolError.executionFailed(code: "obsidian_unavailable", message: "Obsidian is not installed.") }
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }
    func openNote(relativePath: String) async throws {
        let file = try resolve(relativePath); guard FileManager.default.fileExists(atPath: file.path) else { throw NexToolError.executionFailed(code: "note_not_found", message: "Obsidian note was not found.") }
        let vault = root.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? root.lastPathComponent
        let path = try canonicalRelative(file).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? relativePath
        guard let url = URL(string: "obsidian://open?vault=\(vault)&file=\(path)"), NSWorkspace.shared.open(url) else { try await open(); return }
    }
    func read(relativePath: String) throws -> String { try String(contentsOf: resolve(relativePath), encoding: .utf8) }
    func search(query: String?, folder: String?, tag: String?, frontmatterKey: String?, frontmatterValue: String?, createdAfter: Date?, modifiedAfter: Date?, limit: Int) throws -> [NexObsidianNoteMatch] {
        let base = try folder.map(resolveDirectory) ?? root
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var results: [NexObsidianNoteMatch] = []
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "md" {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]), values.isRegularFile == true,
                  createdAfter.map({ (values.creationDate ?? .distantPast) >= $0 }) ?? true,
                  modifiedAfter.map({ (values.contentModificationDate ?? .distantPast) >= $0 }) ?? true,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let title = text.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) } ?? file.deletingPathExtension().lastPathComponent
            if let query, !query.isEmpty, !title.localizedCaseInsensitiveContains(query), !text.localizedCaseInsensitiveContains(query) { continue }
            if let tag, !tag.isEmpty, !Self.matchesTag(tag, in: text) { continue }
            if let key = frontmatterKey, !key.isEmpty {
                let needle = "\n\(key):"; guard text.hasPrefix("\(key):") || text.localizedCaseInsensitiveContains(needle) else { continue }
                if let value = frontmatterValue, !value.isEmpty, !text.localizedCaseInsensitiveContains("\(key): \(value)") { continue }
            }
            let excerpt = String(text.replacingOccurrences(of: "\n", with: " ").prefix(500))
            results.append(.init(relativePath: try canonicalRelative(file), title: title, excerpt: excerpt, modifiedAt: values.contentModificationDate))
            if results.count >= limit { break }
        }
        return results.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }
    func create(relativePath: String, content: String) throws -> String {
        let file = try resolve(relativePath); guard !FileManager.default.fileExists(atPath: file.path) else { throw NexToolError.executionFailed(code: "note_exists", message: "The note already exists; use update_note.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try atomicWrite(content, to: file); return try canonicalRelative(file)
    }
    func update(relativePath: String, content: String) throws -> String {
        let file = try resolve(relativePath), old = try String(contentsOf: file, encoding: .utf8); try atomicWrite(content, to: file); return NexVSCodeCLIProvider.unifiedDiffForTools(path: file.path, old: old, new: content)
    }
    func append(relativePath: String, content: String) throws -> String {
        let file = try resolve(relativePath), old = try String(contentsOf: file, encoding: .utf8); let separator = old.hasSuffix("\n") ? "" : "\n"; let updated = old + separator + content; try atomicWrite(updated, to: file); return NexVSCodeCLIProvider.unifiedDiffForTools(path: file.path, old: old, new: updated)
    }
    private func resolve(_ relativePath: String) throws -> URL {
        var path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines); if !path.lowercased().hasSuffix(".md") { path += ".md" }
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw NexObsidianVaultError.unsafePath }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(canonicalRoot.path + "/") else { throw NexObsidianVaultError.unsafePath }
        return candidate
    }
    private func resolveDirectory(_ relativePath: String) throws -> URL {
        let path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw NexObsidianVaultError.unsafePath }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == canonicalRoot.path || candidate.path.hasPrefix(canonicalRoot.path + "/") else { throw NexObsidianVaultError.unsafePath }
        return candidate
    }
    private func canonicalRelative(_ file: URL) throws -> String {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalFile = file.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalFile.path.hasPrefix(canonicalRoot.path + "/") else { throw NexObsidianVaultError.unsafePath }
        return String(canonicalFile.path.dropFirst(canonicalRoot.path.count + 1))
    }
    private func atomicWrite(_ text: String, to file: URL) throws { guard let data = text.data(using: .utf8) else { throw NexToolError.executionFailed(code: "encoding_failed", message: "Note is not valid UTF-8.") }; try data.write(to: file, options: .atomic) }
    private nonisolated static func matchesTag(_ requested: String, in text: String) -> Bool {
        let normalized = requested.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        guard !normalized.isEmpty else { return true }
        if text.localizedCaseInsensitiveContains("#\(normalized)") { return true }
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("tags:") {
                let value = String(trimmed.dropFirst(5))
                let tags = value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased() }
                if tags.contains(normalized) { return true }
            }
            if trimmed.hasPrefix("- "), trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased() == normalized { return true }
        }
        return false
    }
}

extension NexVSCodeCLIProvider {
    nonisolated static func unifiedDiffForTools(path: String, old: String, new: String) -> String {
        let oldLines = old.components(separatedBy: .newlines), newLines = new.components(separatedBy: .newlines); var lines = ["--- \(path)", "+++ \(path)"]
        for index in 0..<max(oldLines.count, newLines.count) { let lhs = index < oldLines.count ? oldLines[index] : nil, rhs = index < newLines.count ? newLines[index] : nil; if lhs != rhs { if let lhs { lines.append("-\(lhs)") }; if let rhs { lines.append("+\(rhs)") } } }; return lines.joined(separator: "\n")
    }
}

actor NexObsidianActionCatalog {
    private let provider: NexObsidianFileProvider; private var registered = false
    init(provider: NexObsidianFileProvider = NexObsidianFileProvider()) { self.provider = provider }
    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }; let provider = provider; try await provider.prepare()
        try await registry.register(manifest: Self.manifest("obsidian.open", "Open or activate Obsidian without editing through its UI.", ["Open Obsidian"], [:])) { _, _ in try await provider.open(); return Self.result("Opened Obsidian.") }
        try await registry.register(manifest: Self.manifest("obsidian.search", "Search canonical Markdown notes by title/content, folder, tag, frontmatter, creation/modification date, and limit.", ["Find my Nexus architecture notes"], ["query": .init(.string), "folder": .init(.string), "tag": .init(.string), "frontmatter_key": .init(.string), "frontmatter_value": .init(.string), "created_after": .init(.string), "modified_after": .init(.string), "limit": .init(.integer, minimum: 1, maximum: 100)])) { args, _ in
            let iso = ISO8601DateFormatter(); let matches = try await provider.search(query: args["query"]?.string, folder: args["folder"]?.string, tag: args["tag"]?.string, frontmatterKey: args["frontmatter_key"]?.string, frontmatterValue: args["frontmatter_value"]?.string, createdAfter: args["created_after"]?.string.flatMap(iso.date), modifiedAfter: args["modified_after"]?.string.flatMap(iso.date), limit: args["limit"]?.integer ?? 20)
            return .object(["display": .string("Found \(matches.count) Obsidian note\(matches.count == 1 ? "" : "s")."), "status": .string("completed"), "path": .string(""), "content": .string(""), "diff": .string(""), "results": .array(matches.map { .object(["path": .string($0.relativePath), "title": .string($0.title), "excerpt": .string($0.excerpt)]) })])
        }
        try await registry.register(manifest: Self.manifest("obsidian.read_note", "Read an exact Markdown note path inside the configured vault.", ["Read this Obsidian note"], ["path": .init(.string, required: true)])) { args, _ in guard let path = args["path"]?.string else { throw NexToolError.missingField("path") }; return Self.result("Read the Obsidian note.", path: path, content: try await provider.read(relativePath: path)) }
        try await registry.register(manifest: Self.manifest("obsidian.open_note", "Open an exact existing note in Obsidian using its URL scheme.", ["Open this note in Obsidian"], ["path": .init(.string, required: true)])) { args, _ in guard let path = args["path"]?.string else { throw NexToolError.missingField("path") }; try await provider.openNote(relativePath: path); return Self.result("Opened the Obsidian note.", path: path) }
        try await registry.register(manifest: Self.manifest("obsidian.create_note", "Create one UTF-8 Markdown note at a safe app-managed vault-relative path.", ["Create a note in Projects"], ["path": .init(.string, required: true), "content": .init(.string, required: true)], risk: .medium, confirmation: .always)) { args, _ in guard let path = args["path"]?.string, let content = args["content"]?.string else { throw NexToolError.missingField("path") }; return Self.result("Created the Obsidian note.", path: try await provider.create(relativePath: path, content: content)) }
        try await registry.register(manifest: Self.manifest("obsidian.update_note", "Atomically replace an exact Obsidian Markdown note while preserving the supplied frontmatter and formatting; return a diff.", ["Update this Obsidian note"], ["path": .init(.string, required: true), "content": .init(.string, required: true)], risk: .high, confirmation: .always)) { args, _ in guard let path = args["path"]?.string, let content = args["content"]?.string else { throw NexToolError.missingField("path") }; return Self.result("Updated the Obsidian note.", path: path, diff: try await provider.update(relativePath: path, content: content)) }
        try await registry.register(manifest: Self.manifest("obsidian.append_note", "Atomically append Markdown to an exact existing note and return a diff.", ["Append this decision to the note"], ["path": .init(.string, required: true), "content": .init(.string, required: true)], risk: .medium, confirmation: .always)) { args, _ in guard let path = args["path"]?.string, let content = args["content"]?.string else { throw NexToolError.missingField("path") }; return Self.result("Appended to the Obsidian note.", path: path, diff: try await provider.append(relativePath: path, content: content)) }
        registered = true
    }
    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "path": .init(.string, required: true), "content": .init(.string, required: true), "diff": .init(.string, required: true), "results": .init(.array, required: true)])
    private static func result(_ display: String, path: String = "", content: String = "", diff: String = "") -> NexJSONValue { .object(["display": .string(display), "status": .string("completed"), "path": .string(path), "content": .string(content), "diff": .string(diff), "results": .array([])]) }
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ fields: [String: NexToolFieldSchema], risk: NexComputerRiskClass = .low, confirmation: NexComputerConfirmationPolicy = .never) -> NexComputerActionManifest { .init(actionID: id, application: "Obsidian", provider: "Obsidian Vault", bundleIdentifier: "md.obsidian", description: description, examples: examples, aliases: [id.replacingOccurrences(of: ".", with: " ")], tags: ["obsidian", "notes", "markdown", "vault", "knowledge"], inputSchema: .init(fields: fields), outputSchema: output, implementationMethod: .nativeAPI, registryPermission: .files, riskClass: risk, confirmationPolicy: confirmation, availabilityCheck: .always, timeoutSeconds: 30, supportsCancellation: false, dryRunBehavior: .supported("Would perform \(id) directly on the configured Obsidian vault."), previewRenderer: "obsidian.note", tests: ["NexObsidianActionTests"]) }
}

// MARK: - Phase 13: Git and GitHub CLI

actor NexGitHubCLIProvider {
    struct CommandResult: Sendable { let stdout: String; let stderr: String; let exitCode: Int32 }
    func run(executable: String, arguments: [String], cwd: URL?) async throws -> CommandResult {
        guard ["/usr/bin/git", "/opt/homebrew/bin/gh", "/usr/local/bin/gh"].contains(executable), FileManager.default.isExecutableFile(atPath: executable) else { throw NexToolError.executionFailed(code: "cli_unavailable", message: "Required CLI is unavailable: \(executable)") }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process(), out = Pipe(), err = Pipe(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.currentDirectoryURL = cwd; process.standardOutput = out; process.standardError = err
            process.terminationHandler = { process in continuation.resume(returning: .init(stdout: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "", stderr: String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "", exitCode: process.terminationStatus)) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
    func git(_ args: [String], repository: URL) async throws -> CommandResult { let result = try await run(executable: "/usr/bin/git", arguments: ["-C", repository.path] + args, cwd: repository); guard result.exitCode == 0 else { throw NexToolError.executionFailed(code: "git_failed", message: result.stderr) }; return result }
    func gh(_ args: [String], repository: URL?) async throws -> CommandResult { let path = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile(atPath:)) ?? "/opt/homebrew/bin/gh"; let result = try await run(executable: path, arguments: args, cwd: repository); guard result.exitCode == 0 else { throw NexToolError.executionFailed(code: "github_failed", message: result.stderr) }; return result }
}

actor NexGitHubActionCatalog {
    private let cli: NexGitHubCLIProvider; private var registered = false
    init(cli: NexGitHubCLIProvider = NexGitHubCLIProvider()) { self.cli = cli }
    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }; let cli = cli
        try await registry.register(manifest: Self.manifest("github.open", "Open GitHub in the default browser.", ["Open GitHub"], [:], method: .urlScheme)) { _, _ in guard NSWorkspace.shared.open(URL(string: "https://github.com")!) else { throw NexToolError.executionFailed(code: "open_failed", message: "Could not open GitHub.") }; return Self.result("Opened GitHub.") }
        try await registry.register(manifest: Self.manifest(
            "git.status",
            "Read structured Git repository branch and working-tree state.",
            ["Show git status"],
            ["repository": .init(.string, required: true)],
            aliases: ["what changed in this repository", "working tree changes", "uncommitted changes"]
        )) { input, _ in
            let path = try required(input, "repository")
            let result = try await cli.git(["status", "--porcelain=v2", "--branch"], repository: URL(fileURLWithPath: path))
            return Self.result(result.stdout.isEmpty ? "No changes." : result.stdout, output: result.stdout)
        }
        try await registry.register(manifest: Self.manifest(
            "git.diff",
            "Read the current working-tree or explicitly requested staged Git diff without external diff drivers.",
            ["Show the current diff", "Show the staged changes"],
            ["repository": .init(.string, required: true), "staged": .init(.boolean, description: "Read the staged index diff instead of unstaged working-tree changes.")],
            aliases: ["what changed in this repository", "show code changes", "review my changes"]
        )) { input, _ in
            let path = try required(input, "repository")
            let arguments = input["staged"]?.bool == true
                ? ["diff", "--cached", "--no-ext-diff", "--"]
                : ["diff", "--no-ext-diff", "--"]
            let result = try await cli.git(arguments, repository: URL(fileURLWithPath: path))
            return Self.result(result.stdout.isEmpty ? "No changes." : result.stdout, output: result.stdout)
        }
        try await registry.register(manifest: Self.manifest(
            "git.init",
            "Initialize an explicitly supplied existing local directory as a new Git repository.",
            ["Initialize a new local Git repository here"],
            ["repository": .init(.string, required: true), "initialBranch": .init(.string, description: "Optional initial branch name; defaults to main.")],
            risk: .medium,
            confirmation: .always,
            aliases: ["initialize git repository", "start local repository"]
        )) { input, _ in
            let path = try required(input, "repository")
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw NexToolError.executionFailed(code: "repository_directory_missing", message: "Git initialization requires an existing directory.")
            }
            let branch = input["initialBranch"]?.string ?? "main"
            let result = try await cli.run(executable: "/usr/bin/git", arguments: ["init", "--initial-branch", branch, directory.path], cwd: directory.deletingLastPathComponent())
            guard result.exitCode == 0 else { throw NexToolError.executionFailed(code: "git_failed", message: result.stderr) }
            return Self.result(result.stdout.isEmpty ? "Initialized Git repository." : result.stdout, output: result.stdout)
        }
        try await registry.register(manifest: Self.manifest(
            "git.stage",
            "Stage explicitly supplied existing files inside one local Git repository; never stages all changes implicitly.",
            ["Stage this generated file for the local commit"],
            ["repository": .init(.string, required: true), "paths": .init(.stringArray, required: true, description: "One or more explicit existing file paths within the repository. Directories, wildcards, and paths outside the repository are rejected.")],
            risk: .medium,
            confirmation: .always,
            aliases: ["stage these files", "add file to git"]
        )) { input, _ in
            let root = URL(fileURLWithPath: try required(input, "repository"), isDirectory: true).standardizedFileURL
            let paths = try Self.stageablePaths(input, repository: root)
            let result = try await cli.git(["add", "--"] + paths, repository: root)
            return Self.result(result.stdout.isEmpty ? "Staged the selected Git files." : result.stdout, output: result.stdout)
        }
        try await registry.register(manifest: Self.manifest(
            "git.configure_remote",
            "Add one explicitly named Git remote to the supplied local repository without transferring data.",
            ["Connect this disposable repository to its generated backup remote"],
            ["repository": .init(.string, required: true), "name": .init(.string, required: true, description: "A new Git remote name using letters, digits, dots, underscores, or hyphens."), "url": .init(.string, required: true, description: "An explicit local, HTTPS, SSH, or Git remote URL.")],
            risk: .medium,
            confirmation: .always,
            aliases: ["connect a repository to a remote", "add a Git remote", "set up a backup remote"]
        )) { input, _ in
            let path = try required(input, "repository")
            let name = try Self.remoteName(input)
            let url = try required(input, "url")
            guard !url.contains("\u{0000}") else { throw NexToolError.executionFailed(code: "invalid_remote_url", message: "Git remote URLs cannot contain null characters.") }
            let result = try await cli.git(["remote", "add", name, url], repository: URL(fileURLWithPath: path))
            return Self.result(result.stdout.isEmpty ? "Configured the selected Git remote." : result.stdout, output: result.stdout)
        }
        let gitMutations: [(String, String, [String: NexToolFieldSchema], @Sendable ([String: NexJSONValue]) throws -> [String])] = [
            ("git.create_branch", "Create and check out a new local Git branch.", ["repository": .init(.string, required: true), "branch": .init(.string, required: true)], { ["switch", "-c", try required($0, "branch")] }),
            ("git.checkout", "Switch to an existing local Git branch.", ["repository": .init(.string, required: true), "branch": .init(.string, required: true)], { ["switch", try required($0, "branch")] }),
            ("git.pull", "Pull the configured upstream using fast-forward-only semantics.", ["repository": .init(.string, required: true)], { _ in ["pull", "--ff-only"] })
        ]
        for (id, description, fields, builder) in gitMutations {
            let aliases: [String]
            switch id {
            case "git.create_branch":
                aliases = ["start a separate local line of work", "begin isolated work", "work on a local branch"]
            case "git.checkout":
                aliases = ["return to the main line", "switch back to an existing branch", "go back to a branch"]
            case "git.pull":
                aliases = ["bring the latest changes from a remote", "update a local branch from its remote", "receive backup remote changes"]
            default:
                aliases = []
            }
            try await registry.register(manifest: Self.manifest(id, description, [description], fields, risk: id == "git.push" ? .high : .medium, confirmation: .always, aliases: aliases)) { input, _ in guard let path = input["repository"]?.string else { throw NexToolError.missingField("repository") }; let result = try await cli.git(try builder(input), repository: URL(fileURLWithPath: path)); return Self.result(result.stdout.isEmpty ? "Git action completed." : result.stdout, output: result.stdout) }
        }
        try await registry.register(manifest: Self.manifest(
            "git.commit",
            "Record the current staged Git changes as a local commit with an exact message; never stages implicitly.",
            ["Save the staged work as a local checkpoint"],
            ["repository": .init(.string, required: true), "message": .init(.string, required: true)],
            risk: .medium,
            confirmation: .always,
            aliases: ["save staged work", "record local checkpoint", "save the prepared change"]
        )) { input, _ in
            let path = try required(input, "repository")
            let result = try await cli.git(["commit", "-m", try required(input, "message")], repository: URL(fileURLWithPath: path))
            return Self.result(result.stdout.isEmpty ? "Git action completed." : result.stdout, output: result.stdout)
        }
        try await registry.register(manifest: Self.manifest(
            "git.push",
            "Push a local Git branch to its configured upstream, or explicitly establish an upstream on a named remote for the first push.",
            ["Back up this disposable branch to its remote"],
            ["repository": .init(.string, required: true), "remote": .init(.string, description: "Optional explicit remote for a first push; provide branch too."), "branch": .init(.string, description: "Optional explicit branch for a first push; provide remote too.")],
            risk: .high,
            confirmation: .always,
            aliases: ["back up a branch to its remote", "publish a local branch", "send a branch to a backup remote"]
        )) { input, _ in
            let path = try required(input, "repository")
            let remote = input["remote"]?.string
            let branch = input["branch"]?.string
            let arguments: [String]
            switch (remote, branch) {
            case let (.some(remote), .some(branch)) where !remote.isEmpty && !branch.isEmpty:
                arguments = ["push", "--set-upstream", remote, branch]
            case (nil, nil):
                arguments = ["push"]
            default:
                throw NexToolError.executionFailed(code: "push_target_incomplete", message: "Provide both remote and branch to establish an upstream, or neither to use the configured upstream.")
            }
            let result = try await cli.git(arguments, repository: URL(fileURLWithPath: path))
            return Self.result(result.stdout.isEmpty ? "Git push completed." : result.stdout, output: result.stdout)
        }
        try await registry.register(manifest: Self.manifest("github.search", "Search GitHub repositories, issues, or pull requests through authenticated gh.", ["Search GitHub for Nexus issues"], ["query": .init(.string, required: true), "type": .init(.string, allowedValues: ["repositories", "issues", "pull_requests"]), "limit": .init(.integer, minimum: 1, maximum: 100)], method: .cli)) { input, _ in
            let query = try required(input, "query"), type = input["type"]?.string ?? "repositories", command = type == "repositories" ? "repos" : "issues"; var args = ["search", command, query, "--limit", String(input["limit"]?.integer ?? 20), "--json", command == "repos" ? "nameWithOwner,url,description" : "title,url,repository,state"]
            if type == "pull_requests" { args += ["--include-prs"] }; let result = try await cli.gh(args, repository: nil); return Self.result("GitHub search completed.", output: result.stdout)
        }
        try await registry.register(manifest: Self.manifest("github.open_repository", "Open an exact GitHub repository URL or name.", ["Open v1shay/nexusV2"], ["repository": .init(.string, required: true)], method: .urlScheme)) { input, _ in let name = try required(input, "repository"); let url = name.hasPrefix("http") ? URL(string: name) : URL(string: "https://github.com/\(name)"); guard let url, NSWorkspace.shared.open(url) else { throw NexToolError.executionFailed(code: "invalid_repository", message: "Invalid GitHub repository.") }; return Self.result("Opened the GitHub repository.") }
        let remoteActions: [(String, String, [String: NexToolFieldSchema], @Sendable ([String: NexJSONValue]) throws -> [String])] = [
            ("github.create_issue", "Create a GitHub issue through authenticated gh.", ["repository": .init(.string, required: true), "title": .init(.string, required: true), "body": .init(.string, required: true)], { ["issue", "create", "--repo", try required($0, "repository"), "--title", try required($0, "title"), "--body", try required($0, "body")] }),
            ("github.create_pull_request", "Create a GitHub pull request through authenticated gh.", ["repository": .init(.string, required: true), "title": .init(.string, required: true), "body": .init(.string, required: true), "base": .init(.string, required: true)], { ["pr", "create", "--repo", try required($0, "repository"), "--title", try required($0, "title"), "--body", try required($0, "body"), "--base", try required($0, "base")] })
        ]
        for (id, description, fields, builder) in remoteActions { try await registry.register(manifest: Self.manifest(id, description, [description], fields, risk: .high, confirmation: .always)) { input, _ in let result = try await cli.gh(try builder(input), repository: nil); return Self.result("GitHub action completed.", output: result.stdout) } }
        try await registry.register(manifest: Self.manifest("github.open_pull_request", "Open an exact pull request URL or number for a repository.", ["Open PR 42"], ["repository": .init(.string, required: true), "number": .init(.integer, required: true, minimum: 1)])) { input, _ in let result = try await cli.gh(["pr", "view", String(input["number"]!.integer!), "--repo", try required(input, "repository"), "--web"], repository: nil); return Self.result("Opened the pull request.", output: result.stdout) }
        try await registry.register(manifest: Self.manifest("github.get_checks", "Read GitHub pull-request checks through authenticated gh.", ["Show PR checks"], ["repository": .init(.string, required: true), "number": .init(.integer, required: true, minimum: 1)])) { input, _ in let result = try await cli.gh(["pr", "checks", String(input["number"]!.integer!), "--repo", try required(input, "repository"), "--json", "name,state,bucket,link"], repository: nil); return Self.result("Read GitHub checks.", output: result.stdout) }
        registered = true
    }
    private static func validatedString(_ input: [String: NexJSONValue], _ key: String) throws -> String { guard let value = input[key]?.string, !value.isEmpty else { throw NexToolError.missingField(key) }; return value }
    private static func stageablePaths(_ input: [String: NexJSONValue], repository: URL) throws -> [String] {
        guard let supplied = input["paths"]?.strings, !supplied.isEmpty else { throw NexToolError.missingField("paths") }
        let root = repository.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return try supplied.map { raw in
            guard !raw.isEmpty, !raw.contains("*") && !raw.contains("?") else {
                throw NexToolError.executionFailed(code: "invalid_stage_path", message: "Git staging requires explicit file paths without wildcards.")
            }
            let candidate = (raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : root.appendingPathComponent(raw)).standardizedFileURL
            guard candidate.path.hasPrefix(rootPrefix) else {
                throw NexToolError.executionFailed(code: "stage_path_outside_repository", message: "Git staging paths must stay inside the supplied repository.")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw NexToolError.executionFailed(code: "stage_file_missing", message: "Git staging requires an existing file, not a directory.")
            }
            return String(candidate.path.dropFirst(rootPrefix.count))
        }
    }
    private static func remoteName(_ input: [String: NexJSONValue]) throws -> String {
        let name = try required(input, "name")
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw NexToolError.executionFailed(code: "invalid_remote_name", message: "Git remote names must begin with a letter or digit and contain only letters, digits, dots, underscores, or hyphens.")
        }
        return name
    }
    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "output": .init(.string, required: true)])
    private static func result(_ display: String, output: String = "") -> NexJSONValue { .object(["display": .string(display), "status": .string("completed"), "output": .string(output)]) }
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ fields: [String: NexToolFieldSchema], method: NexComputerImplementationMethod = .cli, risk: NexComputerRiskClass = .low, confirmation: NexComputerConfirmationPolicy = .never, aliases additionalAliases: [String] = []) -> NexComputerActionManifest { .init(actionID: id, application: id.hasPrefix("git.") ? "Git" : "GitHub", provider: id.hasPrefix("git.") ? "Git CLI" : "GitHub CLI", description: description, examples: examples, aliases: [id.replacingOccurrences(of: ".", with: " ")] + additionalAliases, tags: ["git", "github", "repository", "code", "pull request", "issue"], inputSchema: .init(fields: fields), outputSchema: output, implementationMethod: method, registryPermission: risk == .low ? .files : .codeExecution, riskClass: risk, confirmationPolicy: confirmation, availabilityCheck: method == .urlScheme ? .always : .executable(paths: id.hasPrefix("git.") ? ["/usr/bin/git"] : ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]), timeoutSeconds: 120, supportsCancellation: true, dryRunBehavior: .supported("Would perform \(id) through validated argv."), previewRenderer: id.hasPrefix("git.") ? "git.action" : "github.action", tests: ["NexGitHubActionTests"]) }
}

private func required(_ input: [String: NexJSONValue], _ key: String) throws -> String { guard let value = input[key]?.string, !value.isEmpty else { throw NexToolError.missingField(key) }; return value }

// MARK: - Phase 14: macOS system state

actor NexSystemProvider {
    func openSetting(_ pane: String) throws {
        let allowed: [String: String] = ["general": "com.apple.General-Settings.extension", "display": "com.apple.Displays-Settings.extension", "sound": "com.apple.Sound-Settings.extension", "network": "com.apple.Network-Settings.extension", "focus": "com.apple.Focus-Settings.extension", "privacy": "com.apple.settings.PrivacySecurity.extension", "battery": "com.apple.Battery-Settings.extension"]
        guard let id = allowed[pane], let url = URL(string: "x-apple.systempreferences:\(id)"), NSWorkspace.shared.open(url) else { throw NexToolError.invalidEnum(field: "pane", allowed: Array(allowed.keys).sorted()) }
    }
    func getVolume() throws -> Int { Int(try appleScript("output volume of (get volume settings)")) ?? 0 }
    func setVolume(_ value: Int) throws { guard 0...100 ~= value else { throw NexToolError.outOfRange(field: "volume", minimum: 0, maximum: 100) }; _ = try appleScript("set volume output volume \(value)") }
    func displayState() -> NexJSONValue {
        .array(NSScreen.screens.map { screen in .object(["name": .string(screen.localizedName), "width": .number(screen.frame.width), "height": .number(screen.frame.height), "scale": .number(screen.backingScaleFactor), "main": .bool(screen == NSScreen.main)]) })
    }
    func batteryState() async throws -> String { try await command("/usr/bin/pmset", ["-g", "batt"]) }
    func networkState() async throws -> String { try await command("/usr/sbin/scutil", ["--nwi"]) }
    func focusUnsupported() throws -> Never { throw NexToolError.executionFailed(code: "unsupported_on_macos", message: "macOS exposes no stable public API for changing Focus mode. Nexus can open Focus settings but will not fake or UI-click the state.") }
    private func appleScript(_ source: String) throws -> String { var error: NSDictionary?; let result = NSAppleScript(source: source)?.executeAndReturnError(&error); if let error { throw NexToolError.executionFailed(code: "system_automation_failed", message: error.description) }; return result?.stringValue ?? result?.description ?? "" }
    private func command(_ executable: String, _ arguments: [String]) async throws -> String { try await withCheckedThrowingContinuation { continuation in let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.standardOutput = pipe; process.standardError = pipe; process.terminationHandler = { process in let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; process.terminationStatus == 0 ? continuation.resume(returning: output) : continuation.resume(throwing: NexToolError.executionFailed(code: "system_command_failed", message: output)) }; do { try process.run() } catch { continuation.resume(throwing: error) } } }
}

actor NexSystemActionCatalog {
    private let provider: NexSystemProvider; private var registered = false
    init(provider: NexSystemProvider = NexSystemProvider()) { self.provider = provider }
    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }; let provider = provider
        try await registry.register(manifest: Self.manifest("system.open_setting", "Open the user-requested macOS System Settings pane—general, display, sound, network, focus, privacy, or battery—without changing privacy or security state.", ["Open Display settings"], ["pane": .init(.string, required: true, description: "The allowed macOS Settings pane that semantically matches the user's requested setting.", allowedValues: ["general", "display", "sound", "network", "focus", "privacy", "battery"])], risk: .low)) { args, _ in guard let pane = args["pane"]?.string else { throw NexToolError.missingField("pane") }; try await provider.openSetting(pane); return Self.result("Opened \(pane) settings.") }
        try await registry.register(manifest: Self.manifest("system.get_volume", "Read the current macOS output volume from zero to one hundred.", ["What is the volume?"], [:], risk: .low)) { _, _ in let value = try await provider.getVolume(); return Self.result("Volume is \(value)%.", value: value) }
        try await registry.register(manifest: Self.manifest("system.set_volume", "Set macOS output volume to an exact validated value from zero to one hundred.", ["Set volume to 30 percent"], ["volume": .init(.integer, required: true, minimum: 0, maximum: 100)], risk: .medium, confirmation: .always)) { args, _ in guard let value = args["volume"]?.integer else { throw NexToolError.missingField("volume") }; try await provider.setVolume(value); return Self.result("Set volume to \(value)%.", value: value) }
        try await registry.register(manifest: Self.manifest("system.get_display_state", "Read connected display names, sizes, scale factors, and main-display state.", ["Show my displays"], [:], risk: .low)) { _, _ in let displays = await provider.displayState(); return Self.result("Read display state.", items: displays) }
        try await registry.register(manifest: Self.manifest("system.toggle_focus_mode", "Focus mode cannot be changed through a stable public macOS API; this action fails explicitly and directs the user to Focus settings.", ["Turn on Focus mode"], ["enabled": .init(.boolean, required: true)], risk: .medium, confirmation: .always, availability: .unsupported("macOS exposes no stable public Focus-mode mutation API; use system.open_setting with pane focus."))) { _, _ in try await provider.focusUnsupported() }
        try await registry.register(manifest: Self.manifest("system.get_battery", "Read current macOS battery and power-source state through pmset.", ["How much battery is left?"], [:], risk: .low)) { _, _ in let output = try await provider.batteryState(); return Self.result(output.trimmingCharacters(in: .whitespacesAndNewlines), raw: output) }
        try await registry.register(manifest: Self.manifest("system.get_network_state", "Read whether this Mac is online, including Wi-Fi or Ethernet interface details and Internet reachability, without changing network configuration.", ["Is my Mac online?"], [:], risk: .low)) { _, _ in let output = try await provider.networkState(); return Self.result("Read network state.", raw: output) }
        registered = true
    }
    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "value": .init(.integer, required: true), "raw": .init(.string, required: true), "items": .init(.array, required: true)])
    private static func result(_ display: String, value: Int = 0, raw: String = "", items: NexJSONValue = .array([])) -> NexJSONValue { .object(["display": .string(display), "status": .string("completed"), "value": .number(Double(value)), "raw": .string(raw), "items": items]) }
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ fields: [String: NexToolFieldSchema], risk: NexComputerRiskClass, confirmation: NexComputerConfirmationPolicy = .never, availability: NexComputerAvailabilityCheck = .always) -> NexComputerActionManifest { .init(actionID: id, application: "macOS", provider: "System", description: description, examples: examples, aliases: [id.replacingOccurrences(of: ".", with: " ")], tags: ["system", "settings", "macos", "battery", "network", "display", "volume", "focus"], inputSchema: .init(fields: fields), outputSchema: output, implementationMethod: id == "system.open_setting" ? .urlScheme : .nativeAPI, registryPermission: .automation, riskClass: risk, confirmationPolicy: confirmation, availabilityCheck: availability, timeoutSeconds: 20, supportsCancellation: false, dryRunBehavior: .supported("Would perform \(id) without changing privacy or network configuration."), previewRenderer: "system.state", tests: ["NexSystemActionTests"]) }
}

// MARK: - Phase 15: Xcode

actor NexXcodeProvider {
    struct Snapshot: Sendable { let status: String; let output: String; let diagnostics: [String]; let tests: String; let artifactPaths: [String] }
    private var last = Snapshot(status: "idle", output: "", diagnostics: [], tests: "", artifactPaths: [])
    func open(path: URL?) async throws { if let path { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xed"); p.arguments = [path.path]; try p.run() } else { guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else { throw NexToolError.executionFailed(code: "xcode_unavailable", message: "Xcode is not installed.") }; _ = try await NSWorkspace.shared.openApplication(at: app, configuration: .init()) } }
    func run(action: String, container: URL, scheme: String, configuration: String, destination: String?, progress: @escaping @Sendable (String) async -> Void) async throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: container.path) else { throw NexToolError.executionFailed(code: "xcode_container_missing", message: "Xcode project or workspace was not found.") }
        var args = [container.pathExtension == "xcworkspace" ? "-workspace" : "-project", container.path, "-scheme", scheme, "-configuration", configuration]
        if let destination, !destination.isEmpty { args += ["-destination", destination] }; args.append(action)
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild"); process.arguments = args; process.standardOutput = pipe; process.standardError = pipe; try process.run()
        var lines: [String] = []; for try await line in pipe.fileHandleForReading.bytes.lines { lines.append(line); if line.contains("warning:") || line.contains("error:") || line.contains("Test Case") { await progress(String(line.prefix(500))) } }; process.waitUntilExit()
        let output = lines.joined(separator: "\n"), diagnostics = lines.filter { $0.contains("warning:") || $0.contains("error:") }, tests = lines.filter { $0.contains("Test Case") || $0.contains("Executed ") || $0.contains("TEST SUCCEEDED") || $0.contains("TEST FAILED") }.suffix(100).joined(separator: "\n")
        let artifacts = lines.compactMap { line -> String? in guard let range = line.range(of: #"/[^ ]+\.(app|xcresult)"#, options: .regularExpression) else { return nil }; return String(line[range]) }
        let snapshot = Snapshot(status: process.terminationStatus == 0 ? "succeeded" : "failed", output: String(output.suffix(100_000)), diagnostics: diagnostics, tests: tests, artifactPaths: Array(Set(artifacts)).sorted()); last = snapshot
        if process.terminationStatus != 0 { throw NexToolError.executionFailed(code: "xcodebuild_failed", message: String(output.suffix(4_000))) }; return snapshot
    }
    func status() -> Snapshot { last }
}

actor NexXcodeActionCatalog {
    private let provider: NexXcodeProvider; private var registered = false
    init(provider: NexXcodeProvider = NexXcodeProvider()) { self.provider = provider }
    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }; let provider = provider
        try await registry.register(manifest: Self.manifest("xcode.open", "Open or activate Xcode.", ["Open Xcode"], [:])) { _, _ in try await provider.open(path: nil); return Self.result("Opened Xcode.") }
        try await registry.register(manifest: Self.manifest("xcode.open_project", "Open an existing Xcode project or workspace with xed.", ["Open this Xcode project"], ["path": .init(.string, required: true)])) { args, _ in let path = try required(args, "path"); try await provider.open(path: URL(fileURLWithPath: path)); return Self.result("Opened the Xcode project.") }
        try await registry.register(manifest: Self.manifest("xcode.open_file", "Open an existing source file with xed.", ["Open this file in Xcode"], ["path": .init(.string, required: true)])) { args, _ in let path = try required(args, "path"); try await provider.open(path: URL(fileURLWithPath: path)); return Self.result("Opened the file in Xcode.") }
        for (id, action, example) in [("xcode.build", "build", "Build this Xcode scheme"), ("xcode.test", "test", "Test this Xcode scheme"), ("xcode.run", "build", "Run this Xcode scheme")] {
            let description = id == "xcode.run"
                ? "Launch the selected Xcode scheme through its Run command with an explicit project/workspace, configuration, and optional destination."
                : "Run xcodebuild \(action) with an explicit project/workspace, scheme, configuration, and optional destination."
            try await registry.register(manifest: Self.manifest(id, description, [example], ["path": .init(.string, required: true), "scheme": .init(.string, required: true), "configuration": .init(.string), "destination": .init(.string)], risk: .medium, confirmation: .always, aliases: id == "xcode.run" ? ["run Xcode scheme", "run this scheme"] : [])) { args, context in
                let snapshot = try await provider.run(action: action, container: URL(fileURLWithPath: try required(args, "path")), scheme: try required(args, "scheme"), configuration: args["configuration"]?.string ?? "Debug", destination: args["destination"]?.string) { await context.reportProgress($0, nil) }; return Self.result(snapshot)
            }
        }
        try await registry.register(manifest: Self.manifest("xcode.get_build_status", "Return the latest structured xcodebuild status and diagnostics.", ["How did the Xcode build go?"], [:])) { _, _ in Self.result(await provider.status()) }
        registered = true
    }
    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "output": .init(.string, required: true), "diagnostics": .init(.stringArray, required: true), "tests": .init(.string, required: true), "artifacts": .init(.stringArray, required: true)])
    private static func result(_ display: String) -> NexJSONValue { .object(["display": .string(display), "status": .string("completed"), "output": .string(""), "diagnostics": .array([]), "tests": .string(""), "artifacts": .array([])]) }
    private static func result(_ s: NexXcodeProvider.Snapshot) -> NexJSONValue { .object(["display": .string("Xcode \(s.status)."), "status": .string(s.status), "output": .string(s.output), "diagnostics": .array(s.diagnostics.map(NexJSONValue.string)), "tests": .string(s.tests), "artifacts": .array(s.artifactPaths.map(NexJSONValue.string))]) }
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ fields: [String: NexToolFieldSchema], risk: NexComputerRiskClass = .low, confirmation: NexComputerConfirmationPolicy = .never, aliases additionalAliases: [String] = []) -> NexComputerActionManifest { .init(actionID: id, application: "Xcode", provider: "xcodebuild/xed", bundleIdentifier: "com.apple.dt.Xcode", description: description, examples: examples, aliases: [id.replacingOccurrences(of: ".", with: " ")] + additionalAliases, tags: ["xcode", "build", "test", "swift", "developer"], inputSchema: .init(fields: fields), outputSchema: output, implementationMethod: .cli, registryPermission: risk == .low ? .files : .codeExecution, riskClass: risk, confirmationPolicy: confirmation, availabilityCheck: .executable(paths: ["/usr/bin/xcodebuild"]), timeoutSeconds: 300, supportsCancellation: true, dryRunBehavior: .supported("Would run \(id) with explicit xcodebuild arguments."), previewRenderer: "xcode.build", tests: ["NexXcodeActionTests"]) }
}

// MARK: - Phase 16: Preview and documents

actor NexPreviewProvider {
    func open(_ file: URL, page: Int? = nil) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { throw NexToolError.executionFailed(code: "document_missing", message: "Document was not found.") }
        var target = file; if let page { guard page > 0 else { throw NexToolError.outOfRange(field: "page", minimum: 1, maximum: nil) }; if let url = URL(string: file.absoluteString + "#page=\(page)") { target = url } }
        guard NSWorkspace.shared.open(target) else { throw NexToolError.executionFailed(code: "preview_open_failed", message: "macOS could not open the document.") }
    }
    func export(source: URL, destination: URL, overwrite: Bool) throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else { throw NexToolError.executionFailed(code: "document_missing", message: "Source document was not found.") }
        if FileManager.default.fileExists(atPath: destination.path), !overwrite { throw NexToolError.executionFailed(code: "destination_exists", message: "Destination exists; choose a new path or explicitly allow overwrite.") }
        let sourceExt = source.pathExtension.lowercased(), targetExt = destination.pathExtension.lowercased()
        if sourceExt == "pdf", targetExt == "pdf" { try FileManager.default.copyItem(at: source, to: destination); return destination }
        guard let image = NSImage(contentsOf: source), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { throw NexToolError.executionFailed(code: "unsupported_conversion", message: "This native document conversion is unsupported.") }
        let data: Data? = targetExt == "png" ? bitmap.representation(using: .png, properties: [:]) : (["jpg", "jpeg"].contains(targetExt) ? bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) : nil)
        guard let data else { throw NexToolError.executionFailed(code: "unsupported_conversion", message: "Supported image exports are PNG and JPEG.") }; try data.write(to: destination, options: .atomic); return destination
    }
    func combine(inputs: [URL], output: URL, overwrite: Bool) throws -> (URL, Int) {
        guard !inputs.isEmpty else { throw NexToolError.executionFailed(code: "missing_documents", message: "Provide at least one PDF.") }; if FileManager.default.fileExists(atPath: output.path), !overwrite { throw NexToolError.executionFailed(code: "destination_exists", message: "Output exists; choose a new path or explicitly allow overwrite.") }
        let combined = PDFDocument(); var pageIndex = 0
        for input in inputs { guard input.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: input) else { throw NexToolError.executionFailed(code: "invalid_pdf", message: "Could not read \(input.lastPathComponent).") }; for index in 0..<document.pageCount { if let page = document.page(at: index) { combined.insert(page, at: pageIndex); pageIndex += 1 } } }
        guard combined.write(to: output) else { throw NexToolError.executionFailed(code: "pdf_write_failed", message: "Could not write the combined PDF.") }; return (output, pageIndex)
    }
}

actor NexPreviewActionCatalog {
    private let provider: NexPreviewProvider; private var registered = false
    init(provider: NexPreviewProvider = NexPreviewProvider()) { self.provider = provider }
    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }; let provider = provider
        for (id, page) in [("preview.open", false), ("preview.open_at_page", true)] { var fields: [String: NexToolFieldSchema] = ["path": .init(.string, required: true)]; if page { fields["page"] = .init(.integer, required: true, minimum: 1) }; try await registry.register(manifest: Self.manifest(id, page ? "Open a PDF with a page fragment hint where Preview supports it." : "Open a supported document with the default macOS Preview handler.", [page ? "Open this PDF at page 4" : "Open this document"], fields)) { args, _ in let path = try required(args, "path"); try await provider.open(URL(fileURLWithPath: path), page: args["page"]?.integer); return Self.result("Opened the document.", path: path) } }
        try await registry.register(manifest: Self.manifest("preview.export", "Export a supported image to PNG/JPEG or copy PDF to a distinct validated destination.", ["Export this image as PNG"], ["source": .init(.string, required: true), "destination": .init(.string, required: true), "overwrite": .init(.boolean)], risk: .medium, confirmation: .always)) { args, _ in let output = try await provider.export(source: URL(fileURLWithPath: try required(args, "source")), destination: URL(fileURLWithPath: try required(args, "destination")), overwrite: args["overwrite"]?.bool ?? false); return Self.result("Exported the document.", path: output.path) }
        try await registry.register(manifest: Self.manifest("preview.combine_pdfs", "Combine validated PDFs in the supplied order into a distinct output file.", ["Combine these PDFs in order"], ["inputs": .init(.stringArray, required: true), "output": .init(.string, required: true), "overwrite": .init(.boolean)], risk: .medium, confirmation: .always)) { args, _ in guard let inputs = args["inputs"]?.strings else { throw NexToolError.missingField("inputs") }; let result = try await provider.combine(inputs: inputs.map(URL.init(fileURLWithPath:)), output: URL(fileURLWithPath: try required(args, "output")), overwrite: args["overwrite"]?.bool ?? false); return Self.result("Combined \(result.1) PDF pages.", path: result.0.path, count: result.1) }
        registered = true
    }
    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "path": .init(.string, required: true), "page_count": .init(.integer, required: true)])
    private static func result(_ display: String, path: String = "", count: Int = 0) -> NexJSONValue { .object(["display": .string(display), "status": .string("completed"), "path": .string(path), "page_count": .number(Double(count))]) }
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ fields: [String: NexToolFieldSchema], risk: NexComputerRiskClass = .low, confirmation: NexComputerConfirmationPolicy = .never) -> NexComputerActionManifest { .init(actionID: id, application: "Preview", provider: "PDFKit/AppKit", bundleIdentifier: "com.apple.Preview", description: description, examples: examples, aliases: [id.replacingOccurrences(of: ".", with: " ")], tags: ["preview", "pdf", "document", "image", "export"], inputSchema: .init(fields: fields), outputSchema: output, implementationMethod: .nativeAPI, registryPermission: .files, riskClass: risk, confirmationPolicy: confirmation, availabilityCheck: .application(bundleIdentifier: "com.apple.Preview"), timeoutSeconds: 60, supportsCancellation: false, dryRunBehavior: .supported("Would perform \(id) with native document APIs."), previewRenderer: "preview.document", tests: ["NexPreviewActionTests"]) }
}

// MARK: - Phase 17: LaunchServices application discovery

actor NexApplicationActionCatalog {
    private var registered = false
    func register(on registry: NexComputerRegistry) async throws {
        guard !registered else { return }
        try await registry.register(manifest: Self.manifest("applications.list", "List installed applications with stable names and bundle identifiers; no automation capability is implied.", ["List installed apps"], [:])) { _, _ in
            let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]; var apps: [NexJSONValue] = []
            for root in roots { guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }; for url in urls where url.pathExtension == "app" { let bundle = Bundle(url: url); apps.append(.object(["name": .string(url.deletingPathExtension().lastPathComponent), "bundle_id": .string(bundle?.bundleIdentifier ?? ""), "path": .string(url.path)])) } }
            return .object(["display": .string("Found \(apps.count) installed applications."), "status": .string("completed"), "apps": .array(apps)])
        }
        try await registry.register(manifest: Self.manifest("applications.open", "Open or activate an installed application by its exact bundle identifier through LaunchServices.", ["Open Discord", "Activate Blender"], ["bundle_id": .init(.string, required: true)])) { args, _ in
            guard let id = args["bundle_id"]?.string, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { throw NexToolError.executionFailed(code: "application_unavailable", message: "No installed application has that bundle identifier.") }
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true; _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return .object(["display": .string("Opened \(url.deletingPathExtension().lastPathComponent)."), "status": .string("completed"), "apps": .array([])])
        }
        registered = true
    }
    private static let output = NexToolInputSchema(fields: ["display": .init(.string, required: true), "status": .init(.string, required: true), "apps": .init(.array, required: true)])
    private static func manifest(_ id: String, _ description: String, _ examples: [String], _ fields: [String: NexToolFieldSchema]) -> NexComputerActionManifest { .init(actionID: id, application: "Applications", provider: "LaunchServices", description: description, examples: examples, aliases: ["open app", "activate app", "installed applications"], tags: ["application", "dock", "launch", "open", "activate"], inputSchema: .init(fields: fields), outputSchema: output, implementationMethod: .nativeAPI, registryPermission: .automation, riskClass: .low, confirmationPolicy: .never, availabilityCheck: .always, timeoutSeconds: 20, supportsCancellation: false, dryRunBehavior: .supported("Would query or open an exact installed application."), previewRenderer: "application.open", tests: ["NexApplicationActionTests"]) }
}
