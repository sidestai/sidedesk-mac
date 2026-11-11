using System;
using System.Linq;
using Newtonsoft.Json;

namespace SideDesk.Models
{
    /// <summary>
    /// 记事条目：与便签（StickyNote）同构的 Markdown 笔记。真相源是 <c>PanelItem.DeskNotes</c>
    /// （随窗口配置存 <c>local_item_row</c>）；<c>local_desk_note</c> 表只是 SaveItemRows 的镜像写入（#443）。
    /// </summary>
    public class DeskNote
    {
        public string Id { get; set; }
        public string Content { get; set; } = "";
        public DateTime CreatedAt { get; set; }
        public DateTime UpdatedAt { get; set; }

        public DeskNote()
        {
            Id = Guid.NewGuid().ToString("N");
            CreatedAt = DateTime.Now;
            UpdatedAt = DateTime.Now;
        }

        /// <summary>
        /// 获取预览文字：取清洗后的首个非空行，最多30字，无内容时返回"(空)"
        /// </summary>
        [JsonIgnore]
        public string Preview
        {
            get
            {
                if (string.IsNullOrWhiteSpace(Content))
                    return Framework.Lang.T("sticky.empty");
                string firstLine = NotePreviewText.FirstLine(Content);
                if (firstLine.Length == 0)
                    return Framework.Lang.T("sticky.empty");   // 首行全是标记（如仅 <details>）：视同空预览
                return firstLine.Length > 30 ? firstLine.Substring(0, 30) + "…" : firstLine;
            }
        }
    }
}
