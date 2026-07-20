import Foundation

/// A small read-only bridge to Codex Desktop's local JSONL event log. Codex
/// owns the log; Nexus only tails completed lines and never writes to or
/// controls Codex.
enum CodexProgressKind: Equatable, Sendable {
    case thinking
    case terminal
    case writing
    case reading
    case image
    case git

    var label: String {
        switch self {
        case .thinking: "Thinking"
        case .terminal: "Running command"
        case .writing: "Writing files"
        case .reading: "Reading files"
        case .image: "Viewing image"
        case .git: "Updating GitHub"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .thinking: "brain.head.profile"
        case .terminal: "terminal"
        case .writing: "chevron.left.forwardslash.chevron.right"
        case .reading: "book.closed"
        case .image: "photo"
        case .git: "arrow.triangle.merge"
        }
    }
}

struct CodexProgressUpdate: Equatable, Sendable {
    let kind: CodexProgressKind
    let detail: String
    let phase: NexToolLifecyclePhase
    let sessionID: String
    let taskTitle: String?

    init(
        kind: CodexProgressKind,
        detail: String,
        phase: NexToolLifecyclePhase,
        sessionID: String = "",
        taskTitle: String? = nil
    ) {
        self.kind = kind
        self.detail = detail
        self.phase = phase
        self.sessionID = sessionID
        self.taskTitle = taskTitle
    }
}

struct CodexSessionProgress: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let lastActivity: Date
    let latestUpdate: CodexProgressUpdate

    var isComplete: Bool { latestUpdate.phase == .completed || latestUpdate.phase == .failed }
}

/// The primary Codex rolling quota emitted in the local JSONL stream. This is
/// read-only account telemetry; Nexus never requests, changes, or estimates it.
struct CodexUsageLimit: Equatable, Sendable {
    let usedPercent: Double
    let resetsAt: Date

    var compactLabel: String {
        let date = Calendar.current.dateComponents([.month, .day], from: resetsAt)
        return "\(Int(usedPercent.rounded()))% · \(date.month ?? 0)/\(date.day ?? 0)"
    }

    static func parse(line: String) -> CodexUsageLimit? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let limits = info["rate_limits"] as? [String: Any],
              let primary = limits["primary"] as? [String: Any],
              let used = primary["used_percent"] as? Double,
              let reset = primary["resets_at"] as? TimeInterval else { return nil }
        return CodexUsageLimit(usedPercent: min(max(used, 0), 100), resetsAt: Date(timeIntervalSince1970: reset))
    }
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
        if normalizedName.contains("image") || normalizedName.contains("screenshot") || looksLikeImage(command) {
            return .image
        }
        if normalizedName == "apply_patch" || normalizedName.contains("write") || normalizedName.contains("edit") {
            return .writing
        }
        if command.contains("git ") || command.hasPrefix("git") || command.contains("gh ") {
            return .git
        }
        if normalizedName == "exec" || normalizedName == "write_stdin" || normalizedName.contains("command") {
            if isReadOnlyCommand(command) { return .reading }
            return .terminal
        }
        return .thinking
    }

    private static func looksLikeImage(_ text: String) -> Bool {
        [".png", ".jpg", ".jpeg", ".webp", ".heic", ".gif", ".svg", ".tiff"].contains { text.contains($0) }
    }

    private static func isReadOnlyCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["cat ", "sed ", "rg ", "grep ", "head ", "tail ", "find ", "ls", "stat ", "jq ", "awk ", "wc "]
            .contains { trimmed.hasPrefix($0) }
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
    typealias UpdateHandler = (CodexProgressUpdate, [CodexSessionProgress]) -> Void
    typealias UsageHandler = (CodexUsageLimit) -> Void

    private struct SessionState {
        let url: URL
        var readOffset: UInt64
        var title = "Codex task"
        var latestUpdate: CodexProgressUpdate?
        var lastActivity = Date.distantPast
    }

    private let sessionsRoot: URL
    private let fileManager: FileManager
    private var task: Task<Void, Never>?
    private var sessions: [URL: SessionState] = [:]
    private var lastDiscovery = Date.distantPast
    private var handler: UpdateHandler?
    private var usageHandler: UsageHandler?

    init(
        sessionsRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.sessionsRoot = sessionsRoot ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func start(onUpdate: @escaping UpdateHandler, onUsage: @escaping UsageHandler) {
        guard task == nil else { return }
        handler = onUpdate
        usageHandler = onUsage
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
        usageHandler = nil
    }

    private func poll() {
        if Date().timeIntervalSince(lastDiscovery) > 1.5 {
            lastDiscovery = Date()
            refreshActiveSessions()
        }
        for file in sessions.keys { readNewLines(from: file) }
    }

    private func refreshActiveSessions() {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-12 * 60 * 60)
        var discovered = Set<URL>()
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate,
                  date >= cutoff else { continue }
            discovered.insert(url)
            guard sessions[url] == nil else { continue }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            // A bounded initial tail identifies recent task state without
            // replaying hours of unrelated Codex history into the notch.
            sessions[url] = SessionState(url: url, readOffset: size > 262_144 ? size - 262_144 : 0, lastActivity: date)
        }
        sessions = sessions.filter { discovered.contains($0.key) }
    }

    private func readNewLines(from file: URL) {
        guard var state = sessions[file] else { return }
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return }
        if size < state.readOffset { state.readOffset = 0 }
        guard size > state.readOffset,
              let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.readOffset)
            let data = try handle.readToEnd() ?? Data()
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
            let completedData = data[...lastNewline]
            state.readOffset += UInt64(completedData.count)
            guard let text = String(data: completedData, encoding: .utf8) else { return }
            text.split(separator: "\n", omittingEmptySubsequences: true).forEach {
                let line = String($0)
                if let usage = CodexUsageLimit.parse(line: line) { usageHandler?(usage) }
                if let title = CodexProgressParser.taskTitle(line: line) { state.title = title }
                guard var update = CodexProgressParser.parse(line: line) else { return }
                update = .init(
                    kind: update.kind,
                    detail: update.detail,
                    phase: update.phase,
                    sessionID: file.deletingPathExtension().lastPathComponent,
                    taskTitle: state.title
                )
                state.latestUpdate = update
                state.lastActivity = activityDate(from: line) ?? Date()
                sessions[file] = state
                handler?(update, summaries())
            }
            sessions[file] = state
        } catch {
            return
        }
    }

    private func summaries() -> [CodexSessionProgress] {
        sessions.values.compactMap { state in
            guard let latestUpdate = state.latestUpdate else { return nil }
            return CodexSessionProgress(
                id: latestUpdate.sessionID,
                title: state.title,
                lastActivity: state.lastActivity,
                latestUpdate: latestUpdate
            )
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    private func activityDate(from line: String) -> Date? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["timestamp"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

private extension CodexProgressParser {
    static func taskTitle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any] else { return nil }
        if payload["type"] as? String == "user_message",
           let message = payload["message"] as? String {
            return compactTitle(message)
        }
        guard payload["type"] as? String == "message",
              payload["role"] as? String == "user",
              let content = payload["content"] as? [[String: Any]] else { return nil }
        let message = content.compactMap { $0["text"] as? String }.joined(separator: " ")
        return compactTitle(message)
    }

    private static func compactTitle(_ message: String) -> String? {
        let text = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > 64 ? String(text.prefix(61)) + "…" : text
    }
}
