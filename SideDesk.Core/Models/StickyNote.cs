using System;
using System.Linq;
using Newtonsoft.Json;

namespace SideDesk.Models
{
    public class StickyNote
    {
        public string Id { get; set; }
        public string Content { get; set; } = "";
        public DateTime CreatedAt { get; set; }
        public DateTime UpdatedAt { get; set; }

        // === 钉选到桌面（issue #300）：选中后以黄色便签悬浮窗常驻屏幕 ===
        /// <summary>是否钉选到桌面（显示为 topmost 黄色便签悬浮窗）。</summary>
        public bool Pinned { get; set; }
        /// <summary>悬浮窗左上角 X（屏幕坐标）；0 = 尚未定位，首次打开走级联默认位置。</summary>
        public double PinLeft { get; set; }
        /// <summary>悬浮窗左上角 Y（屏幕坐标）；0 = 尚未定位。</summary>
        public double PinTop { get; set; }
        /// <summary>悬浮窗宽；&lt;=0 = 尚未调整过尺寸，首次打开用默认尺寸。</summary>
        public double PinWidth { get; set; }
        /// <summary>悬浮窗高；&lt;=0 = 尚未调整过尺寸。</summary>
        public double PinHeight { get; set; }
        /// <summary>
        /// 桌面悬浮窗是否被用户关闭（✕ 或侧栏收起）：抑制 pin 的开机自动恢复（#486）——
        /// 关掉后重启也不弹回，直到用户再点侧栏该项（届时清回 false）。默认 false：旧数据无此字段时
        /// 按「未关闭」处理，已钉选便签照常恢复（向后兼容）。仅当 <see cref="Pinned"/> 为真时才参与恢复判定。
        /// </summary>
        public bool DeskClosed { get; set; }

        public StickyNote()
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
