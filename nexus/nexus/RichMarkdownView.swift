import AppKit
import Foundation
import SwiftUI
import WebKit

enum MarkdownBlock: Equatable {
    case prose(String)
    case code(language: String?, content: String)
    case math(String)
}

enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []
        var index = 0

        func flushProse() {
            let value = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { blocks.append(.prose(value)) }
            prose.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushProse()
                let languageText = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let language = languageText.isEmpty ? nil : languageText
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: language, content: code.joined(separator: "\n")))
                continue
            }

            if let inlineMath = sameLineMath(in: trimmed) {
                flushProse()
                blocks.append(.math(inlineMath))
                index += 1
                continue
            }

            if trimmed == "$$" || trimmed == #"\["# {
                flushProse()
                let closing = trimmed == "$$" ? "$$" : #"\]"#
                index += 1
                var equation: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != closing {
                    equation.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.math(equation.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }

            prose.append(line)
            index += 1
        }
        flushProse()
        return blocks
    }

    private static func sameLineMath(in line: String) -> String? {
        if line.hasPrefix("$$"), line.hasSuffix("$$"), line.count > 4 {
            return String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        if line.hasPrefix(#"\["#), line.hasSuffix(#"\]"#), line.count > 4 {
            return String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

struct RichMarkdownView: View {
    let markdown: String

    private var blocks: [MarkdownBlock] { MarkdownBlockParser.parse(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let text):
                    MarkdownProseView(source: text)
                case .code(let language, let content):
                    MarkdownCodeBlock(language: language, content: content)
                case .math(let equation):
                    MarkdownMathBlock(equation: equation)
                }
            }
            HStack {
                Spacer()
                CopyControl(text: markdown, label: "Copy response")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownProseView: View {
    let source: String

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(source)
    }

    var body: some View {
        Text(attributed)
            .font(.system(size: 19, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.96))
            .tint(.cyan)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownCodeBlock: View {
    let language: String?
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.48))
                Spacer()
                CopyControl(text: content, label: "Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.055))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 13.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(13)
            }
            .frame(maxHeight: 150)
        }
        .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.7)
        }
    }
}

private struct MarkdownMathBlock: View {
    let equation: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MathJaxView(equation: equation)
                .frame(height: min(150, max(64, CGFloat(equation.count / 48 + 1) * 38)))
            CopyControl(text: equation, label: "Copy equation")
                .padding(8)
        }
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.09), lineWidth: 0.7)
        }
    }
}

private struct CopyControl: View {
    let text: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10.5, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? .green : .white.opacity(0.52))
    }
}

private struct MathJaxView: NSViewRepresentable {
    let equation: String

    final class Coordinator {
        var renderedEquation = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.enclosingScrollView?.hasVerticalScroller = false
        webView.enclosingScrollView?.hasHorizontalScroller = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.renderedEquation != equation else { return }
        context.coordinator.renderedEquation = equation
        webView.loadHTMLString(Self.html(for: equation), baseURL: nil)
    }

    private static func html(for equation: String) -> String {
        let escaped = equation
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          html,body{margin:0;min-height:100%;background:transparent;color:rgba(255,255,255,.95);overflow:hidden}
          body{display:flex;align-items:center;justify-content:center;padding:12px 48px;box-sizing:border-box;font-size:18px}
          mjx-container{margin:0!important;max-width:100%;overflow-x:auto;overflow-y:hidden}
        </style>
        <script>window.MathJax={svg:{fontCache:'local'},options:{enableMenu:false}};</script>
        <script defer src="https://cdn.jsdelivr.net/npm/mathjax@4/tex-svg.js"></script>
        </head><body>\\[\(escaped)\\]</body></html>
        """
    }
}
