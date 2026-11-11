using System.Text.RegularExpressions;

namespace SideDesk.Models;

/// <summary>
/// 便签/记事预览文本清洗（#797）：列表名称与 tooltip 直接展示原始 Markdown 会漏出 XML 标签
/// （如 <c>&lt;details&gt;</c>）、图片网址与行首标记。纯函数、可单测；Models 内共享，UI 复用同一口径。
/// </summary>
public static class NotePreviewText
{
    private static readonly Regex ImageMarkdown = new(@"!\[([^\]]*)\]\([^)]*\)", RegexOptions.Compiled);
    private static readonly Regex LinkMarkdown = new(@"\[([^\]]*)\]\([^)]*\)", RegexOptions.Compiled);
    private static readonly Regex XmlTags = new(@"</?[A-Za-z][^>]*>", RegexOptions.Compiled);
    // 行首的标题 # / 引用 > / 列表 - * + / 待办 [ ] [x] 标记：名称里只留正文
    private static readonly Regex LinePrefix = new(@"^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s*)?)", RegexOptions.Compiled);

    /// <summary>图片/链接语法取文字、XML/HTML 标签整段去掉，保留可读内容。</summary>
    public static string StripMarkup(string? content)
    {
        if (string.IsNullOrEmpty(content)) return string.Empty;
        var s = ImageMarkdown.Replace(content, "$1");   // 先图片后链接：链接正则会把 ![alt](url) 的 ! 留下
        s = LinkMarkdown.Replace(s, "$1");
        return XmlTags.Replace(s, string.Empty);
    }

    /// <summary>列表名称用首行：清洗标记后取第一个非空行并去行首标记；全为标记时返回空串。</summary>
    public static string FirstLine(string? content)
    {
        if (string.IsNullOrWhiteSpace(content)) return string.Empty;
        foreach (var raw in StripMarkup(content).Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var line = LinePrefix.Replace(raw, string.Empty).Trim();
            if (line.Length > 0) return line;
        }
        return string.Empty;
    }
}
