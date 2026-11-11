import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SideDeskCore
import SideDeskServices

/// 便签富文本编辑器的 UI 侧（对应 C# `Controls.RichNoteEditor` + `StickyDesktopService` 顶栏工具/搜索按钮）：
/// `NoteMarkdown`（Services 层）负责 Markdown ⇄ AST，本文件负责 AST ⇄ NSAttributedString 的所见即所得映射、
/// 待办勾选/折叠块三角的点击交互、工具条五按钮与搜索条。存储口径不变：`note.Content` 仍是 Markdown。
///
/// 与 C# 的有意差异：折叠块正文收起时暂存在宿主字典（C# 存在 `DetailsState.Hidden`），语义一致；
/// 嵌套强调在扁平样式模型下归一（与 C#「子集外有损」同取舍，见 NoteMarkdown 单测）。

// MARK: - 属性键

extension NSAttributedString.Key {
    /// 块类型：plain / h / quote / code / hr / ul / ol / todo / dsum / dbody
    static let sdBlock = NSAttributedString.Key("sdBlock")
    static let sdLevel = NSAttributedString.Key("sdLevel")       // 标题级别
    static let sdTodo = NSAttributedString.Key("sdTodo")        // 待办勾选态（挂在勾选字形上）
    static let sdToggle = NSAttributedString.Key("sdToggle")    // 折叠块 id（挂在三角字形上）
    static let sdDetails = NSAttributedString.Key("sdDetails")  // 折叠块 id（摘要/正文段落）
    static let sdOpen = NSAttributedString.Key("sdOpen")        // 折叠块展开态
    static let sdFence = NSAttributedString.Key("sdFence")      // 代码围栏 id（同围栏的多行归并）
    static let sdLang = NSAttributedString.Key("sdLang")        // 围栏语言
    static let sdOlIndex = NSAttributedString.Key("sdOlIndex")  // 有序列表序号
    static let sdImage = NSAttributedString.Key("sdImage")      // 图片路径（挂在附件字符上）
}

// MARK: - AST ⇄ NSAttributedString

enum NoteBridge {

    static let todoUnchecked = "☐ "
    static let todoChecked = "☑ "
    static let detailsOpenGlyph = "▾ "
    static let detailsClosedGlyph = "▸ "

    struct Palette {
        var color: NSColor
        var size: CGFloat
        var monoColor: NSColor
    }

    // MARK: 块 → 属性串

    static func attributed(_ blocks: [NoteBlock], palette: Palette) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            append(block: block, to: out, palette: palette, detailsId: nil)
            if index != blocks.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private static func append(block: NoteBlock, to out: NSMutableAttributedString, palette: Palette, detailsId: String?) {
        switch block {
        case .paragraph(let inlines):
            appendParagraph(inlines: inlines, kind: detailsId == nil ? "plain" : "dbody", palette: palette,
                            attrs: detailsId.map { [NSAttributedString.Key.sdDetails: $0] } ?? [:], to: out)
        case .heading(let level, let inlines):
            var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key.sdLevel: level]
            if let detailsId { attrs[.sdDetails] = detailsId }
            appendParagraph(inlines: inlines, kind: "h", palette: palette, attrs: attrs, to: out,
                            fontOverride: headingFont(level: level, palette: palette, bold: true))
        case .quote(let inlines):
            var attrs: [NSAttributedString.Key: Any] = [:]
            if let detailsId { attrs[.sdDetails] = detailsId }
            appendParagraph(inlines: inlines, kind: "quote", palette: palette, attrs: attrs, to: out, forceItalic: true)
        case .code(let lang, let lines):
            let fence = UUID().uuidString
            for (i, line) in lines.enumerated() {
                var attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key.sdFence: fence,
                    NSAttributedString.Key.sdLang: lang,
                ]
                if let detailsId { attrs[.sdDetails] = detailsId }
                let paragraph = NSMutableAttributedString(string: line, attributes: [
                    .font: monoFont(palette.size, palette: palette),
                    .foregroundColor: palette.monoColor,
                    .sdBlock: "code",
                ])
                for (key, value) in attrs { paragraph.addAttribute(key, value: value, range: paragraph.wholeRange) }
                out.append(paragraph)
                if i != lines.count - 1 { out.append(NSAttributedString(string: "\n")) }
            }
        case .hr:
            let paragraph = NSMutableAttributedString(string: "───", attributes: [
                .font: baseFont(palette.size, palette: palette),
                .foregroundColor: palette.color.withAlphaComponent(0.5),
                .sdBlock: "hr",
            ])
            if let detailsId { paragraph.addAttribute(.sdDetails, value: detailsId, range: paragraph.wholeRange) }
            out.append(paragraph)
        case .list(let ordered, let items):
            for (i, item) in items.enumerated() {
                let kind: String
                let marker: String
                var attrs: [NSAttributedString.Key: Any] = [:]
                if let checked = item.checked {
                    kind = "todo"; marker = checked ? todoChecked : todoUnchecked
                    attrs[.sdTodo] = checked ? 1 : 0
                } else if ordered {
                    kind = "ol"; marker = "\(i + 1). "
                    attrs[.sdOlIndex] = i + 1
                } else {
                    kind = "ul"; marker = "- "
                }
                if let detailsId { attrs[.sdDetails] = detailsId }
                appendParagraph(inlines: item.inlines, kind: kind, palette: palette, attrs: attrs, to: out, marker: marker)
                if i != items.count - 1 { out.append(NSAttributedString(string: "\n")) }
            }
        case .details(let open, let summary, let body):
            let id = UUID().uuidString
            appendParagraph(inlines: summary, kind: "dsum", palette: palette,
                            attrs: [.sdDetails: id, .sdOpen: open ? 1 : 0, .sdToggle: id],
                            to: out,
                            marker: open ? detailsOpenGlyph : detailsClosedGlyph,
                            markerAttrs: [.sdToggle: id])
            out.append(NSAttributedString(string: "\n"))
            for (i, inner) in body.enumerated() {
                append(block: inner, to: out, palette: palette, detailsId: id)
                if i != body.count - 1 { out.append(NSAttributedString(string: "\n")) }
            }
        }
    }

    private static func appendParagraph(inlines: [NoteInline], kind: String, palette: Palette,
                                        attrs: [NSAttributedString.Key: Any],
                                        to out: NSMutableAttributedString,
                                        marker: String = "",
                                        markerAttrs: [NSAttributedString.Key: Any] = [:],
                                        fontOverride: NSFont? = nil,
                                        forceItalic: Bool = false) {
        let paragraph = NSMutableAttributedString()
        if !marker.isEmpty {
            var markerAttributes: [NSAttributedString.Key: Any] = [
                .font: fontOverride ?? baseFont(palette.size, palette: palette),
                .foregroundColor: palette.color,
                .sdBlock: kind,
            ]
            for (key, value) in markerAttrs { markerAttributes[key] = value }
            paragraph.append(NSAttributedString(string: marker, attributes: markerAttributes))
        }
        for inline in inlines {
            paragraph.append(attributed(inline: inline, kind: kind, palette: palette,
                                        fontOverride: fontOverride, forceItalic: forceItalic))
        }
        if paragraph.length == 0 {
            paragraph.append(NSAttributedString(string: " ", attributes: [
                .font: fontOverride ?? baseFont(palette.size, palette: palette),
                .foregroundColor: palette.color,
                .sdBlock: kind,
            ]))
        }
        paragraph.addAttribute(.sdBlock, value: kind, range: paragraph.wholeRange)
        for (key, value) in attrs {
            guard key != .sdTodo, key != .sdToggle else { continue }   // 这两个只挂字形/三角
            paragraph.addAttribute(key, value: value, range: paragraph.wholeRange)
        }
        // 勾选态/三角 id 挂在标记字形上
        if let todo = attrs[.sdTodo] { paragraph.addAttribute(.sdTodo, value: todo, range: NSRange(location: 0, length: marker.count)) }
        if let toggle = attrs[.sdToggle] { paragraph.addAttribute(.sdToggle, value: toggle, range: NSRange(location: 0, length: marker.count)) }
        out.append(paragraph)
    }

    /// 单个行内节点 → 属性串（工具条插入链接/图片时用）。
    static func attributedInline(_ inline: NoteInline, palette: Palette) -> NSAttributedString {
        attributed(inline: inline, kind: "plain", palette: palette, fontOverride: nil, forceItalic: false)
    }

    private static func attributed(inline: NoteInline, kind: String, palette: Palette,
                                   fontOverride: NSFont?, forceItalic: Bool) -> NSAttributedString {
        switch inline {
        case .text(let text, let style):
            return NSAttributedString(string: text, attributes: runAttributes(style: style, kind: kind, palette: palette,
                                                                             fontOverride: fontOverride, forceItalic: forceItalic))
        case .link(let text, let style, let url):
            var attributes = runAttributes(style: style, kind: kind, palette: palette,
                                           fontOverride: fontOverride, forceItalic: forceItalic)
            attributes[.link] = URL(string: url) ?? url
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return NSAttributedString(string: text, attributes: attributes)
        case .image(let path):
            let attachment = NSTextAttachment()
            if let image = NSImage(contentsOfFile: path) {
                let maxW: CGFloat = 220
                let ratio = image.size.height / max(image.size.width, 1)
                let width = min(image.size.width, maxW)
                attachment.image = image
                attachment.bounds = NSRect(x: 0, y: -4, width: width, height: width * ratio)
            }
            let attributed = NSMutableAttributedString(attachment: attachment)
            attributed.addAttribute(.sdImage, value: path, range: attributed.wholeRange)
            attributed.addAttribute(.sdBlock, value: kind, range: attributed.wholeRange)
            attributed.addAttribute(.font, value: baseFont(palette.size, palette: palette), range: attributed.wholeRange)
            return attributed
        }
    }

    private static func runAttributes(style: NoteStyle, kind: String, palette: Palette,
                                      fontOverride: NSFont?, forceItalic: Bool) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: runFont(style: style, kind: kind, palette: palette, fontOverride: fontOverride, forceItalic: forceItalic),
            .foregroundColor: palette.color,
        ]
        if style.contains(.strike) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    // MARK: 字体

    static func baseFont(_ size: CGFloat, palette: Palette) -> NSFont {
        .systemFont(ofSize: size)
    }

    static func monoFont(_ size: CGFloat, palette: Palette) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func headingFont(level: Int, palette: Palette, bold: Bool) -> NSFont {
        let delta: CGFloat = level <= 1 ? 6 : (level == 2 ? 4 : 2)
        return .systemFont(ofSize: palette.size + delta, weight: bold ? .bold : .regular)
    }

    private static func runFont(style: NoteStyle, kind: String, palette: Palette,
                                fontOverride: NSFont?, forceItalic: Bool) -> NSFont {
        if style.contains(.code) { return monoFont(palette.size, palette: palette) }
        if kind == "code" { return monoFont(palette.size, palette: palette) }
        let bold = style.contains(.bold) || (fontOverride != nil && kind == "h")
        let italic = style.contains(.italic) || forceItalic
        if let fontOverride, !italic, !style.contains(.italic) { return fontOverride }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let base = fontOverride ?? baseFont(palette.size, palette: palette)
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    // MARK: 属性串 → 块

    struct Paragraph {
        let range: NSRange
        let kind: String
        let level: Int
        let detailsId: String?
        let open: Bool
        let fence: String?
        let lang: String
        let text: String
    }

    static func paragraphs(in string: NSAttributedString) -> [Paragraph] {
        var result: [Paragraph] = []
        let full = string.string as NSString
        var location = 0
        while location < full.length {
            var end = full.range(of: "\n", options: [], range: NSRange(location: location, length: full.length - location)).location
            if end == NSNotFound { end = full.length } else { end += 1 }
            let range = NSRange(location: location, length: end - location)
            result.append(paragraph(at: range, in: string, full: full))
            location = end
        }
        if result.isEmpty {
            result.append(paragraph(at: NSRange(location: 0, length: 0), in: string, full: full))
        }
        return result
    }

    private static func paragraph(at range: NSRange, in string: NSAttributedString, full: NSString) -> Paragraph {
        func attr(_ key: NSAttributedString.Key) -> Any? {
            guard range.length > 0 else { return nil }
            return string.attribute(key, at: range.location, effectiveRange: nil)
        }
        let text = full.substring(with: range)
        return Paragraph(
            range: range,
            kind: (attr(.sdBlock) as? String) ?? "plain",
            level: (attr(.sdLevel) as? Int) ?? 1,
            detailsId: attr(.sdDetails) as? String,
            open: (attr(.sdOpen) as? Int) == 1,
            fence: attr(.sdFence) as? String,
            lang: (attr(.sdLang) as? String) ?? "",
            text: text
        )
    }

    static func blocks(_ string: NSAttributedString, collapsed: [String: NSAttributedString]) -> [NoteBlock] {
        let paras = paragraphs(in: string)
        var out: [NoteBlock] = []
        var i = 0
        while i < paras.count {
            let p = paras[i]
            switch p.kind {
            case "code":
                var lines: [String] = []
                let fence = p.fence
                let lang = p.lang
                while i < paras.count, paras[i].kind == "code", paras[i].fence == fence {
                    lines.append(stripNewline(paras[i].text))
                    i += 1
                }
                out.append(.code(lang: lang, lines: lines))
            case "ul", "ol", "todo":
                var items: [NoteListItem] = []
                let ordered = p.kind == "ol"
                while i < paras.count, ["ul", "ol", "todo"].contains(paras[i].kind), paras[i].detailsId == nil {
                    items.append(listItem(from: paras[i], in: string))
                    i += 1
                }
                out.append(.list(ordered: ordered, items: items))
            case "dsum":
                let id = p.detailsId ?? ""
                let summary = inlines(of: p, in: string)
                var body: [NoteBlock] = []
                if let stash = collapsed[id] {
                    body = blocks(stash, collapsed: collapsed)
                } else {
                    i += 1
                    while i < paras.count, paras[i].detailsId == id, paras[i].kind != "dsum" {
                        body.append(block(from: paras[i], in: string, paras: paras, index: &i))
                    }
                    out.append(.details(open: p.open, summary: summary, body: body))
                    continue
                }
                out.append(.details(open: false, summary: summary, body: body))
                i += 1
            case "hr":
                out.append(.hr); i += 1
            case "h":
                out.append(.heading(level: p.level, inlines(of: p, in: string))); i += 1
            case "quote":
                out.append(.quote(inlines(of: p, in: string))); i += 1
            default:
                out.append(.paragraph(inlines(of: p, in: string))); i += 1
            }
        }
        return out
    }

    /// 折叠块体内的单个块（体内存的是带 sdDetails 标记的普通段落级块）。
    private static func block(from p: Paragraph, in string: NSAttributedString, paras: [Paragraph], index: inout Int) -> NoteBlock {
        switch p.kind {
        case "code":
            var lines = [stripNewline(p.text)]
            let fence = p.fence
            index += 1
            while index < paras.count, paras[index].kind == "code", paras[index].fence == fence {
                lines.append(stripNewline(paras[index].text)); index += 1
            }
            return .code(lang: p.lang, lines: lines)
        case "ul", "ol", "todo":
            var items = [listItem(from: p, in: string)]
            let ordered = p.kind == "ol"
            let id = p.detailsId
            index += 1
            while index < paras.count, ["ul", "ol", "todo"].contains(paras[index].kind), paras[index].detailsId == id {
                items.append(listItem(from: paras[index], in: string)); index += 1
            }
            return .list(ordered: ordered, items: items)
        case "h":
            index += 1
            return .heading(level: p.level, inlines(of: p, in: string))
        case "quote":
            index += 1
            return .quote(inlines(of: p, in: string))
        case "hr":
            index += 1
            return .hr
        default:
            index += 1
            return .paragraph(inlines(of: p, in: string))
        }
    }

    private static func listItem(from p: Paragraph, in string: NSAttributedString) -> NoteListItem {
        var checked: Bool? = nil
        if p.kind == "todo" {
            checked = (string.attribute(.sdTodo, at: p.range.location, effectiveRange: nil) as? Int) == 1
        }
        return NoteListItem(checked: checked, inlines: inlines(of: p, in: string))
    }

    /// 段落正文行内节点：跳过块标记字形（勾选框 / 三角 / 列表符号），按运行属性还原样式。
    static func inlines(of p: Paragraph, in string: NSAttributedString) -> [NoteInline] {
        var out: [NoteInline] = []
        let start = p.range.location + markerLength(of: p)
        let contentRange = NSRange(location: start, length: max(p.range.length - markerLength(of: p) - newlineSuffix(p), 0))
        guard contentRange.length > 0 else { return out }
        string.enumerateAttributes(in: contentRange, options: []) { attributes, range, _ in
            let text = (string.string as NSString).substring(with: range)
            if text.isEmpty { return }
            if attributes[.sdTodo] != nil || attributes[.sdToggle] != nil { return }
            if let path = attributes[.sdImage] as? String {
                out.append(.image(path: path)); return
            }
            let font = attributes[.font] as? NSFont
            var style: NoteStyle = []
            if let font {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { style.insert(.bold) }
                if traits.contains(.italic) { style.insert(.italic) }
                if font.isMono { style.insert(.code) }
            }
            if attributes[.strikethroughStyle] != nil { style.insert(.strike) }
            if let link = attributes[.link] {
                let url = (link as? URL)?.absoluteString ?? "\(link)"
                out.append(.link(text: text, style: style, url: url))
            } else {
                out.append(.text(text, style))
            }
        }
        return merge(out)
    }

    /// 块标记字形长度（勾选框 / 三角 / 列表符号），回写时由 NoteMarkdown 重新产出，故解析侧跳过。
    static func markerLength(of p: Paragraph) -> Int {
        switch p.kind {
        case "todo": return p.text.hasPrefix(todoChecked) || p.text.hasPrefix(todoUnchecked) ? 2 : 0
        case "dsum": return p.text.hasPrefix(detailsOpenGlyph) || p.text.hasPrefix(detailsClosedGlyph) ? 2 : 0
        case "ul": return p.text.hasPrefix("- ") ? 2 : 0
        case "ol":
            let digits = p.text.prefix(while: { $0.isNumber }).count
            guard digits > 0, p.text.count > digits + 1 else { return 0 }
            let rest = p.text.dropFirst(digits)
            return rest.hasPrefix(". ") || rest.hasPrefix(") ") ? digits + 2 : 0
        default: return 0
        }
    }

    private static func newlineSuffix(_ p: Paragraph) -> Int {
        p.text.hasSuffix("\n") ? 1 : 0
    }

    private static func stripNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    /// 相邻同样式文本运行归并（减少回写碎片）。
    static func merge(_ inlines: [NoteInline]) -> [NoteInline] {
        var out: [NoteInline] = []
        for inline in inlines {
            if case .text(let text, let style) = inline,
               case .text(let lastText, let lastStyle) = out.last ?? .text("", []) {
                if lastStyle == style, !out.isEmpty {
                    out[out.count - 1] = .text(lastText + text, style)
                    continue
                }
            }
            out.append(inline)
        }
        return out
    }
}

private extension NSAttributedString {
    var wholeRange: NSRange { NSRange(location: 0, length: length) }
}

private extension NSFont {
    var isMono: Bool {
        let family = familyName ?? ""
        return family.contains("Mono") || family.contains("Menlo") || family.contains("Courier")
    }
}

// MARK: - 可交互文本视图

/// 便签正文视图：待办勾选字形 / 折叠块三角 / 链接的点击在 mouseDown 里命中属性后分发。
final class NoteTextView: NSTextView {

    var onTodoToggle: ((Int) -> Void)?
    var onDetailsToggle: ((String) -> Void)?
    var onLinkOpen: ((URL) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let index = characterIndex(at: event), index < textStorage?.length ?? 0, let storage = textStorage {
            if storage.attribute(.sdTodo, at: index, effectiveRange: nil) != nil {
                onTodoToggle?(index); return
            }
            if let id = storage.attribute(.sdToggle, at: index, effectiveRange: nil) as? String {
                onDetailsToggle?(id); return
            }
            if let link = storage.attribute(.link, at: index, effectiveRange: nil) {
                let url = (link as? URL) ?? URL(string: "\(link)")
                if let url { onLinkOpen?(url) }
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func characterIndex(at event: NSEvent) -> Int? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let bounds = NSRect(origin: .zero, size: container.size)
        guard bounds.insetBy(dx: -4, dy: -4).contains(containerPoint) else { return nil }
        return manager.characterIndex(for: containerPoint, in: container,
                                      fractionOfDistanceBetweenInsertionPoints: nil)
    }
}

// MARK: - 编辑器模型

/// 便签富文本编辑器模型（对应 C# `RichNoteEditor` 的行为面）：持有 `NoteTextView`、驱动 Markdown ⇄ 富文本双向同步、
/// 工具条五动作、窗内搜索、待办勾选/折叠块展开的交互，以及列表项回车续行。存储口径不变：`note.Content` 仍是 Markdown。
///
/// 与 C# 的有意收窄：图片落盘子系统（`NoteImageService`）未移植，插入图片直接引用本地文件路径（`![](/abs/path)`）；
/// 搜索期间自动展开折叠块未接（收起块正文暂存在宿主字典、不在文本流里，故不可被搜到）。
@MainActor
final class StickyNoteEditorModel: NSObject, ObservableObject, NSTextViewDelegate {

    @Published var toolbarVisible = false
    @Published var searchVisible = false {
        didSet {
            guard searchVisible != oldValue else { return }
            if searchVisible { refreshSearch() } else { clearSearch() }
        }
    }
    @Published var searchText = "" { didSet { guard searchText != oldValue else { return }; refreshSearch() } }
    @Published var matchLabel = ""

    /// 内容变化回调（用户编辑/工具动作后触发，参数为回写的 Markdown）；宿主据此更新 `note.Content` 并调度落盘。
    var onChange: ((String) -> Void)?

    let palette: NoteBridge.Palette
    weak var textView: NoteTextView?

    private let initialMarkdown: String
    private var collapsed: [String: NSMutableAttributedString] = [:]   // 折叠块收起态的正文暂存
    private var suppress = false                                      // 程序回填/结构性变更时抑制 textDidChange
    private var matches: [NSRange] = []
    private var matchIndex = -1

    init(noteId: String, markdown: String, palette: NoteBridge.Palette) {
        self.initialMarkdown = markdown
        self.palette = palette
        super.init()
    }

    func attach(_ tv: NoteTextView) {
        textView = tv
        load(markdown: initialMarkdown)
    }

    /// 载入 Markdown 为富文本（宿主 refresh 时用；内容一致则跳过，避免打断编辑）。
    func load(markdown: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        suppress = true
        let blocks = NoteMarkdown.parse(markdown)
        storage.setAttributedString(NoteBridge.attributed(blocks, palette: palette))
        collapsed.removeAll()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        suppress = false
        if searchVisible { refreshSearch() }
    }

    /// 他处内容变更时同步（不一致才重载）。
    func externalUpdate(_ markdown: String) {
        guard markdown != currentMarkdown() else { return }
        load(markdown: markdown)
    }

    func currentMarkdown() -> String {
        guard let tv = textView, let storage = tv.textStorage else { return "" }
        return NoteMarkdown.write(NoteBridge.blocks(storage, collapsed: collapsed))
    }

    private func emitChange() { onChange?(currentMarkdown()) }

    func focus() { textView?.becomeFirstResponder() }

    // MARK: 工具条动作

    func toggleBold() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let base = NoteBridge.baseFont(palette.size, palette: palette)
        if sel.length == 0 {
            var attrs = tv.typingAttributes
            let font = (attrs[.font] as? NSFont) ?? base
            let nowBold = font.fontDescriptor.symbolicTraits.contains(.bold)
            attrs[.font] = Self.withBold(font, !nowBold)
            tv.typingAttributes = attrs
            return
        }
        let allBold = Self.isAllBold(storage, sel)
        suppress = true
        storage.enumerateAttribute(.font, in: sel, options: []) { value, range, _ in
            let font = (value as? NSFont) ?? base
            storage.addAttribute(.font, value: Self.withBold(font, !allBold), range: range)
        }
        suppress = false
        tv.setSelectedRange(sel)
        emitChange()
    }

    func insertImage() {
        let panel = NSOpenPanel()
        panel.title = Lang.t("common.image")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertInlineAtCaret(.image(path: url.path))
    }

    func insertLink() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let selected = sel.length > 0 ? (storage.string as NSString).substring(with: sel) : ""

        let alert = NSAlert()
        alert.messageText = Lang.t("common.link")
        alert.addButton(withTitle: Lang.t("common.confirm"))
        alert.addButton(withTitle: Lang.t("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "https://"
        if selected.isEmpty { field.stringValue = "" }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let text = selected.isEmpty ? url : selected
        insertInlineAtCaret(.link(text: text, style: [], url: url), replacing: sel)
    }

    func makeCollapseBlock() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let full = storage.string as NSString
        let sel = tv.selectedRange()
        let startLoc = min(sel.location, full.length)
        let endLoc = min(sel.location + sel.length, full.length)
        var cover = full.lineRange(for: NSRange(location: startLoc, length: 0))
        if endLoc > startLoc {
            let endLine = full.lineRange(for: NSRange(location: max(endLoc - 1, 0), length: 0))
            cover = NSRange(location: cover.location, length: endLine.location + endLine.length - cover.location)
        }
        let covered = full.substring(with: cover)
        let lines = covered.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        let summary = NoteMarkdown.parseInlines(lines[0])
        let body: [NoteBlock] = lines.dropFirst().map { .paragraph(NoteMarkdown.parseInlines($0)) }
        let rendered = NoteBridge.attributed([.details(open: false, summary: summary, body: body)], palette: palette)
            .mutableCopy() as! NSMutableAttributedString
        if cover.location + cover.length < full.length { rendered.append(NSAttributedString(string: "\n")) }
        suppress = true
        storage.replaceCharacters(in: cover, with: rendered)
        suppress = false
        tv.setSelectedRange(NSRange(location: cover.location, length: 0))
        emitChange()
    }

    func insertTodo() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let full = storage.string as NSString
        let caret = min(tv.selectedRange().location, full.length)
        // lineRange 含行尾换行，故 insertAt = 下一行行首（或文末）。待办要自成一行插到当前行之后，
        // 不能像旧逻辑那样无脑在前面补 \n——那样会在中间行产生空行、并把下一行内容粘到待办后面。
        let lineR = full.lineRange(for: NSRange(location: caret, length: 0))
        let insertAt = lineR.location + lineR.length
        let item = NoteBridge.attributed([.list(ordered: false, items: [NoteListItem(checked: false, inlines: [])])],
                                         palette: palette)
        let itemLen = (item.string as NSString).length
        let newline = NSAttributedString(string: "\n")
        suppress = true
        var caretLoc: Int
        if insertAt < full.length {
            // 后面还有内容：item + 换行，把下一行顶下去（不打断、不粘连）。
            storage.insert(item, at: insertAt)
            storage.insert(newline, at: insertAt + itemLen)
            caretLoc = insertAt + itemLen
        } else if insertAt > 0 && full.character(at: insertAt - 1) != 0x0A {
            // 文末且当前行无换行结尾：先补 \n 再插 item。
            storage.insert(newline, at: insertAt)
            storage.insert(item, at: insertAt + 1)
            caretLoc = insertAt + 1 + itemLen
        } else {
            // 空文档，或已在行首（前一字符是 \n）：直接插 item，不加多余换行。
            storage.insert(item, at: insertAt)
            caretLoc = insertAt + itemLen
        }
        suppress = false
        tv.setSelectedRange(NSRange(location: caretLoc, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        emitChange()
    }

    private func insertInlineAtCaret(_ inline: NoteInline, replacing sel: NSRange? = nil) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = sel ?? tv.selectedRange()
        let attr = NoteBridge.attributedInline(inline, palette: palette)
        suppress = true
        storage.replaceCharacters(in: range, with: attr)
        suppress = false
        tv.setSelectedRange(NSRange(location: range.location + (attr.string as NSString).length, length: 0))
        emitChange()
    }

    // MARK: 待办 / 折叠块交互

    func toggleTodo(at index: Int) {
        guard let tv = textView, let storage = tv.textStorage, index < storage.length else { return }
        var eff = NSRange(location: 0, length: 0)
        guard let val = storage.attribute(.sdTodo, at: index, effectiveRange: &eff) as? Int else { return }
        let wasChecked = val == 1
        let glyph = wasChecked ? NoteBridge.todoUnchecked : NoteBridge.todoChecked
        suppress = true
        storage.replaceCharacters(in: eff, with: glyph)
        let glyphRange = NSRange(location: eff.location, length: (glyph as NSString).length)
        storage.addAttribute(.sdTodo, value: wasChecked ? 0 : 1, range: glyphRange)
        storage.addAttribute(.sdBlock, value: "todo", range: glyphRange)
        suppress = false
        emitChange()
    }

    func toggleDetails(id: String) {
        guard let storage = textView?.textStorage else { return }
        let paras = NoteBridge.paragraphs(in: storage)
        guard let sumIdx = paras.firstIndex(where: { $0.kind == "dsum" && $0.detailsId == id }) else { return }
        let sumRange = paras[sumIdx].range
        suppress = true
        if collapsed[id] != nil {
            // 展开：把暂存正文插回摘要行之后
            if let stash = collapsed[id] {
                storage.insert(stash, at: sumRange.location + sumRange.length)
            }
            collapsed[id] = nil
            setSummaryGlyph(storage, sumRange: sumRange, open: true)
        } else {
            // 收起：摘出后续同 id 的正文段落，暂存到字典
            var bodyEnd = sumIdx + 1
            while bodyEnd < paras.count, paras[bodyEnd].detailsId == id, paras[bodyEnd].kind != "dsum" { bodyEnd += 1 }
            if bodyEnd > sumIdx + 1 {
                let loc = paras[sumIdx + 1].range.location
                let lastR = paras[bodyEnd - 1].range
                let del = NSRange(location: loc, length: lastR.location + lastR.length - loc)
                collapsed[id] = (storage.attributedSubstring(from: del).mutableCopy() as! NSMutableAttributedString)
                storage.deleteCharacters(in: del)
            }
            setSummaryGlyph(storage, sumRange: sumRange, open: false)
        }
        suppress = false
        emitChange()
    }

    private func setSummaryGlyph(_ storage: NSTextStorage, sumRange: NSRange, open: Bool) {
        let glyph = open ? NoteBridge.detailsOpenGlyph : NoteBridge.detailsClosedGlyph
        let markerRange = NSRange(location: sumRange.location, length: min(2, sumRange.length))
        storage.replaceCharacters(in: markerRange, with: glyph)
        let gr = NSRange(location: sumRange.location, length: (glyph as NSString).length)
        storage.addAttribute(.sdOpen, value: open ? 1 : 0, range: gr)
    }

    // MARK: 搜索

    func findNext() { advance(1) }
    func findPrev() { advance(-1) }

    private func advance(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = ((matchIndex + delta) % matches.count + matches.count) % matches.count
        scrollToMatch()
        updateLabel()
    }

    func refreshSearch() {
        clearHighlights()
        matches.removeAll()
        matchIndex = -1
        let q = searchText
        guard searchVisible, !q.isEmpty, let tv = textView, let storage = tv.textStorage else { matchLabel = ""; return }
        let full = storage.string as NSString
        var searchRange = NSRange(location: 0, length: full.length)
        while searchRange.location < full.length {
            let found = full.range(of: q, options: .caseInsensitive, range: searchRange)
            if found.location == NSNotFound { break }
            matches.append(found)
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: full.length - next)
        }
        guard !matches.isEmpty else { matchLabel = Lang.t("common.noMatches"); return }
        matchIndex = 0
        highlightAll()
        scrollToMatch()
        updateLabel()
    }

    private func highlightAll() {
        guard let tv = textView, let lm = tv.layoutManager, let storage = tv.textStorage else { return }
        let color = NSColor.systemYellow.withAlphaComponent(0.45)
        for m in matches {
            guard NSMaxRange(m) <= storage.length else { continue }
            lm.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: m)
        }
    }

    private func clearHighlights() {
        guard let tv = textView, let lm = tv.layoutManager, let storage = tv.textStorage else { return }
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
    }

    private func scrollToMatch() {
        guard let tv = textView, matchIndex >= 0, matchIndex < matches.count else { return }
        clearHighlights()
        highlightAll()
        let m = matches[matchIndex]
        guard NSMaxRange(m) <= (tv.textStorage?.length ?? 0) else { return }
        tv.setSelectedRange(m)
        tv.scrollRangeToVisible(m)
        if let lm = tv.layoutManager {
            lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.7), forCharacterRange: m)
        }
    }

    private func clearSearch() {
        clearHighlights()
        matches.removeAll()
        matchIndex = -1
        matchLabel = ""
    }

    private func updateLabel() {
        matchLabel = matches.isEmpty ? Lang.t("common.noMatches") : "\(matchIndex + 1)/\(matches.count)"
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !suppress else { return }
        emitChange()
        if searchVisible && !searchText.isEmpty { refreshSearch() }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)), let tv = textView as? NoteTextView {
            return handleNewline(tv)
        }
        return false
    }

    // MARK: 列表回车续行

    private func handleNewline(_ tv: NoteTextView) -> Bool {
        guard let storage = tv.textStorage else { return false }
        let full = storage.string as NSString
        let caret = min(tv.selectedRange().location, full.length)
        let lineR = full.lineRange(for: NSRange(location: caret, length: 0))
        let raw = full.substring(with: lineR)
        let line = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
        guard let pre = Self.listPrefix(line) else { return false }
        // 仅在光标位于该行末尾时续行（行中回车走默认拆行）
        let lineEnd = lineR.location + (line as NSString).length
        guard caret >= lineEnd else { return false }

        if pre.bodyEmpty {
            // 空列表项回车：删掉标记退出列表
            suppress = true
            storage.replaceCharacters(in: NSRange(location: lineR.location, length: caret - lineR.location), with: "")
            suppress = false
            tv.setSelectedRange(NSRange(location: lineR.location, length: 0))
            emitChange()
            return true
        }
        let marker = NSMutableAttributedString(string: "\n" + pre.marker, attributes: [
            .font: NoteBridge.baseFont(palette.size, palette: palette),
            .foregroundColor: palette.color,
            .sdBlock: pre.kind,
        ])
        let mRange = NSRange(location: 1, length: (pre.marker as NSString).length)
        if pre.kind == "todo" { marker.addAttribute(.sdTodo, value: 0, range: mRange) }
        if pre.kind == "ol" { marker.addAttribute(.sdOlIndex, value: pre.nextIndex, range: mRange) }
        suppress = true
        storage.insert(marker, at: caret)
        suppress = false
        let newCaret = caret + (marker.string as NSString).length
        tv.setSelectedRange(NSRange(location: newCaret, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        emitChange()
        return true
    }

    private struct ListPrefix { let kind: String; let marker: String; let bodyEmpty: Bool; let nextIndex: Int }

    private static func listPrefix(_ line: String) -> ListPrefix? {
        func bodyEmpty(_ rest: Substring) -> Bool {
            rest.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if line.hasPrefix(NoteBridge.todoChecked) {
            return ListPrefix(kind: "todo", marker: NoteBridge.todoUnchecked, bodyEmpty: bodyEmpty(line.dropFirst(2)), nextIndex: 0)
        }
        if line.hasPrefix(NoteBridge.todoUnchecked) {
            return ListPrefix(kind: "todo", marker: NoteBridge.todoUnchecked, bodyEmpty: bodyEmpty(line.dropFirst(2)), nextIndex: 0)
        }
        if line.hasPrefix("- ") {
            return ListPrefix(kind: "ul", marker: "- ", bodyEmpty: bodyEmpty(line.dropFirst(2)), nextIndex: 0)
        }
        let digits = line.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") {
                let next = (Int(digits) ?? 0) + 1
                return ListPrefix(kind: "ol", marker: "\(next). ", bodyEmpty: bodyEmpty(rest.dropFirst(2)), nextIndex: next)
            }
        }
        return nil
    }

    // MARK: 字体工具

    private static func withBold(_ font: NSFont, _ bold: Bool) -> NSFont {
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) } else { traits.remove(.bold) }
        let d = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    private static func isAllBold(_ storage: NSTextStorage, _ range: NSRange) -> Bool {
        var all = true, seen = false
        storage.enumerateAttribute(.font, in: range, options: []) { value, r, _ in
            let text = (storage.string as NSString).substring(with: r)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            seen = true
            let font = value as? NSFont
            if !(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false) { all = false }
        }
        return seen && all
    }
}

// MARK: - NSViewRepresentable

/// 便签富文本编辑区：手动构建 `NoteTextView`（非 `scrollableTextView()`，以用子类接管待办/折叠块点击）。
struct StickyRichNoteView: NSViewRepresentable {

    @ObservedObject var model: StickyNoteEditorModel

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NoteTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 10, height: 8)
        tv.textContainer?.lineFragmentPadding = 2
        tv.textContainer?.widthTracksTextView = true
        tv.insertionPointColor = model.palette.color
        tv.textColor = model.palette.color
        tv.font = NoteBridge.baseFont(model.palette.size, palette: model.palette)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.delegate = model

        tv.onTodoToggle = { [weak model] index in MainActor.assumeIsolated { model?.toggleTodo(at: index) } }
        tv.onDetailsToggle = { [weak model] id in MainActor.assumeIsolated { model?.toggleDetails(id: id) } }
        tv.onLinkOpen = { url in NSWorkspace.shared.open(url) }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = tv

        model.attach(tv)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if model.textView == nil, let tv = nsView.documentView as? NoteTextView { model.attach(tv) }
    }
}
