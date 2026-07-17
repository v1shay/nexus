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

enum InlineMarkdownSegment: Equatable {
    case text(String)
    case math(String)
}

enum InlineMathParser {
    static func parse(_ source: String) -> [InlineMarkdownSegment] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<!\$)\$([^$\n]+)\$(?!\$)|\\\((.+?)\\\)"#
        ) else { return [.text(source)] }
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty else { return [.text(source)] }
        var segments: [InlineMarkdownSegment] = []
        var cursor = source.startIndex
        for match in matches {
            guard let fullRange = Range(match.range, in: source) else { continue }
            if cursor < fullRange.lowerBound {
                segments.append(.text(String(source[cursor..<fullRange.lowerBound])))
            }
            let capture = [match.range(at: 1), match.range(at: 2)]
                .compactMap { Range($0, in: source).map { String(source[$0]) } }
                .first ?? ""
            segments.append(.math(capture))
            cursor = fullRange.upperBound
        }
        if cursor < source.endIndex { segments.append(.text(String(source[cursor...]))) }
        return segments
    }
}

enum MarkdownProseFormatter {
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ"
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎"
    ]
    private static let symbols: [(String, String)] = [
        (#"\alpha"#, "α"), (#"\beta"#, "β"), (#"\gamma"#, "γ"),
        (#"\delta"#, "δ"), (#"\theta"#, "θ"), (#"\lambda"#, "λ"),
        (#"\mu"#, "μ"), (#"\pi"#, "π"), (#"\sigma"#, "σ"),
        (#"\phi"#, "φ"), (#"\omega"#, "ω"), (#"\times"#, "×"),
        (#"\cdot"#, "·"), (#"\pm"#, "±"), (#"\leq"#, "≤"),
        (#"\geq"#, "≥"), (#"\neq"#, "≠"), (#"\infty"#, "∞"),
        (#"\sum"#, "∑"), (#"\int"#, "∫")
    ]

    static func render(_ source: String) -> String {
        InlineMathParser.parse(normalizedWhitespace(in: source)).map { segment in
            switch segment {
            case .text(let text): text
            case .math(let equation): readableInlineMath(equation)
            }
        }.joined()
    }

    private static func normalizedWhitespace(in source: String) -> String {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: String(repeating: "\u{00a0}", count: 4))
    }

    private static func readableInlineMath(_ equation: String) -> String {
        var value = equation
            .replacingOccurrences(of: #"\left"#, with: "")
            .replacingOccurrences(of: #"\right"#, with: "")

        value = replacing(pattern: #"\\frac\{([^{}]+)\}\{([^{}]+)\}"#, in: value) { match in
            "(\(match[1]))/(\(match[2]))"
        }
        value = replacing(pattern: #"\\sqrt\{([^{}]+)\}"#, in: value) { match in
            "√(\(match[1]))"
        }
        value = replacingScript(pattern: #"\^\{?([0-9+\-=()n]+)\}?"#, in: value, table: superscripts)
        value = replacingScript(pattern: #"_\{?([0-9+\-=()]+)\}?"#, in: value, table: subscripts)
        for (command, symbol) in symbols {
            value = value.replacingOccurrences(of: command, with: symbol)
        }
        return value.replacingOccurrences(of: #"\,"#, with: " ")
    }

    private static func replacing(
        pattern: String,
        in source: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: source) else { continue }
            let captures = (0..<match.numberOfRanges).map { index -> String in
                guard let captureRange = Range(match.range(at: index), in: source) else { return "" }
                return String(source[captureRange])
            }
            result.replaceSubrange(range, with: transform(captures))
        }
        return result
    }

    private static func replacingScript(
        pattern: String,
        in source: String,
        table: [Character: Character]
    ) -> String {
        replacing(pattern: pattern, in: source) { match in
            String(match[1].map { table[$0] ?? $0 })
        }
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

    private func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }

    var body: some View {
        Text(attributed(MarkdownProseFormatter.render(source)))
            .font(.system(size: 19, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.96))
            .tint(.blue)
            .lineSpacing(4)
            .lineLimit(nil)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
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
            KaTeXView(equation: equation)
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

private struct KaTeXView: NSViewRepresentable {
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
        let resourceDirectory = Bundle.main.resourceURL?.appendingPathComponent("KaTeX", isDirectory: true)
        webView.loadHTMLString(KaTeXHTML.document(for: equation), baseURL: resourceDirectory)
    }
}

enum KaTeXHTML {
    static func document(for equation: String) -> String {
        let encodedEquation = javaScriptString(equation)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <link rel="stylesheet" href="katex.min.css">
        <style>
          html,body{margin:0;min-height:100%;background:transparent;color:rgba(255,255,255,.95);overflow:hidden}
          body{display:flex;align-items:center;justify-content:center;padding:12px 48px;box-sizing:border-box;font-size:18px}
          #equation{max-width:100%;overflow-x:auto;overflow-y:hidden;padding:2px;box-sizing:border-box}
          .katex-display{margin:0;max-width:100%}
        </style>
        </head><body><div id="equation"></div>
        <script src="katex.min.js"></script>
        <script>
          const equation = \(encodedEquation);
          const target = document.getElementById('equation');
          if (window.katex) {
            katex.render(equation, target, {
              displayMode: true,
              throwOnError: false,
              strict: false,
              output: 'htmlAndMathml'
            });
          } else {
            target.textContent = equation;
          }
        </script></body></html>
        """
    }

    private static func javaScriptString(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let json = String(data: data, encoding: .utf8),
            json.count >= 2
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}
