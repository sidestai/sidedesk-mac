using System.IO;
using Newtonsoft.Json;

namespace SideDesk.Models;

public enum WindowType { Native, WebView }

public partial class PanelItem
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string? ServerId { get; set; }  // 云同步服务器端 ID（服务器返回，持久化到 windows.json；null=尚未同步）
    public PanelType Type { get; set; }
    public string? GroupId { get; set; }  // 仅 QuickGroup 类型使用
    public string? Title { get; set; }    // 可选自定义标题
    public List<ClipboardSavedItem>? ClipboardItems { get; set; } // 剪贴板收藏数据
    public List<FileAreaItem>? FileItems { get; set; } // 文件区数据
    public List<DataDashboardItem>? DashboardItems { get; set; } // 数据看板项
    public List<TimerItem>? TimerItems { get; set; } // 计时器数据
    public List<CountdownItem>? CountdownItems { get; set; } // 倒计时器数据
    public List<PanelItem>? ChildPanels { get; set; } // 分组子面板
    public bool IsExpanded { get; set; } = true;      // 分组是否展开
    public string? GroupBGColor { get; set; }              // 分组自定义背景色（hex字符串，null=跟随主题）
    public string? BGColor { get; set; }                   // 卡片自定义背景色（hex字符串，null=跟随主题）
    public List<StickyNote>? StickyNotes { get; set; } // 便签数据（per-panel）
    public List<TodoItem>? TodoItems { get; set; } // 今日待办数据（per-panel）
    public bool SkipWrapper { get; set; } = false;     // 是否跳过外层容器包装
    public bool HideFrame { get; set; } = false;       // 单个卡片独立隐藏外框（边框/标题/背景/内边距）
    public bool IsPinned { get; set; } = false;        // 是否置顶（渲染在滚动区上方的置顶区，压缩滚动区高度）
    public int DashboardColumns { get; set; } = 1;     // 数据看板每排列数（1~4）
    public List<SignalLightItem>? SignalLights { get; set; } // 信号灯数据
    public bool SignalLightVertical { get; set; } = false; // 信号灯纵向排列
    public double SignalLightSpacing { get; set; } = 5;    // 信号灯间距（px）
    public string SignalLightAlignment { get; set; } = "Center"; // 信号灯对齐：Left/Center/Right
    public string FileAreaLayout { get; set; } = "List";         // 文件区布局：LargeIcons/SmallIcons/List
    public int FileAreaColumns { get; set; } = 1;                // 文件区列数（1~4）
    public double? PanelHeight { get; set; }                     // 卡片内容区自定义高度（px）；null=自动高度
    public List<string>? DigitalEmployeeIds { get; set; }        // 数字员工卡片：展示的员工 Id 列表（引用全局员工库）
    public int DigitalEmployeeColumns { get; set; } = 3;         // 数字员工卡片：每排展示的员工数（1~5）
    public string? FriendName { get; set; }                      // 好友卡片：名字
    public string? FriendAvatarPath { get; set; }                // 好友卡片：头像图片路径
    public string? FriendEmoji { get; set; }                     // 好友卡片：Emoji/文字头像（无图片时的兜底）
    public string? FriendStatusText { get; set; }                // 好友卡片：状态文字
    public string FriendOnlineStatus { get; set; } = "online";   // 好友卡片：在线状态 online/away/busy/offline
    public string FriendDisplayMode { get; set; } = "HorizontalSmall"; // 好友卡片：显示方式 HorizontalSmall/VerticalLarge
    public List<string>? FriendUserIds { get; set; }             // 好友卡片：展示的好友 userId 加密串列表（引用后端真实好友，与实际数据分离的显示副本）
    public string? CarouselFolder { get; set; }                  // 图片轮播：图片所在目录
    public int CarouselIntervalSeconds { get; set; } = 5;        // 图片轮播：切换间隔（秒）
    public bool CarouselRandom { get; set; } = false;            // 图片轮播：随机播放（否则顺序）
    public bool CarouselIncludeSubfolders { get; set; } = false; // 图片轮播：包含子目录
    public string CarouselStretch { get; set; } = "Uniform";     // 图片轮播：填充方式 Uniform/UniformToFill/Fill
    public double CarouselHeight { get; set; } = 140;            // 图片轮播：显示区高度（px）
    public bool CarouselAutoPlay { get; set; } = true;           // 图片轮播：自动播放
    public string? PluginId { get; set; }                        // 插件卡片：插件 ID（对应 plugin.json 中的 id）
    // ===== 快捷方式卡片（原 quickgroups.json 分组数据，已改为面板自有 + item_row 行级存储）=====
    public List<QuickItem>? QuickItems { get; set; }             // 快捷方式卡片：快捷项列表（行级存储）
    public string QuickGroupName { get; set; } = "快捷方式";      // 快捷方式卡片：分组名
    public int QuickColumns { get; set; } = 1;                   // 快捷方式卡片：布局列数（1~4）
    public string QuickDisplayMode { get; set; } = "grid";       // 快捷方式卡片：显示模式 grid/list/popup
    public bool QuickHideFrame { get; set; } = false;            // 快捷方式卡片：隐藏外框（背景/边框/标题栏/内边距）
    public int QuickOrder { get; set; }                          // 快捷方式卡片：排序序号（原分组 Order）
    public string ScreenTimeStyle { get; set; } = "List";        // 屏幕时长卡片展示风格：List/Pie/Category/Window
    public string DailyActivityView { get; set; } = "Month";      // 每日活跃视图模式：Month(当月热力图)/Today(仅今日)/Week(前后5天逐日)
    public string DailyActivityType { get; set; } = "screen";     // 每日活跃卡片展示的数据类型：screen=本地屏幕使用时长，其他=服务端类型（含内置固定类型番茄/屏幕时长/健身记录/鼠标键盘活跃）
    public PomodoroSettings? Pomodoro { get; set; }                    // 番茄闹钟数据
    public List<CheckInItem>? CheckInItems { get; set; }               // 打卡卡片：打卡按钮列表（行级存储）
    public int CheckInColumns { get; set; } = 2;                       // 打卡卡片：每排列数（1~4）
    public string CheckInStyle { get; set; } = "IconTextVertical";     // 打卡卡片：按钮样式（TextOnly/IconOnly/IconTextVertical/IconTextHorizontal）
    /// <summary>归属类型: personal=个人, team=团队</summary>
    public string OwnerType { get; set; } = "personal";
    /// <summary>所属团队 ID（OwnerType=team 时有值）</summary>
    public string? TeamId { get; set; }
    /// <summary>团队名称快照（显示用）</summary>
    public string? TeamName { get; set; }
    /// <summary>来源分享记录ID（分享导入时有值，服务端加密ID，可查分享详情/对账）</summary>
    public string? ShareId { get; set; }
    /// <summary>来源分享短码（分享导入时有值，展示/再分享用）</summary>
    public string? ShareCode { get; set; }
    /// <summary>分享导入模式: null=本地创建/非分享来源, copy=复制, reference=引用</summary>
    public string? ShareMode { get; set; }
    /// <summary>导入权限快照（仅 reference 有意义）：允许编辑数据（含便签/todo 等行数据）</summary>
    public bool AllowEdit { get; set; } = true;
    /// <summary>导入权限快照（仅 reference 有意义）：允许删除行/卡片</summary>
    public bool AllowDelete { get; set; } = true;
    /// <summary>导入权限快照（仅 reference 有意义）：允许再分享</summary>
    public bool AllowReShare { get; set; } = false;
    /// <summary>引用分享且不允许编辑 → 内容只读（拦截一切行数据修改）</summary>
    [Newtonsoft.Json.JsonIgnore]
    public bool IsShareReadOnly => ShareMode == "reference" && !AllowEdit;
    /// <summary>引用分享且不允许删除 → 禁止删除卡片/行</summary>
    [Newtonsoft.Json.JsonIgnore]
    public bool IsShareDeleteBlocked => ShareMode == "reference" && !AllowDelete;
}

/// <summary>
/// 数字员工卡片行包装：行级存储/同步用（原始数据为 List&lt;string&gt; 员工 Id 引用）
/// </summary>
public class DigitalEmployeeRow
{
    public string Id { get; set; } = "";      // = EmployeeId（行唯一标识）
    public string EmployeeId { get; set; } = ""; // 全局员工库中的员工 Id
}

/// <summary>
/// 好友卡片行包装：行级存储/同步用（原始数据为 List&lt;string&gt; 好友 userId 加密串引用）
/// </summary>
public class FriendUserRow
{
    public string Id { get; set; } = "";      // = UserId（行唯一标识）
    public string UserId { get; set; } = "";  // 好友 userId 加密串
}

public class FileAreaItem
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Path { get; set; } = "";      // 文件或文件夹完整路径
    public string Name { get; set; } = "";      // 显示名称
    /// <summary>用户自定义别名：非空时屏幕上优先于 Name 显示（项右键菜单「编辑别名」设置，清空恢复原名）</summary>
    public string? Alias { get; set; }
    public bool IsFolder { get; set; }          // 是否为文件夹
    public DateTime AddedAt { get; set; } = DateTime.Now;

    // ===== 云文件相关（IsCloudFile=true 时有效）=====
    public bool IsCloudFile { get; set; }       // 是否为云文件（云盘导入）
    public string? CloudSpaceId { get; set; }   // 所属云空间 Id（CloudSpaceService）
    public string? CloudSpaceName { get; set; } // 云空间名称快照（如"百度网盘"）
    public string? CloudSpaceIcon { get; set; } // 云空间图标快照（emoji）
    public string? CloudFileId { get; set; }    // 云文件ID / 分享链接 / 提取码
    public string? CloudUrl { get; set; }       // 实际打开的链接（分享链接优先，否则云空间主页）
}

public class ClipboardSavedItem
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Content { get; set; } = "";
    public string ContentType { get; set; } = "Text"; // Text, Image, File
    public DateTime SavedAt { get; set; } = DateTime.Now;
}

/// <summary>
/// 计时器项
/// </summary>
public class TimerItem
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "新计时";
    public int TimeoutSeconds { get; set; } = 3600; // 默认 1 小时
    public bool IsRunning { get; set; } = false;
    public DateTime? StartTime { get; set; }
    public TimeSpan ElapsedTime { get; set; } = TimeSpan.Zero;

    /// <summary>
    /// 勾选后：每次停止计时时，把本次时段时长（分钟）按「计时器名称」写入每日活跃数据（DailyActivityService）。
    /// 默认关闭，不影响原有本地当日统计。
    /// </summary>
    public bool StoreToDailyActivity { get; set; } = false;

    /// <summary>
    /// 历史记录：日期 -> 总秒数
    /// </summary>
    public Dictionary<string, int> DailyRecords { get; set; } = new();

    /// <summary>
    /// 获取总经过时间（含当前运行时段）
    /// </summary>
    public TimeSpan GetElapsed()
    {
        if (IsRunning && StartTime.HasValue)
            return ElapsedTime + (DateTime.Now - StartTime.Value);
        return ElapsedTime;
    }
}

/// <summary>
/// 倒计时项
/// </summary>
public class CountdownItem
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "新倒计时";
    public int TotalSeconds { get; set; } = 3600;        // 倒计时总时长（秒）
    public double RemainingSeconds { get; set; } = 3600; // 剩余秒数（暂停时保存进度）
    public bool IsRunning { get; set; } = false;
    public DateTime? StartTime { get; set; }             // 本次启动的时刻（运行中用于计算已消耗时间）
    public bool IsFinished { get; set; } = false;        // 是否已到期

    // 到时提醒方式
    public bool RemindFlash { get; set; } = true;        // 闪烁窗口
    public bool RemindPopup { get; set; } = true;        // 弹出提示窗口
    public string RemindAction { get; set; } = "None";   // 到时操作：None/Hibernate/Shutdown

    /// <summary>获取当前剩余时间（含运行中的实时计算）</summary>
    public TimeSpan GetRemaining()
    {
        if (IsRunning && StartTime.HasValue)
        {
            var remaining = RemainingSeconds - (DateTime.Now - StartTime.Value).TotalSeconds;
            return TimeSpan.FromSeconds(Math.Max(0, remaining));
        }
        return TimeSpan.FromSeconds(Math.Max(0, RemainingSeconds));
    }
}

/// <summary>
/// 今日待办项
/// </summary>
public class TodoItem
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Text { get; set; } = "";
    public string Description { get; set; } = "";  // 详细内容/备注
    public bool IsDone { get; set; } = false;
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public DateTime? DueTime { get; set; }               // 任务时间（可选）
    public int RemindBeforeMinutes { get; set; } = -1;   // 提前多少分钟提醒；-1=不提醒，0=准时
    public bool Reminded { get; set; } = false;          // 是否已提醒（防重复）
}

/// <summary>
/// 信号灯状态条件：变量按 Op 比较满足；MISSING 时变量缺失/未取到值即满足
/// </summary>
public class SignalLightCondition
{
    public string VarKey { get; set; } = "";   // 数据变量名
    public string Op { get; set; } = "EQ";     // 比较操作符：EQ 等于 / GT 大于 / LT 小于 / MISSING 不存在
    public string Value { get; set; } = "";    // 期望值（用于 EQ/GT/LT）
}

/// <summary>
/// 信号灯项
/// </summary>
public class SignalLightItem
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Color { get; set; } = "#FF4444";   // 灯颜色（hex）
    public double Size { get; set; } = 36;            // 灯直径
    public string? Icon { get; set; }                  // 灯上方图标（emoji/文字，空则无）
    public bool IsOn { get; set; } = true;             // 亮/灭状态（无条件匹配时的手动状态）
    public string LightStyle { get; set; } = "Circle"; // 灯样式：Circle/Square/Pixel
    public List<SignalLightCondition> OnConditions { get; set; } = new();    // 满足 → 开启
    public List<SignalLightCondition> OffConditions { get; set; } = new();   // 满足 → 关闭
    public List<SignalLightCondition> BlinkConditions { get; set; } = new(); // 满足 → 闪烁（优先级最高）
    public string OnConditionMode { get; set; } = "OR";    // 开条件组合：OR 任一满足 / AND 全部满足
    public string OffConditionMode { get; set; } = "OR";   // 关条件组合
    public string BlinkConditionMode { get; set; } = "OR"; // 闪烁条件组合
    public double BlinkIntervalSeconds { get; set; } = 1; // 闪烁频率（秒/次）
}

/// <summary>
/// 番茄闹钟设置与运行状态
/// </summary>
public class PomodoroSettings
{
    /// <summary>行级同步用的稳定 GUID（每个番茄钟仅一条行记录）</summary>
    public string Id { get; set; } = Guid.NewGuid().ToString();

    // 时长配置
    public int WorkMinutes { get; set; } = 25;          // 番茄钟时长（分钟）
    public int ShortBreakMinutes { get; set; } = 5;     // 短休息时长（分钟）
    public int LongBreakMinutes { get; set; } = 15;     // 长休息时长（分钟）
    public int LongBreakInterval { get; set; } = 4;     // 每完成 N 个番茄后进入长休息

    // 行为配置
    public bool AutoStartNext { get; set; } = false;    // 阶段结束后自动开始下一阶段
    public bool RemindFlash { get; set; } = true;       // 结束时闪烁窗口
    public bool RemindPopup { get; set; } = true;       // 结束时弹出提示窗口

    // 运行状态（仅本地持久化，不参与云同步/分享；同步只带番茄数与时长等配置）
    public string Mode { get; set; } = "Work";          // 当前模式：Work/ShortBreak/LongBreak
    public double RemainingSeconds { get; set; } = 25 * 60;
    public bool IsRunning { get; set; } = false;
    public DateTime? StartTime { get; set; }            // 本次启动时刻（运行中用于计算已消耗时间）
    public int CompletedCount { get; set; } = 0;        // 当日已完成番茄数
    public string? CompletedDate { get; set; }          // 计数所属日期（yyyy-MM-dd，跨天自动清零）

    /// <summary>获取当前模式的总时长（秒）</summary>
    public int GetModeTotalSeconds() => Mode switch
    {
        "ShortBreak" => ShortBreakMinutes * 60,
        "LongBreak" => LongBreakMinutes * 60,
        _ => WorkMinutes * 60
    };

    /// <summary>获取当前剩余时间（含运行中的实时计算）</summary>
    public TimeSpan GetRemaining()
    {
        if (IsRunning && StartTime.HasValue)
        {
            var remaining = RemainingSeconds - (DateTime.Now - StartTime.Value).TotalSeconds;
            return TimeSpan.FromSeconds(Math.Max(0, remaining));
        }
        return TimeSpan.FromSeconds(Math.Max(0, RemainingSeconds));
    }

    /// <summary>确保计数为当天（跨天清零）</summary>
    public void EnsureTodayCount()
    {
        var today = DateTime.Now.ToString("yyyy-MM-dd");
        if (CompletedDate != today)
        {
            CompletedDate = today;
            CompletedCount = 0;
        }
    }
}

/// <summary>
/// 打卡项：一个可点击的打卡按钮，每点一次当日计数 +1，并镜像写入「每日活跃」同名类型。
/// 与番茄钟 CompletedCount 同构：本地保留当日计数（离线可用、跨天自动清零），点击时同步累加到服务端每日活跃。
/// </summary>
public class CheckInItem
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Text { get; set; } = "";              // 打卡内容文字（同时作为「每日活跃」的类型名）
    public string Icon { get; set; } = "";              // emoji 图标
    public string Color { get; set; } = "#4A90D9";      // 主题色（hex）
    public int Count { get; set; } = 0;                 // 当日打卡次数
    public string? CountDate { get; set; }              // 计数所属日期（yyyy-MM-dd，跨天自动清零）
    public int SortIndex { get; set; } = 0;             // 排序序号

    /// <summary>确保计数为当天（跨天清零）</summary>
    public void EnsureTodayCount()
    {
        var today = DateTime.Now.ToString("yyyy-MM-dd");
        if (CountDate != today)
        {
            CountDate = today;
            Count = 0;
        }
    }

    /// <summary>当日打卡次数（跨天未点击时返回 0，不改动持久值，供渲染展示）</summary>
    public int TodayCount()
        => CountDate == DateTime.Now.ToString("yyyy-MM-dd") ? Count : 0;
}

public class WindowConfig
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string? ServerId { get; set; }  // 云同步服务器端 ID（服务器返回，持久化到 windows.json；null=尚未同步）
    public string Name { get; set; } = "新窗口";
    public string? BGColor { get; set; }   // 窗口(bar)自定义背景色（hex字符串，null=跟随主题）
    public WindowType Type { get; set; } = WindowType.Native;
    public string? Url { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.Now;
    public List<PanelItem> Panels { get; set; } = new();
    public bool IsEditMode { get; set; } = false;
    public bool IsAppMode { get; set; } = false;
    /// <summary>窗口级启用的工具列表（底部工具栏）。默认含 AIChat（#511）。必须 Replace：Newtonsoft 默认复用既有集合再追加，列表会逐次增长（#598）</summary>
    [JsonProperty(ObjectCreationHandling = ObjectCreationHandling.Replace)] public List<string> EnabledTools { get; set; } = new() { "AIChat" };
    /// <summary>是否开启鼠键记录器（每条侧边栏独立：开启才安装键鼠钩子计数并显示底部状态栏；关闭不记录不显示）</summary>
    public bool KeyMouseRecorderEnabled { get; set; } = false;
    /// <summary>是否显示在顶部标签列表中（微屏管理中勾选才显示）</summary>
    public bool ShowInTabs { get; set; } = true;
    /// <summary>归属类型: personal=个人, team=团队</summary>
    public string OwnerType { get; set; } = "personal";
    /// <summary>所属团队 ID（OwnerType=team 时有值）</summary>
    public string? CorpId { get; set; }
    /// <summary>分享导入模式: null=本地创建, copy=复制, reference=引用</summary>
    public string? ShareMode { get; set; }
    /// <summary>引用模式时指向源窗口的 serverId</summary>
    public string? SourceBarId { get; set; }
    /// <summary>来源分享记录ID（分享导入时有值，服务端加密ID，可查分享详情/对账）</summary>
    public string? ShareId { get; set; }
    /// <summary>来源分享短码（分享导入时有值，展示/再分享用）</summary>
    public string? ShareCode { get; set; }
    /// <summary>导入权限快照（仅 reference 有意义）：允许编辑数据（含卡片内行数据）</summary>
    public bool AllowEdit { get; set; } = true;
    /// <summary>导入权限快照（仅 reference 有意义）：允许删除</summary>
    public bool AllowDelete { get; set; } = true;
    /// <summary>导入权限快照（仅 reference 有意义）：允许再分享</summary>
    public bool AllowReShare { get; set; } = false;
    /// <summary>引用分享且不允许编辑 → 窗口内所有卡片内容只读</summary>
    [Newtonsoft.Json.JsonIgnore]
    public bool IsShareReadOnly => ShareMode == "reference" && !AllowEdit;
    /// <summary>引用分享且不允许删除 → 窗口内卡片禁止删除</summary>
    [Newtonsoft.Json.JsonIgnore]
    public bool IsShareDeleteBlocked => ShareMode == "reference" && !AllowDelete;
}

public class DockWindowState
{
    public List<string> WindowIds { get; set; } = new();
    public int ActiveIndex { get; set; } = 0;
}

// NOTE(port): WindowConfigManager (Windows Models/WindowConfig.cs L386-879) is an
// application/persistence orchestrator (LocalDbService + AppContainer + CloudSync),
// not a domain model. Under the layered/seam architecture it belongs to the SERVICE
// layer — deferred to Phase 2, to be re-ported from the untouched Windows source and
// wired through Core seam interfaces. Kept out of SideDesk.Core for now.
