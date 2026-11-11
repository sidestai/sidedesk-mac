import Foundation

/// 便签搜索的纯函数层（#155）：过滤与命中分段都在这一层，UI 只负责把结果画出来。
/// 对应 C# `Models.StickyNoteSearch`。便签没有独立标题字段——首行即标题，故按 Content 全文匹配。
public enum StickyNoteSearch {

    /// 归一化关键词：去首尾空白；空/纯空白 → nil（= 不过滤）。
    public static func Normalize(_ keyword: String?) -> String? {
        guard let keyword else { return nil }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 单条便签是否命中：空关键词恒为 true（清空 = 恢复全量）。
    public static func Matches(_ note: StickyNote?, _ keyword: String?) -> Bool {
        guard let keyword else { return true }
        guard let content = note?.Content, !content.isEmpty else { return false }
        return content.range(of: keyword, options: .caseInsensitive) != nil
    }

    /// 过滤（保持传入顺序；空关键词原样返回）。
    public static func Filter(_ notes: [StickyNote]?, _ keyword: String?) -> [StickyNote] {
        let kw = Normalize(keyword)
        guard let notes else { return [] }
        return notes.filter { Matches($0, kw) }
    }

    /// 把文本按关键词切成「未命中 / 命中」交替的片段——UI 据此拼高亮。
    /// 空关键词或空文本 → 单一整段、IsHit=false。
    public static func Segments(_ text: String?, _ keyword: String?) -> [StickySearchSegment] {
        var result: [StickySearchSegment] = []
        let kw = Normalize(keyword)
        guard let text, !text.isEmpty else {
            return [StickySearchSegment(text ?? "", false)]
        }
        guard let kw else {
            return [StickySearchSegment(text, false)]
        }
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let r = text.range(of: kw, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            if r.lowerBound > searchStart {
                result.append(StickySearchSegment(String(text[searchStart..<r.lowerBound]), false))
            }
            result.append(StickySearchSegment(String(text[r]), true))
            searchStart = r.upperBound
        }
        if searchStart < text.endIndex {
            result.append(StickySearchSegment(String(text[searchStart..<text.endIndex]), false))
        }
        if result.isEmpty { result.append(StickySearchSegment(text, false)) }
        return result
    }
}

/// 命中分段：一段连续文本 + 它是不是关键词命中。对应 C# `readonly struct StickySearchSegment`。
public struct StickySearchSegment {
    public let Text: String
    public let IsHit: Bool
    public init(_ text: String, _ isHit: Bool) {
        Text = text
        IsHit = isHit
    }
}

extension StickySearchSegment: CustomStringConvertible {
    public var description: String { IsHit ? "[" + Text + "]" : Text }
}
