import AppKit

/// Rich or plain text put on the pasteboard for one paste.
enum PasteContent {
    static func write(_ text: String, format: String, to pasteboard: NSPasteboard = .general) throws {
        pasteboard.clearContents()
        switch format {
        case "text":
            pasteboard.setString(text, forType: .string)
        case "html":
            pasteboard.declareTypes([.html, .string], owner: nil)
            pasteboard.setString(text, forType: .html)
            pasteboard.setString(plainText(fromHTML: text), forType: .string)
        case "markdown":
            pasteboard.declareTypes([.html, .string], owner: nil)
            pasteboard.setString(html(fromMarkdown: text), forType: .html)
            pasteboard.setString(text, forType: .string)
        default:
            throw ComputerUseError.invalidArguments("format must be text, html or markdown")
        }
    }

    private static func plainText(fromHTML html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                             .characterEncoding: String.Encoding.utf8.rawValue],
                                                       documentAttributes: nil) else { return html }
        return attributed.string
    }

    /// Headings, lists, paragraphs, emphasis, code and links: enough for pasting notes and messages.
    static func html(fromMarkdown markdown: String) -> String {
        var out: [String] = []
        var list: String?
        var paragraph: [String] = []
        func flushParagraph() {
            if !paragraph.isEmpty { out.append("<p>\(paragraph.joined(separator: " "))</p>") }
            paragraph = []
        }
        func closeList() {
            if let tag = list { out.append("</\(tag)>") }
            list = nil
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                closeList()
            } else if let level = line.firstIndex(where: { $0 != "#" }).map({ line.distance(from: line.startIndex, to: $0) }),
                      (1...6).contains(level), line.dropFirst(level).first == " " {
                flushParagraph()
                closeList()
                out.append("<h\(level)>\(inline(String(line.dropFirst(level + 1))))</h\(level)>")
            } else if let item = listItem(line) {
                flushParagraph()
                if list != item.tag {
                    closeList()
                    out.append("<\(item.tag)>")
                    list = item.tag
                }
                out.append("<li>\(inline(item.text))</li>")
            } else {
                closeList()
                paragraph.append(inline(line))
            }
        }
        flushParagraph()
        closeList()
        return out.joined()
    }

    private static func listItem(_ line: String) -> (tag: String, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return ("ul", String(line.dropFirst(2))) }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
           line[line.index(after: dot)...].hasPrefix(" ") {
            return ("ol", String(line[line.index(dot, offsetBy: 2)...]))
        }
        return nil
    }

    private static func inline(_ text: String) -> String {
        var html = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"__([^_]+)__"#, "<strong>$1</strong>"),
            (#"\*([^*]+)\*"#, "<em>$1</em>"),
            (#"(?<![\w])_([^_]+)_(?![\w])"#, "<em>$1</em>"),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules {
            html = html.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return html
    }
}
