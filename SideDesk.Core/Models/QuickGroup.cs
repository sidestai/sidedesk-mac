using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Newtonsoft.Json;

namespace SideDesk.Models
{
    public class QuickItem
    {
        public string Id { get; set; }
        public string Name { get; set; } = string.Empty;
        /// <summary>Emoji 图标字符（如 、📁）</summary>
        public string? Icon { get; set; }
        /// <summary>"url" / "program"</summary>
        public string Type { get; set; } = "url";
        /// <summary>网址或程序路径</summary>
        public string Target { get; set; } = string.Empty;
        /// <summary>URL 类型：是否 App 模式打开</summary>
        public bool UseAppMode { get; set; } = true;

        /// <summary>URL 类型：是否用内置 WebView2 弹窗打开（页内悬浮复制/分享按钮，#57）；默认外部浏览器</summary>
        public bool UseBuiltinBrowser { get; set; } = false;
        public string? BackgroundColor { get; set; }   // #RRGGBB；null/空 = 透明
        public DateTime CreatedAt { get; set; }

        /// <summary>是否窗口置顶</summary>
        public bool AlwaysOnTop { get; set; } = false;

        /// <summary>是否允许该窗口在系统任务栏上显示（并可 Alt+Tab 切换）</summary>
        public bool ShowInTaskbar { get; set; } = false;

        /// <summary>是否保存为「长期窗口」：启动时根据匹配规则查找现有窗口并接管</summary>
        public bool IsLongTermWindow { get; set; } = false;
        /// <summary>长期窗口匹配：标题文本（未设置为 null）</summary>
        public string? MatchTitle { get; set; }
        /// <summary>长期窗口匹配：标题模式 exact / contains</summary>
        public string MatchTitleMode { get; set; } = "contains";
        /// <summary>长期窗口匹配：窗口类名（未设置为 null）</summary>
        public string? MatchClass { get; set; }
        /// <summary>长期窗口匹配：exe 文件名（不含路径）（未设置为 null）</summary>
        public string? MatchExe { get; set; }

        /// <summary>项来源标记："window" = 通过「添加窗口」接管创建（未勾选长期窗口时，退出会被清理）；非接管项为 null</summary>
        public string? Source { get; set; }

        /// <summary>URL 类型打开时使用的浏览器 exe 配置 ID（空=使用系统默认 msedge）</summary>
        public string? BrowserExeId { get; set; }
        /// <summary>URL 类型打开时使用的 user-data-dir 配置 ID（空=不指定）</summary>
        public string? BrowserProfileId { get; set; }

        /// <summary>程序启动时的命令行参数（无参数为 null）</summary>
        public string? LaunchArgs { get; set; }

        /// <summary>URL 类型打开时使用的 ProgramRegistry 浏览器 ID（空=默认）</summary>
        public string? BrowserId { get; set; }
        /// <summary>URL 类型打开时使用的 ProgramRegistry Profile ID（空=不指定）</summary>
        public string? ProfileId { get; set; }

        /// <summary>高级项（Type="advanced"）动作配置 JSON（AdvancedItemConfig 序列化）；非高级项为 null</summary>
        public string? AdvancedConfigJson { get; set; }

        /// <summary>组内排序序号（越小越靠前）：随行 content 持久化与云同步，拖拽调序后重排</summary>
        public int SortIndex { get; set; }

        [JsonIgnore]
        public IntPtr WindowHandle { get; set; } = IntPtr.Zero;

        public QuickItem()
        {
            Id = Guid.NewGuid().ToString("N");
            CreatedAt = DateTime.Now;
            BackgroundColor = "#3498DB";
        }
    }

    /// <summary>
    /// 快捷卡片「分组」内存门面：与 PanelItem(Type=QuickGroup) 一一对应，所有属性代理到面板。
    /// 历史上快捷分组存于 quickgroups.json；改造后设置存面板 item_data、快捷项存 item_row，
    /// 本类仅为兼容 UI 层（QuickGroupUIService 等）调用而保留，不再参与任何持久化。
    /// </summary>
    public class QuickGroup
    {
        /// <summary>底层面板（所有属性的真实存储处）</summary>
        [JsonIgnore]
        public PanelItem Panel { get; }

        public QuickGroup() : this(new PanelItem { Type = PanelType.QuickGroup }) { }

        public QuickGroup(PanelItem panel)
        {
            Panel = panel;
            panel.Type = PanelType.QuickGroup;
        }

        /// <summary>分组 Id = 面板本地 Id（稳定 GUID，行级同步寻址基础）</summary>
        [JsonIgnore]
        public string Id => Panel.Id;

        public string Name { get => Panel.QuickGroupName; set => Panel.QuickGroupName = value; }
        public int Columns { get => Panel.QuickColumns; set => Panel.QuickColumns = value; }
        public bool IsExpanded { get => Panel.IsExpanded; set => Panel.IsExpanded = value; }
        public bool HideFrame { get => Panel.QuickHideFrame; set => Panel.QuickHideFrame = value; }
        public string DisplayMode { get => Panel.QuickDisplayMode; set => Panel.QuickDisplayMode = value; }
        public int Order { get => Panel.QuickOrder; set => Panel.QuickOrder = value; }
        public string OwnerType { get => Panel.OwnerType; set => Panel.OwnerType = value; }
        public string? TeamId { get => Panel.TeamId; set => Panel.TeamId = value; }
        public string? TeamName { get => Panel.TeamName; set => Panel.TeamName = value; }

        /// <summary>快捷项：直接引用面板列表本体，增删即时生效</summary>
        [JsonIgnore]
        public List<QuickItem> Items => Panel.QuickItems ??= new List<QuickItem>();

        /// <summary>分组内子卡片列表（用于添加便签、剪贴板等卡片）</summary>
        [JsonIgnore]
        public List<PanelItem>? ChildPanels { get => Panel.ChildPanels; set => Panel.ChildPanels = value; }
    }

    // ===== 浏览器 Profile 管理 =====

    public class BrowserExeEntry
    {
        public string Id { get; set; } = Guid.NewGuid().ToString("N");
        /// <summary>显示名，如 "Chrome", "Edge"</summary>
        public string Name { get; set; } = string.Empty;
        /// <summary>浏览器 exe 完整路径</summary>
        public string ExePath { get; set; } = string.Empty;
    }

    public class BrowserProfileEntry
    {
        public string Id { get; set; } = Guid.NewGuid().ToString("N");
        /// <summary>显示名，如 "工作", "个人"</summary>
        public string Name { get; set; } = string.Empty;
        /// <summary>user-data 目录完整路径</summary>
        public string UserDataDir { get; set; } = string.Empty;
    }

    public class BrowserProfileData
    {
        public List<BrowserExeEntry> Exes { get; set; } = new List<BrowserExeEntry>();
        public List<BrowserProfileEntry> Profiles { get; set; } = new List<BrowserProfileEntry>();
    }
}
