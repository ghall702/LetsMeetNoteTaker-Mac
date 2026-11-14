import Foundation

/// Minimal GitHub-flavoured Markdown block parser used to preview pupil-facing notes the
/// way the website renders them (headings, lists, tables, quotes, code, rules, paragraphs).
/// Inline formatting (bold, italic, code, links) is left in the text for the UI to render.
public enum MarkdownBlock: Equatable, Sendable {
    public struct ListItem: Equatable, Sendable {
        public var level: Int
        public var ordered: Bool
        public var number: Int?
        public var text: String
    }
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([ListItem])
    case quote(String)
    case code(String)
    case table(header: [String], rows: [[String]])
    case rule
}

public enum MarkdownBlocks {
    static let bullet = try! NSRegularExpression(pattern: #"^(\s*)([-*+•])\s+(.*)$"#)
    static let ordered = try! NSRegularExpression(pattern: #"^(\s*)(\d{1,3})[.)]\s+(.*)$"#)
    static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*?)\s*#*\s*$"#)

    static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    static func isTableSeparator(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.hasPrefix("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var para: [String] = []
        var items: [MarkdownBlock.ListItem] = []
        var quote: [String] = []
        func flushPara() { if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func flushList() { if !items.isEmpty { blocks.append(.list(items)); items = [] } }
        func flushQuote() { if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] } }
        func flushAll() { flushPara(); flushList(); flushQuote() }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushAll()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                blocks.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty { flushAll(); i += 1; continue }
            if let h = match(heading, trimmed) {
                flushAll()
                blocks.append(.heading(level: h[0].count, text: h[1]))
                i += 1; continue
            }
            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) && para.isEmpty {
                flushAll(); blocks.append(.rule); i += 1; continue
            }
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushAll()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    var r = cells(lines[i])
                    if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                    rows.append(Array(r.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushPara(); flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1; continue
            }
            if let b = match(bullet, line) {
                flushPara(); flushQuote()
                items.append(.init(level: b[0].count / 2, ordered: false, number: nil, text: b[2]))
                i += 1; continue
            }
            if let o = match(ordered, line) {
                flushPara(); flushQuote()
                items.append(.init(level: o[0].count / 2, ordered: true, number: Int(o[1]), text: o[2]))
                i += 1; continue
            }
            if !items.isEmpty, line.hasPrefix("  ") {
                // Continuation of a list item.
                items[items.count - 1].text += " " + trimmed
                i += 1; continue
            }
            flushList(); flushQuote()
            para.append(trimmed)
            i += 1
        }
        flushAll()
        return blocks
    }
}
