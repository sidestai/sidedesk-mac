import Foundation

/// 生成与 .NET `Guid.NewGuid().ToString("N")` 等价的 Id：32 位小写十六进制、无连字符。
func newGuidId() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

/// 便签/记事预览文本清洗（#797）：列表名称与 tooltip 直接展示原始 Markdown 会漏出 XML 标签
/// （如 `<details>`）、图片网址与行首标记。纯函数、可单测；Models 内共享，UI 复用同一口径。
/// 对应 C# `Models.NotePreviewText`。
public enum NotePreviewText {

    private static let imageMarkdown = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\([^)]*\)"#)
    private static let linkMarkdown = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)
    private static let xmlTags = try! NSRegularExpression(pattern: #"</?[A-Za-z][^>]*>"#)
    // 行首的标题 # / 引用 > / 列表 - * + / 待办 [ ] [x] 标记：名称里只留正文
    private static let linePrefix = try! NSRegularExpression(pattern: #"^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s*)?)"#)

    private static func replace(_ pattern: NSRegularExpression, _ s: String, _ template: String) -> String {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return pattern.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }

    /// 图片/链接语法取文字、XML/HTML 标签整段去掉，保留可读内容。
    public static func StripMarkup(_ content: String?) -> String {
        guard let content, !content.isEmpty else { return "" }
        var s = replace(imageMarkdown, content, "$1")   // 先图片后链接：链接正则会把 ![alt](url) 的 ! 留下
        s = replace(linkMarkdown, s, "$1")
        return replace(xmlTags, s, "")
    }

    /// 列表名称用首行：清洗标记后取第一个非空行并去行首标记；全为标记时返回空串。
    public static func FirstLine(_ content: String?) -> String {
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let stripped = StripMarkup(content)
        for raw in stripped.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let line = replace(linePrefix, String(raw), "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { return line }
        }
        return ""
    }
}
