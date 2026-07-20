import Foundation

/// A small read-only bridge to Codex Desktop's local JSONL event log. Codex
/// owns the log; Nexus only tails completed lines and never writes to or
/// controls Codex.
enum CodexProgressKind: Equatable, Sendable {
    case thinking
    case terminal
    case writing
    case git

    var label: String {
        switch self {
        case .thinking: "Thinking"
        case .terminal: "Running command"
        case .writing: "Writing files"
        case .git: "Updating GitHub"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .thinking: "brain.head.profile"
        case .terminal: "terminal"
        case .writing: "chevron.left.forwardslash.chevron.right"
        case .git: "arrow.triangle.merge"
        }
    }
}

struct CodexProgressUpdate: Equatable, Sendable {
    let kind: CodexProgressKind
    let detail: String
    let phase: NexToolLifecyclePhase
}

enum CodexProgressParser {
    static func parse(line: String) -> CodexProgressUpdate? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envelope = root["type"] as? String,
              let payload = root["payload"] as? [String: Any] else { return nil }

        if envelope == "event_msg", let type = payload["type"] as? String {
            switch type {
            case "task_started":
                return .init(kind: .thinking, detail: "Thinking…", phase: .started)
            case "task_complete":
                return .init(kind: .thinking, detail: "Task complete", phase: .completed)
            case "task_failed":
                return .init(kind: .thinking, detail: "Codex task failed", phase: .failed)
            case "agent_message":
                guard payload["phase"] as? String == "commentary",
                      let message = normalized(payload["message"] as? String) else { return nil }
                return .init(kind: .thinking, detail: message, phase: .progress)
            default:
                return nil
            }
        }

        guard envelope == "response_item",
              payload["type"] as? String == "custom_tool_call",
              let name = payload["name"] as? String else { return nil }
        let input = payload["input"] as? String ?? ""
        let kind = classify(toolName: name, input: input)
        let detail = actionLine(toolName: name, input: input, kind: kind)
        return .init(kind: kind, detail: detail, phase: .progress)
    }

    static func classify(toolName: String, input: String) -> CodexProgressKind {
        let normalizedName = toolName.lowercased()
        let command = command(from: input)?.lowercased() ?? input.lowercased()
        if normalizedName == "apply_patch" || normalizedName.contains("write") || normalizedName.contains("edit") {
            return .writing
        }
        if command.contains("git ") || command.hasPrefix("git") || command.contains("gh ") {
            return .git
        }
        if normalizedName == "exec" || normalizedName == "write_stdin" || normalizedName.contains("command") {
            return .terminal
        }
        return .thinking
    }

    static func actionLine(toolName: String, input: String, kind: CodexProgressKind) -> String {
        if let command = command(from: input), let normalized = normalized(command) {
            return normalized
        }
        if kind == .writing, let path = updatedFile(from: input) {
            return "Updating \(path)"
        }
        return "Codex: \(toolName.replacingOccurrences(of: "_", with: " "))"
    }

    private static func command(from input: String) -> String? {
        guard let range = input.range(of: "\"cmd\":\"") else { return nil }
        let suffix = input[range.upperBound...]
        guard let end = suffix.range(of: "\",\"justification\"") ?? suffix.range(of: "\",\"login\"") ?? suffix.range(of: "\",\"workdir\"") else {
            return nil
        }
        return String(suffix[..<end.lowerBound])
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func updatedFile(from input: String) -> String? {
        guard let range = input.range(of: "*** Update File: ") ?? input.range(of: "*** Add File: ") else { return nil }
        let suffix = input[range.upperBound...]
        return normalized(String(suffix.prefix { $0 != "\\" && $0 != "\n" }))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let compact = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? nil : compact
    }
}

@MainActor
final class CodexProgressMonitor {
    typealias UpdateHandler = (CodexProgressUpdate) -> Void

    private let sessionsRoot: URL
    private let fileManager: FileManager
    private var task: Task<Void, Never>?
    private var currentFile: URL?
    private var readOffset: UInt64 = 0
    private var lastDiscovery = Date.distantPast
    private var handler: UpdateHandler?

    init(
        sessionsRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.sessionsRoot = sessionsRoot ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func start(onUpdate: @escaping UpdateHandler) {
        guard task == nil else { return }
        handler = onUpdate
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        handler = nil
    }

    private func poll() {
        if Date().timeIntervalSince(lastDiscovery) > 1.5 {
            lastDiscovery = Date()
            let newest = newestSessionFile()
            if newest != currentFile {
                currentFile = newest
                // Start near the end of a pre-existing log. This keeps Nexus
                // focused on the live Codex task instead of replaying an
                // entire past session when it launches.
                let size: UInt64
                if let newest,
                   let attributes = try? fileManager.attributesOfItem(atPath: newest.path),
                   let fileSize = (attributes[.size] as? NSNumber)?.uint64Value {
                    size = fileSize
                } else {
                    size = 0
                }
                readOffset = size > 131_072 ? size - 131_072 : 0
            }
        }
        guard let currentFile else { return }
        readNewLines(from: currentFile)
    }

    private func newestSessionFile() -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate else { continue }
            if newest == nil || date > newest!.date { newest = (url, date) }
        }
        return newest?.url
    }

    private func readNewLines(from file: URL) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return }
        if size < readOffset { readOffset = 0 }
        guard size > readOffset,
              let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: readOffset)
            let data = try handle.readToEnd() ?? Data()
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
            let completedData = data[...lastNewline]
            readOffset += UInt64(completedData.count)
            guard let text = String(data: completedData, encoding: .utf8) else { return }
            text.split(separator: "\n", omittingEmptySubsequences: true).forEach {
                if let update = CodexProgressParser.parse(line: String($0)) { handler?(update) }
            }
        } catch {
            return
        }
    }
}
