import AppKit
import SwiftUI

enum NexTaskPreviewKind: String, Sendable {
    case terminal, message, email, calendar, photos, files, code, browser, connector, generic
}

struct NexTaskPreviewField: Equatable, Sendable, Identifiable {
    let label: String
    let value: String

    var id: String { "\(label):\(value)" }
}

struct NexTaskPreviewModel: Equatable, Sendable {
    let action: String
    let kind: NexTaskPreviewKind
    let title: String
    let subtitle: String
    let status: String
    let icon: ToolIconSource
    let fields: [NexTaskPreviewField]
    let confirmationID: UUID?
    let connectionID: UUID?
    let targetURL: URL?
    let isFailure: Bool

    static func make(activity: ToolActivity) -> Self {
        let action = activity.actionID ?? activity.toolName
        let object = activity.result?.object ?? [:]
        let kind = kind(for: action)
        let confirmationID = UUID(uuidString: object["actionId"]?.string ?? object["action_id"]?.string ?? "")
        let connectionID = UUID(uuidString: object["connectionId"]?.string ?? "")
        let target = targetURL(from: object)
        return .init(
            action: action,
            kind: kind,
            title: title(for: action, kind: kind),
            subtitle: activity.toolName,
            status: object["display"]?.string ?? object["summary"]?.string ?? activity.status,
            icon: activity.icon,
            fields: fields(kind: kind, arguments: activity.arguments, result: object),
            confirmationID: confirmationID,
            connectionID: connectionID,
            targetURL: target,
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
        if action.hasPrefix("vscode.") || action.hasPrefix("xcode.") || action.hasPrefix("git.") || action.hasPrefix("github.") { return .code }
        if action.hasPrefix("browser.") || action.hasPrefix("chrome.") || action.hasPrefix("web_") { return .browser }
        if action.contains(".") { return .connector }
        return .generic
    }

    private static func title(for action: String, kind: NexTaskPreviewKind) -> String {
        let operation = action.split(separator: ".").last.map(String.init)?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Task"
        switch kind { case .email: return operation.contains("Draft") ? "New Message" : operation; case .calendar: return operation.contains("Event") ? operation : "Calendar"; default: return operation }
    }

    private static func fields(kind: NexTaskPreviewKind, arguments: [String: NexJSONValue], result: [String: NexJSONValue]) -> [NexTaskPreviewField] {
        let keys: [(String, String)] = switch kind {
        case .email: [("To", "email"), ("Subject", "title"), ("Message", "body")]
        case .message: [("To", "channel_id"), ("Message", "body")]
        case .calendar: [("Event", "title"), ("Starts", "start"), ("Ends", "end"), ("Location", "location")]
        case .terminal: [("Command", "executable"), ("Output", "stdout")]
        case .photos: [("Selection", "query"), ("Album", "album")]
        case .files: [("File", "path"), ("Destination", "destination")]
        case .code: [("Workspace", "workspace"), ("File", "path"), ("Change", "content")]
        case .browser: [("Page", "url"), ("Goal", "goal"), ("Query", "query")]
        case .connector, .generic: [("Action", "display")]
        }
        return keys.compactMap { label, key in
            let value = arguments[key] ?? result[key]
            guard let text = display(value), !text.isEmpty else { return nil }
            return NexTaskPreviewField(label: label, value: text)
        }.prefix(5).map { $0 }
    }

    private static func targetURL(from result: [String: NexJSONValue]) -> URL? {
        if let path = result["path"]?.string, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        for key in ["url", "output_url"] {
            if let raw = result[key]?.string, let url = URL(string: raw) {
                return url
            }
        }
        return nil
    }

    private static func display(_ value: NexJSONValue?) -> String? {
        switch value { case .string(let value): value; case .number(let value): String(value); case .bool(let value): value ? "Yes" : "No"; case .array(let values): values.compactMap(display).joined(separator: ", "); default: nil }
    }
}

struct NexTaskPreviewCard: View {
    let model: NexTaskPreviewModel
    let confirm: (UUID) -> Void
    let cancel: (UUID?) -> Void
    let connect: (NexConnectorProvider) -> Void
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ToolIconView(source: model.icon, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(model.subtitle).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { cancel(model.confirmationID) } label: { Image(systemName: "xmark").frame(width: 24, height: 24).background(.white.opacity(0.08), in: Circle()) }
                    .buttonStyle(.plain)
            }
            .padding(16)
            .background(.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 12) {
                Text(model.status)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(model.isFailure ? .red : .white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(model.fields.enumerated()), id: \.element.id) { index, field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                        Text(field.value).font(.system(size: 13, weight: .regular, design: .rounded)).textSelection(.enabled).lineLimit(5)
                    }
                    if index < model.fields.count - 1 { Divider().opacity(0.22) }
                }
                Spacer(minLength: 0)
                HStack {
                    if let target = model.targetURL { Button("Open") { open(target) } }
                    Spacer()
                    if let provider = connectorProvider, model.connectionID != nil { Button("Connect \(provider.title)") { connect(provider) }.buttonStyle(.borderedProminent) }
                    if let id = model.confirmationID { Button("Confirm") { confirm(id) }.buttonStyle(.borderedProminent) }
                }
            }
            .padding(18)
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.13), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(12)
        .accessibilityIdentifier("nex-task-preview-\(model.kind.rawValue)")
    }

    private var connectorProvider: NexConnectorProvider? {
        let prefix = model.action.split(separator: ".").first.map(String.init) ?? ""
        switch prefix {
        case "gmail", "calendar", "contacts", "google": return .google
        default: return NexConnectorProvider(rawValue: prefix)
        }
    }
}
