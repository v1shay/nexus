import AppKit
import SwiftUI

/// A typed rendering model built from a tool's real arguments and result.  The
/// manifest `previewRenderer` is descriptive metadata only; this adapter is
/// the one place where tool data becomes an interactive user-facing preview.
enum NexTaskPreviewKind: String, Sendable {
    case terminal, message, email, calendar, photos, files, code, browser, connector, system, media, generic
}

struct NexTaskPreviewField: Equatable, Sendable, Identifiable {
    let label: String
    let value: String
    var id: String { "\(label):\(value)" }
}

struct NexTaskPreviewItem: Equatable, Sendable, Identifiable {
    let title: String
    let detail: String
    let emphasis: Bool
    var id: String { "\(title)|\(detail)" }
}

struct NexTaskPreviewModel: Equatable, Sendable {
    let action: String
    let kind: NexTaskPreviewKind
    let title: String
    let subtitle: String
    let status: String
    let effect: String?
    let icon: ToolIconSource
    let fields: [NexTaskPreviewField]
    let items: [NexTaskPreviewItem]
    let confirmationID: UUID?
    let connectionID: UUID?
    let targetURL: URL?
    let messageDraftID: String?
    let messageRecipient: String?
    let messageBody: String?
    let isFailure: Bool

    static func make(activity: ToolActivity) -> Self {
        let action = activity.actionID ?? activity.toolName
        let object = activity.result?.object ?? [:]
        let kind = kind(for: action)
        let confirmationID = UUID(uuidString: object["actionId"]?.string ?? object["action_id"]?.string ?? "")
        let recipient = string("recipient", arguments: activity.arguments, result: object)
            ?? string("email", arguments: activity.arguments, result: object)
            ?? string("channel_id", arguments: activity.arguments, result: object)
        let body = string("body", arguments: activity.arguments, result: object)
            ?? string("content", arguments: activity.arguments, result: object)
        return .init(
            action: action,
            kind: kind,
            title: title(for: action, kind: kind),
            subtitle: applicationName(for: action, fallback: activity.toolName),
            status: object["display"]?.string ?? object["summary"]?.string ?? activity.status,
            effect: object["exactEffect"]?.string,
            icon: activity.icon,
            fields: fields(kind: kind, action: action, arguments: activity.arguments, result: object),
            items: items(kind: kind, action: action, arguments: activity.arguments, result: object),
            confirmationID: confirmationID,
            connectionID: UUID(uuidString: object["connectionId"]?.string ?? ""),
            targetURL: targetURL(from: object),
            messageDraftID: object["messageDraftId"]?.string,
            messageRecipient: recipient,
            messageBody: body,
            isFailure: activity.phase == .failed
        )
    }

    private static func kind(for action: String) -> NexTaskPreviewKind {
        if action.hasPrefix("terminal.") { return .terminal }
        if action.hasPrefix("messages.") || action.hasPrefix("slack.") || action.hasPrefix("discord.") { return .message }
        if action.hasPrefix("gmail.") { return .email }
        if action.hasPrefix("calendar.") { return .calendar }
        if action.hasPrefix("photos.") { return .photos }
        if action.hasPrefix("finder.") || action.hasPrefix("preview.") || action.hasPrefix("obsidian.") { return .files }
        if action.hasPrefix("vscode.") || action.hasPrefix("xcode.") || action.hasPrefix("git.") || action.hasPrefix("github.") || action.hasPrefix("codex.") || action == "nex_cli_task" { return .code }
        if action == "browser.play_youtube" { return .media }
        if action.hasPrefix("browser.") || action.hasPrefix("chrome.") || action.hasPrefix("web_") { return .browser }
        if action.hasPrefix("spotify.") || action.hasPrefix("youtube_") { return .media }
        if action.hasPrefix("system.") || action.hasPrefix("applications.") { return .system }
        if action.contains(".") { return .connector }
        return .generic
    }

    private static func title(for action: String, kind: NexTaskPreviewKind) -> String {
        let operation = action.split(separator: ".").last.map(String.init)?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Task"
        switch kind {
        case .message: return action == "messages.draft" ? "New Message" : operation
        case .email: return operation.contains("Draft") ? "New Email" : operation
        case .files: return operation
        case .code: return action == "nex_cli_task" ? "NexCLI" : operation
        default: return operation
        }
    }

    private static func applicationName(for action: String, fallback: String) -> String {
        switch action.split(separator: ".").first.map(String.init) {
        case "messages": "Messages"
        case "finder": "Finder"
        case "spotify": "Spotify"
        case "photos": "Photos"
        case "terminal": "Terminal"
        case "calendar": "Calendar"
        case "gmail": "Gmail"
        case "notion": "Notion"
        case "slack": "Slack"
        case "github", "git": "GitHub"
        case "codex": "Codex"
        case "system": "macOS"
        default: fallback
        }
    }

    private static func fields(kind: NexTaskPreviewKind, action: String, arguments: [String: NexJSONValue], result: [String: NexJSONValue]) -> [NexTaskPreviewField] {
        let keys: [(String, [String])] = switch kind {
        case .message: [("To", ["recipient", "channel_id", "email"]), ("Message", ["body", "content"])]
        case .email: [("To", ["email", "recipient"]), ("Subject", ["title"]), ("Message", ["body", "content"])]
        case .calendar: [("Event", ["title"]), ("Starts", ["start"]), ("Ends", ["end"]), ("Location", ["location"])]
        case .terminal: [("Command", ["command", "executable"]), ("Folder", ["workingDirectory"])]
        case .photos: [("Request", ["query"]), ("Album", ["album", "name"])]
        case .files: [("Folder", ["root", "parent", "destinationDirectory", "destination"]), ("Item", ["path", "name"])]
        case .code: [("Workspace", ["workspace", "repository"]), ("File", ["path"]), ("Task", ["prompt", "content", "message"])]
        case .browser: [("Page", ["url"]), ("Goal", ["goal"]), ("Query", ["query"])]
        case .media: [("Track", ["query", "title"]), ("Artist", ["artist"])]
        case .system: [("Setting", ["pane"]), ("Value", ["value", "volume"])]
        case .connector, .generic: [("Request", ["query", "title", "display"])]
        }
        return keys.compactMap { label, candidates in
            guard let value = candidates.lazy.compactMap({ string($0, arguments: arguments, result: result) }).first,
                  !value.isEmpty else { return nil }
            return .init(label: label, value: value)
        }.prefix(4).map { $0 }
    }

    private static func items(kind: NexTaskPreviewKind, action: String, arguments: [String: NexJSONValue], result: [String: NexJSONValue]) -> [NexTaskPreviewItem] {
        let values: [NexJSONValue]
        if let items = result["items"]?.array {
            values = items
        } else if let paths = result["paths"]?.array {
            values = paths
        } else if let results = result["results"]?.array {
            values = results
        } else if let tabs = result["tabs"]?.array {
            values = tabs
        } else if let apps = result["apps"]?.array {
            values = apps
        } else if let changedFiles = result["files_changed"]?.array {
            values = changedFiles
        } else {
            values = []
        }
        var rendered = values.prefix(8).compactMap { item(kind: kind, value: $0) }
        if rendered.isEmpty, let text = result["text"]?.string ?? result["stdout"]?.string ?? result["output"]?.string, !text.isEmpty {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(6)
            rendered = lines.map { line in
                NexTaskPreviewItem(title: String(line), detail: "", emphasis: false)
            }
        }
        if action == "messages.draft", let body = string("body", arguments: arguments, result: result), !body.isEmpty {
            // Preserve the recent Messages history already returned by the
            // action, then keep the new outgoing text visually distinct.
            rendered.append(NexTaskPreviewItem(title: body, detail: "Draft", emphasis: true))
        }
        if kind == .browser,
           let rawPlan = browserStepsJSON(arguments: arguments, result: result),
           let data = rawPlan.data(using: .utf8),
           let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rendered = steps.prefix(6).enumerated().map { index, step in
                let action = step["action"] as? String ?? "step"
                let target = (step["url"] as? String) ?? (step["selector"] as? String) ?? ""
                return NexTaskPreviewItem(
                    title: "\(index + 1). \(action.replacingOccurrences(of: "_", with: " ").capitalized)",
                    detail: target,
                    emphasis: false
                )
            }
        }
        return rendered
    }

    private static func browserStepsJSON(arguments: [String: NexJSONValue], result: [String: NexJSONValue]) -> String? {
        if let steps = arguments["steps"]?.array,
           let data = try? JSONEncoder().encode(steps),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return string("steps_json", arguments: arguments, result: result)
    }

    private static func item(kind: NexTaskPreviewKind, value: NexJSONValue) -> NexTaskPreviewItem? {
        if let text = value.string {
            if kind == .message {
                let parts = text.split(separator: "|", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
                if parts.count >= 8 { return .init(title: parts[7], detail: parts[1] + " · " + parts[2], emphasis: false) }
                if parts.count >= 3 { return .init(title: parts[1], detail: parts[2], emphasis: false) }
            }
            return .init(title: URL(fileURLWithPath: text).lastPathComponent.isEmpty ? text : URL(fileURLWithPath: text).lastPathComponent, detail: text, emphasis: false)
        }
        guard let object = value.object else { return nil }
        let title = firstString(in: object, keys: ["title", "name", "path", "url", "id"]) ?? "Result"
        let detail = firstString(in: object, keys: ["detail", "description", "url", "state"]) ?? ""
        return .init(title: title, detail: detail, emphasis: false)
    }

    private static func firstString(in object: [String: NexJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key]?.string, !value.isEmpty { return value }
        }
        return nil
    }

    private static func string(_ key: String, arguments: [String: NexJSONValue], result: [String: NexJSONValue]) -> String? {
        (arguments[key] ?? result[key])?.string
    }

    private static func targetURL(from result: [String: NexJSONValue]) -> URL? {
        if let path = result["path"]?.string, !path.isEmpty { return URL(fileURLWithPath: path) }
        if let path = result["paths"]?.strings?.first, !path.isEmpty { return URL(fileURLWithPath: path) }
        for key in ["url", "output_url"] {
            if let raw = result[key]?.string, let url = URL(string: raw) { return url }
        }
        return nil
    }
}

/// A reusable glass shell with domain-aware content.  It deliberately renders
/// real values returned by the action rather than inventing a fake app screen.
struct NexTaskPreviewCard: View {
    let model: NexTaskPreviewModel
    let confirm: (UUID) -> Void
    let cancel: (UUID?) -> Void
    let connect: (NexConnectorProvider) -> Void
    let open: (URL) -> Void
    let sendDraft: (String, String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.14))
            VStack(alignment: .leading, spacing: 14) {
                if model.kind == .message { messageContent }
                else { standardContent }
                actions
            }
            .padding(18)
        }
        .background(NexTaskPreviewGlassSurface(cornerRadius: 26))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 0.85))
        .shadow(color: .black.opacity(0.46), radius: 28, y: 14)
        .padding(12)
        .accessibilityIdentifier("nex-task-preview-\(model.kind.rawValue)")
    }

    private var header: some View {
        HStack(spacing: 11) {
            ToolIconView(source: model.icon, size: 25)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(model.subtitle).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { cancel(model.confirmationID) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 26, height: 26).background { NexTaskPreviewInsetGlass(cornerRadius: 13).clipShape(Circle()) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss preview")
        }
        .padding(16)
        .background(NexTaskPreviewInsetGlass(cornerRadius: 0))
    }

    @ViewBuilder private var messageContent: some View {
        if let recipient = model.messageRecipient, !recipient.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(.blue)
                Text(recipient).font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background { NexTaskPreviewInsetGlass(cornerRadius: 18).clipShape(Capsule()) }
        }
        let historyItems = model.action == "messages.draft"
            ? model.items.filter { !$0.emphasis }
            : model.items
        if !historyItems.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("RECENT MESSAGES").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                ForEach(historyItems.prefix(4)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(size: 12, weight: .medium, design: .rounded)).lineLimit(2)
                        if !item.detail.isEmpty { Text(item.detail).font(.system(size: 9, design: .rounded)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { NexTaskPreviewInsetGlass(cornerRadius: 11) }
                }
            }
        }
        if let body = model.messageBody, !body.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.action == "messages.draft" ? "MESSAGE" : "CONFIRMED MESSAGE").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                Text(body).font(.system(size: 14, weight: .regular, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background { NexTaskPreviewInsetGlass(cornerRadius: 15, emphasis: true) }
            }
        }
        statusText
    }

    @ViewBuilder private var standardContent: some View {
        statusText
        if let effect = model.effect, !effect.isEmpty {
            Text(effect).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(model.fields) { field in
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                Text(field.value).font(.system(size: 13, design: .rounded)).textSelection(.enabled).lineLimit(4)
            }
        }
        if !model.items.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.kind == .files ? "ITEMS" : "RESULTS").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                ForEach(model.items.prefix(6)) { item in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: item.emphasis ? "checkmark.circle.fill" : itemIcon).foregroundStyle(item.emphasis ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 12, weight: item.emphasis ? .semibold : .medium, design: .rounded)).lineLimit(2)
                            if !item.detail.isEmpty { Text(item.detail).font(.system(size: 9, design: .rounded)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(9)
                    .background { NexTaskPreviewInsetGlass(cornerRadius: 11) }
                }
            }
        }
    }

    private var statusText: some View {
        Text(model.status)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(model.isFailure ? .red : .white.opacity(0.94))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var actions: some View {
        HStack {
            if let target = model.targetURL { Button("Open") { open(target) }.buttonStyle(.bordered) }
            Spacer()
            if let provider = connectorProvider, model.connectionID != nil { Button("Connect \(provider.title)") { connect(provider) }.buttonStyle(.borderedProminent) }
            if let draftID = model.messageDraftID,
               let recipient = model.messageRecipient,
               let body = model.messageBody,
               model.confirmationID == nil,
               model.action == "messages.draft" {
                Button("Send") { sendDraft(draftID, recipient, body) }.buttonStyle(.borderedProminent)
            }
            if let id = model.confirmationID { Button(model.action == "messages.send_draft" ? "Send" : "Confirm") { confirm(id) }.buttonStyle(.borderedProminent) }
        }
    }

    private var itemIcon: String {
        switch model.kind {
        case .files: "folder.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .photos: "photo"
        case .browser: "globe"
        case .media: "play.fill"
        case .system: "slider.horizontal.3"
        default: "doc.text"
        }
    }

    private var connectorProvider: NexConnectorProvider? {
        let prefix = model.action.split(separator: ".").first.map(String.init) ?? ""
        switch prefix {
        case "gmail", "calendar", "contacts", "google": return .google
        default: return NexConnectorProvider(rawValue: prefix)
        }
    }
}

/// Version-independent smoked liquid glass for every action preview.  It
/// combines the normal macOS material with restrained specular edges and a
/// neutral charcoal tint instead of individual opaque, boxy panels.
private struct NexTaskPreviewGlassSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(.black.opacity(0.43))
            shape.fill(
                LinearGradient(
                    colors: [.white.opacity(0.13), .white.opacity(0.025), .black.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            shape.stroke(
                LinearGradient(
                    colors: [.white.opacity(0.32), .white.opacity(0.07), .white.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
        }
    }
}

private struct NexTaskPreviewInsetGlass: View {
    let cornerRadius: CGFloat
    var emphasis = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.white.opacity(emphasis ? 0.12 : 0.055))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(emphasis ? 0.22 : 0.11), lineWidth: 0.65)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.white.opacity(emphasis ? 0.055 : 0.025))
                    .frame(height: 1)
            }
    }
}
