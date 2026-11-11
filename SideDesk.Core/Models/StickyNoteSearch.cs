using System;
using System.Collections.Generic;

namespace SideDesk.Models
{
    /// <summary>
    /// 便签搜索的纯函数层（#155）：过滤与命中分段都在这一层，UI 只负责把结果画出来。
    ///
    /// <para><b>为什么单独一层</b>：两处便签列表（侧边栏卡片、设置页「我的数据-便签」）都要过滤，
    /// 且"命中高亮"需要把一段文本切成「命中/未命中」交替的片段——这两件事都能脱离 WPF 断言，
    /// 放纯函数里才测得到（UI 层的 Inlines 构造没有单测价值）。</para>
    ///
    /// <para><b>匹配口径（诚实标注）</b>：便签没有独立标题字段（见 <see cref="StickyNote"/>）——
    /// 首行即标题。所以"按标题+内容搜索"在实现上就是按 <see cref="StickyNote.Content"/> 全文匹配，
    /// 不额外切首行：切出来再拼回去既慢又会让"跨行的关键词"漏掉。</para>
    /// </summary>
    public static class StickyNoteSearch
    {
        /// <summary>归一化关键词：去首尾空白；空/纯空白 → null（= 不过滤）。</summary>
        public static string? Normalize(string? keyword)
            => string.IsNullOrWhiteSpace(keyword) ? null : keyword.Trim();

        /// <summary>单条便签是否命中：空关键词恒为 true（清空 = 恢复全量）。</summary>
        public static bool Matches(StickyNote note, string? keyword)
        {
            if (keyword is null) return true;
            if (note?.Content is not { } content || content.Length == 0) return false;
            return content.IndexOf(keyword, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        /// <summary>过滤（保持传入顺序；空关键词原样返回）。</summary>
        public static IReadOnlyList<StickyNote> Filter(IEnumerable<StickyNote> notes, string? keyword)
        {
            var kw = Normalize(keyword);
            var result = new List<StickyNote>();
            if (notes == null) return result;
            foreach (var n in notes)
                if (Matches(n, kw)) result.Add(n);
            return result;
        }

        /// <summary>
        /// 把文本按关键词切成「未命中 / 命中」交替的片段——UI 据此拼高亮 Run。
        /// 空关键词或空文本 → 单一整段、<c>IsHit=false</c>（调用方直接当普通文本用）。
        /// </summary>
        public static IReadOnlyList<StickySearchSegment> Segments(string? text, string? keyword)
        {
            var result = new List<StickySearchSegment>();
            var kw = Normalize(keyword);
            if (string.IsNullOrEmpty(text))
            {
                result.Add(new StickySearchSegment(text ?? "", false));
                return result;
            }
            if (kw == null)
            {
                result.Add(new StickySearchSegment(text, false));
                return result;
            }

            int from = 0;
            while (true)
            {
                var at = text.IndexOf(kw, from, StringComparison.OrdinalIgnoreCase);
                if (at < 0) break;
                if (at > from) result.Add(new StickySearchSegment(text.Substring(from, at - from), false));
                result.Add(new StickySearchSegment(text.Substring(at, kw.Length), true));
                from = at + kw.Length;
            }
            if (from < text.Length) result.Add(new StickySearchSegment(text.Substring(from), false));
            // 极端情况（text 全是关键词且刚好到尾）保证至少一段
            if (result.Count == 0) result.Add(new StickySearchSegment(text, false));
            return result;
        }
    }

    /// <summary>命中分段：一段连续文本 + 它是不是关键词命中。</summary>
    public readonly struct StickySearchSegment
    {
        /// <summary>片段文本。</summary>
        public string Text { get; }

        /// <summary>是否关键词命中（UI 据此高亮）。</summary>
        public bool IsHit { get; }

        public StickySearchSegment(string text, bool isHit)
        {
            Text = text;
            IsHit = isHit;
        }

        public override string ToString() => IsHit ? "[" + Text + "]" : Text;
    }
}
