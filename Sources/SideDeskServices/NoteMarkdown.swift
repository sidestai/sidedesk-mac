import Foundation

/// 便签行内样式（对应 C# 富文本回写侧识别的 Run/Span 属性子集：粗 / 斜 / 删除线 / 行内代码）。
/// 下划线、颜色、字号等 Markdown 子集表达不了的属性一律不建模（对应 C# FlowDocumentMarkdownWriter 的归一化取舍）。
public struct NoteStyle: OptionSet, Equatable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold   = NoteStyle(rawValue: 1 << 0)
    public static let italic = NoteStyle(rawValue: 1 << 1)
    public static let strike = NoteStyle(rawValue: 1 << 2)
    public static let code   = NoteStyle(rawValue: 1 << 3)
}

/// 行内节点：纯文本 / 链接 / 图片（对应 C# Run / Hyperlink / InlineUIContainer(Image)）。
public enum NoteInline: Equatable {
    case text(String, NoteStyle)
    case link(text: String, style: NoteStyle, url: String)
    case image(path: String)
}

/// 列表项：`checked` 非 nil 即待办项（对应 C# 首内联为自绘勾选框的 ListItem）。
public struct NoteListItem: Equatable {
    public var checked: Bool?
    public var inlines: [NoteInline]
    public init(checked: Bool? = nil, inlines: [NoteInline]) {
        self.checked = checked; self.inlines = inlines
    }
}

/// 块级节点（对应 C# FlowDocument 的 Block 子集）。
/// 表格、公式等未建模结构在解析侧落为 `paragraph` 原样保留，回写不变（往返稳定）。
public indirect enum NoteBlock: Equatable {
    case paragraph([NoteInline])
    case heading(level: Int, [NoteInline])
    case quote([NoteInline])
    case code(lang: String, lines: [String])
    case hr
    case list(ordered: Bool, items: [NoteListItem])
    case details(open: Bool, summary: [NoteInline], body: [NoteBlock])
}

/// 便签「Markdown 存储 ⇄ 富文本编辑」双向桥的纯逻辑侧（对应 C# `MarkdownFlowRenderer` 读侧 +
/// `FlowDocumentMarkdownWriter` 写侧的子集口径）。不依赖 AppKit，可单测；
/// NSAttributedString 的映射在 UI 层（`StickyRichEditor`）。
///
/// 口径与 C# 一致：段落以空行分隔；空段落不产出；标题/引用回写时抑制行内粗斜（段落级已带）；
/// 待办归一为 `- [ ] ` / `- [x] `；折叠块为 `<details[ open]>\n<summary>…</summary>\n\n正文\n\n</details>`。
public enum NoteMarkdown {

    // MARK: - 解析

    public static func parse(_ markdown: String) -> [NoteBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        return parseBlocks(lines, &index, stopAtDetailsClose: false)
    }

    private static func parseBlocks(_ lines: [String], _ i: inout Int, stopAtDetailsClose: Bool) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            if stopAtDetailsClose, trimmed == "</details>" { i += 1; return blocks }
            if trimmed.hasPrefix("```") {
                blocks.append(parseCode(lines, &i, trimmed)); continue
            }
            if trimmed == "<details>" || trimmed == "<details open>" {
                blocks.append(parseDetails(lines, &i, open: trimmed.hasSuffix("open>"))); continue
            }
            if trimmed == "---" { i += 1; blocks.append(.hr); continue }
            if let level = headingLevel(trimmed) {
                i += 1
                blocks.append(.heading(level: level, parseInlines(String(trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces))))); continue
            }
            if trimmed.hasPrefix(">") {
                blocks.append(parseQuote(lines, &i)); continue
            }
            if listItemMarker(trimmed) != nil {
                blocks.append(parseList(lines, &i)); continue
            }
            // 连续非空行 = 同一段落内的软换行（Markdown 语义；表格等未建模结构借此原样往返）
            var parts = [line]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || isBlockStart(t) { break }
                parts.append(lines[i])
                i += 1
            }
            blocks.append(.paragraph(parseInlines(parts.joined(separator: "\n"))))
        }
        return blocks
    }

    /// 行是否开启一个新块（用于段落软换行的收束边界）。
    private static func isBlockStart(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("```") { return true }
        if trimmed == "<details>" || trimmed == "<details open>" || trimmed == "</details>" { return true }
        if trimmed == "---" { return true }
        if headingLevel(trimmed) != nil { return true }
        if trimmed.hasPrefix(">") { return true }
        if listItemMarker(trimmed) != nil { return true }
        return false
    }

    private static func parseCode(_ lines: [String], _ i: inout Int, _ opening: String) -> NoteBlock {
        let lang = String(opening.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        i += 1
        var body: [String] = []
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "```" { i += 1; break }
            body.append(lines[i]); i += 1
        }
        return .code(lang: lang, lines: body)
    }

    private static func parseDetails(_ lines: [String], _ i: inout Int, open: Bool) -> NoteBlock {
        i += 1
        var summary: [NoteInline] = []
        if i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("<summary>") {
                var inner = String(t.dropFirst("<summary>".count))
                if inner.hasSuffix("</summary>") { inner = String(inner.dropLast("</summary>".count)) }
                summary = parseInlines(inner.trimmingCharacters(in: .whitespaces))
                i += 1
            }
        }
        let body = parseBlocks(lines, &i, stopAtDetailsClose: true)
        return .details(open: open, summary: summary, body: body)
    }

    private static func parseQuote(_ lines: [String], _ i: inout Int) -> NoteBlock {
        var parts: [String] = []
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(">") else { break }
            parts.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
            i += 1
        }
        return .quote(parseInlines(parts.joined(separator: "\n")))
    }

    private static func parseList(_ lines: [String], _ i: inout Int) -> NoteBlock {
        var items: [NoteListItem] = []
        var ordered = false
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard let marker = listItemMarker(t) else { break }
            if items.isEmpty { ordered = marker.ordered }
            items.append(NoteListItem(checked: marker.checked, inlines: parseInlines(marker.text)))
            i += 1
        }
        return .list(ordered: ordered, items: items)
    }

    /// 列表行标记解析：返回（是否有序、待办勾选态、去掉标记后的正文）；非列表行 nil。
    private static func listItemMarker(_ trimmed: String) -> (ordered: Bool, checked: Bool?, text: String)? {
        if trimmed.hasPrefix("- [ ] ") || trimmed == "- [ ]" {
            return (false, false, String(trimmed.dropFirst("- [ ] ".count)))
        }
        if trimmed.hasPrefix("- [x] ") || trimmed == "- [x]" {
            return (false, true, String(trimmed.dropFirst("- [x] ".count)))
        }
        if trimmed.hasPrefix("- [X] ") || trimmed == "- [X]" {
            return (false, true, String(trimmed.dropFirst("- [X] ".count)))
        }
        // 旧写法：手打的 ☐/☑ 字形前缀（C# 回写侧同样归一）
        if trimmed.hasPrefix("☐ ") { return (false, false, String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("☑ ") { return (false, true, String(trimmed.dropFirst(2))) }
        for prefix in ["- ", "* ", "+ "] where trimmed.hasPrefix(prefix) {
            return (false, nil, String(trimmed.dropFirst(prefix.count)))
        }
        let digits = trimmed.prefix(while: { $0.isNumber })
        if !digits.isEmpty, trimmed.count > digits.count + 1 {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return (true, nil, String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), trimmed.count > hashes, trimmed[trimmed.index(trimmed.startIndex, offsetBy: hashes)] == " " else { return nil }
        return hashes
    }

    // MARK: - 行内解析

    public static func parseInlines(_ source: String) -> [NoteInline] {
        var out: [NoteInline] = []
        var plain = ""
        var i = source.startIndex

        func flush() {
            if !plain.isEmpty { out.append(.text(plain, [])); plain = "" }
        }

        while i < source.endIndex {
            let rest = source[i...]
            if rest.hasPrefix("!["), let end = closeOf(source, from: i, open: "![", sep: "](") {
                flush()
                out.append(.image(path: end.url))
                i = end.next
                continue
            }
            if rest.hasPrefix("["), let end = closeOf(source, from: i, open: "[", sep: "](") {
                flush()
                // 链接文字按原样保留（回写原样还原），样式只作用于文字整体的粗斜等
                out.append(.link(text: end.inner, style: [], url: end.url))
                i = end.next
                continue
            }
            if rest.hasPrefix("`"), let inner = spanOf(source, from: i, marker: "`") {
                flush()
                out.append(.text(inner.inner, .code))
                i = inner.next
                continue
            }
            if rest.hasPrefix("**"), let inner = spanOf(source, from: i, marker: "**") {
                flush()
                out.append(contentsOf: wrap(parseInlines(inner.inner), .bold))
                i = inner.next
                continue
            }
            if rest.hasPrefix("~~"), let inner = spanOf(source, from: i, marker: "~~") {
                flush()
                out.append(contentsOf: wrap(parseInlines(inner.inner), .strike))
                i = inner.next
                continue
            }
            if rest.hasPrefix("*"), let inner = spanOf(source, from: i, marker: "*") {
                flush()
                out.append(contentsOf: wrap(parseInlines(inner.inner), .italic))
                i = inner.next
                continue
            }
            plain.append(source[i])
            i = source.index(after: i)
        }
        flush()
        return out
    }

    private static func wrap(_ inlines: [NoteInline], _ style: NoteStyle) -> [NoteInline] {
        inlines.map { inline in
            switch inline {
            case .text(let t, let s):  return .text(t, s.union(style))
            case .link(let t, let s, let u): return .link(text: t, style: s.union(style), url: u)
            case .image:               return inline
            }
        }
    }

    /// 取 `marker … marker` 区间；无配对闭合返回 nil（标记按字面文本处理）。
    private static func spanOf(_ s: String, from i: String.Index, marker: String) -> (inner: String, next: String.Index)? {
        let start = s.index(i, offsetBy: marker.count)
        guard let close = s.range(of: marker, range: start..<s.endIndex) else { return nil }
        let inner = String(s[start..<close.lowerBound])
        if inner.isEmpty { return nil }
        return (inner, close.upperBound)
    }

    /// 取 `[inner](url)` 形态；返回 inner 与 url、以及整个结构之后的下标。
    private static func closeOf(_ s: String, from i: String.Index, open: String, sep: String) -> (inner: String, url: String, next: String.Index)? {
        let afterOpen = s.index(i, offsetBy: open.count)
        guard let sepRange = s.range(of: sep, range: afterOpen..<s.endIndex) else { return nil }
        let inner = String(s[afterOpen..<sepRange.lowerBound])
        guard let close = s.range(of: ")", range: sepRange.upperBound..<s.endIndex) else { return nil }
        let url = String(s[sepRange.upperBound..<close.lowerBound])
        return (inner, url, close.upperBound)
    }

    // MARK: - 回写

    public static func write(_ blocks: [NoteBlock]) -> String {
        var out = ""
        for block in blocks { write(block, into: &out) }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
    }

    private static func write(_ block: NoteBlock, into out: inout String) {
        switch block {
        case .paragraph(let inlines):
            let text = writeInlines(inlines).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
            out += text + "\n\n"
        case .heading(let level, let inlines):
            let text = writeInlines(inlines, suppressEmphasis: true).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
            out += String(repeating: "#", count: min(max(level, 1), 6)) + " " + text + "\n\n"
        case .quote(let inlines):
            let text = writeInlines(inlines, suppressEmphasis: true).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) { out += "> " + line + "\n" }
            out += "\n"
        case .code(let lang, let lines):
            out += "```" + lang + "\n" + lines.joined(separator: "\n") + "\n```\n\n"
        case .hr:
            out += "---\n\n"
        case .list(let ordered, let items):
            for (index, item) in items.enumerated() {
                let body = writeInlines(item.inlines).trimmingCharacters(in: .whitespacesAndNewlines)
                let marker: String
                if let checked = item.checked {
                    marker = checked ? "- [x] " : "- [ ] "
                } else if ordered {
                    marker = "\(index + 1). "
                } else {
                    marker = "- "
                }
                out += marker + body + "\n"
            }
            out += "\n"
        case .details(let open, let summary, let body):
            out += open ? "<details open>\n" : "<details>\n"
            out += "<summary>" + writeInlines(summary, suppressEmphasis: true).trimmingCharacters(in: .whitespacesAndNewlines) + "</summary>\n\n"
            for inner in body { write(inner, into: &out) }
            out += "</details>\n\n"
        }
    }

    /// 行内节点 → Markdown 片段（UI 层局部回写与单测共用）。
    public static func writeInlines(_ inlines: [NoteInline], suppressEmphasis: Bool = false) -> String {
        var out = ""
        for inline in inlines {
            switch inline {
            case .text(let text, let style):
                out += decorate(text, style, suppressEmphasis: suppressEmphasis)
            case .link(let text, let style, let url):
                out += "[" + decorate(text, style, suppressEmphasis: suppressEmphasis) + "](" + url + ")"
            case .image(let path):
                out += "![](" + path + ")"
            }
        }
        return out
    }

    /// 行内标记包裹顺序与 C# 一致：删除线最外、其次粗体、最后斜体；行内代码不再叠其它标记。
    private static func decorate(_ text: String, _ style: NoteStyle, suppressEmphasis: Bool) -> String {
        guard !text.isEmpty else { return text }
        if style.contains(.code) { return "`" + text + "`" }
        var out = text
        if !suppressEmphasis {
            if style.contains(.strike) { out = "~~" + out + "~~" }
            if style.contains(.bold) { out = "**" + out + "**" }
            if style.contains(.italic) { out = "*" + out + "*" }
        }
        return out
    }
}
