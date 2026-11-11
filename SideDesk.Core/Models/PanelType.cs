namespace SideDesk.Models;

/// <summary>
/// 卡片（面板）类型：与 <see cref="PanelItem.Type"/> 一一对应，序列化为整数存进 windows.json。
/// **新增成员只能追加在末尾** —— 冻结夹具按枚举值覆盖全部面板类型（tests/SideDesk.Tests/WindowsFrozenFixtureTests.cs）。
/// 2026-10-05 自 WindowConfig.cs 拆出（ADR-0011：巨型类只减不增）。
/// </summary>
public enum PanelType
{
    QuickGroup,      // 快捷方式
    StickyNotes,     // 便签
    Clipboard,       // 剪贴板收藏
    SystemMonitor,   // 系统信息/计数器
    UsageStats,      // 使用统计
    AIChat,          // AI 对话
    FileArea,        // 文件区
    ClipboardHistory,  // 剪贴板历史
    DataDashboard,     // 数据看板
    Timer,           // 计时器
    Group,           // 分组
    TodoList,        // 今日待办
    SignalLight,     // 信号灯
    DigitalEmployee, // 数字员工
    Friend,          // 好友
    ImageCarousel,   // 图片轮播
    DailyActivity,   // 每日活跃
    Calendar,        // 日历
    Plugin,          // 外部插件
    ScreenTime,      // 屏幕时长
    Countdown,       // 倒计时器
    Pomodoro,        // 番茄闹钟
    WebBaidu,        // 百度搜索（内嵌网页组件）
    CheckIn,         // 打卡（多个打卡按钮，点击计数并写入每日活跃）
    Dsh,             // 已弃用（DSH 迁至外部插件，走 Plugin 卡片）：保留占位以免挪动其后续枚值（持久化为整数），存量该型卡片不再渲染
    Notes,           // 记事（Markdown 笔记，独立于便签）
    ModuleUi,        // 第三方模块卡（#657 批 2）：渲染模块声明的 sideui/v1 布局
}
