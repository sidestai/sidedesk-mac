import Foundation
import SideDeskCore

/// 窗口（bar）配置管理器：内存容器 + SQLite 加载/保存编排。对应 C# `WindowConfigManager`（`Models/WindowConfig.cs`）。
///
/// 本批（T3 本地持久化地基）移植核心：`Load`/`Save`（走 `LocalDbService` 关系树）、
/// 窗口 CRUD、`EnsureDefault`（示例播种）、`EnsureAtLeastOneBar`、`RepairDockMembership`。
///
/// **推迟到后续批次**（依赖尚未移植的服务或仅对 Windows 升级用户有意义，fresh Mac 均为无操作）：
/// - 遗留 `windows.json` → SQLite 迁移（`LoadCore` 的 JSON 分支、`ImportFromJsonFile`、`ArchiveLegacyWindowsJsonOnce`）
/// - 一次性 bug 修复：`MigrateLegacyStickyNotesOnce` / `PurgeEmptyStickyNotesOnce` /
///   `ConsolidateDuplicateWindowsOnce` / `DedupPanelsSharingServerIdOnce`（针对云同步污染的历史数据）
/// - 服务预热（AIConfig/CloudSpace/TitleLockRule）与 `QuickGroupService.Init`
public final class WindowConfigManager: Codable {
    public var Windows: [WindowConfig] = []
    public var LeftDock = DockWindowState()
    public var RightDock = DockWindowState()
    /// 全局后台数据看板项（不绑定任何面板，仅后台轮询）
    public var BackgroundDashboardItems: [DataDashboardItem] = []
    /// 变量集定义（多变量聚合，生成本地新变量）
    public var VariableSets: [VariableSet] = []

    /// 本内存实例加载时所归属的数据作用域（"local" 或 "u:{密文}"），由 `loadManager` 打标。
    /// 与 `LocalDbService.currentScope()` 不一致 → 登录态已变更而窗口尚未按新作用域重载，
    /// 任何"以内存为准"的全量写库都会清空新作用域数据，故 `saveManager` 会拒绝。
    /// 不参与序列化（对应 C# `[JsonIgnore]`）。
    public var LoadedScope: String?

    private enum CodingKeys: CodingKey {
        case Windows, LeftDock, RightDock, BackgroundDashboardItems, VariableSets
    }

    public init() {}

    // MARK: - 加载 / 保存

    /// 加载全量配置。对应 C# `WindowConfigManager.Load()`。
    public static func Load() -> WindowConfigManager {
        let mgr = loadCore()
        // 作用域戳兜底：loadManager 已按实际作用域打标；空实例语义是"当前作用域无数据"，同样按当前作用域打标
        if mgr.LoadedScope == nil || mgr.LoadedScope!.isEmpty {
            mgr.LoadedScope = LocalDbService.currentScope()
        }
        // dock 成员自愈：dock 状态与窗口表是两份独立持久化，异常写入可能使二者脱节
        mgr.RepairDockMembership()
        // 推迟：QuickGroupService.Init、AIConfig/CloudSpace/DigitalEmployee/TitleLockRule 预热
        return mgr
    }

    private static func loadCore() -> WindowConfigManager {
        // 主存储：SQLite。C# 的"损坏库改名留存 + 降级 windows.json"分支依赖遗留 JSON 迁移，本批推迟；
        // 无库时 loadManager 返回空实例（LoadedScope 已打标），由调用方 EnsureDefault 播种。
        return LocalDbService.loadManager()
    }

    /// 保存全量配置。对应 C# `WindowConfigManager.Save()`。
    public func Save() {
        // 主存储：SQLite 单事务全量写入（内含作用域一致性守卫）
        LocalDbService.saveManager(self)
        // 行级变更通知：防抖 2 秒后差分推送（未开云同步/未登录时内部直接返回；
        // 服务未登记时 resolve 为 nil 静默跳过——测试与无云同步宿主不受影响）
        AppContainer.shared.resolve(CloudSyncService.self)?.notifyRowsChanged()
        // 推迟：ArchiveLegacyWindowsJsonOnce（遗留 windows.json 归档，仅 Windows 升级用户有意义）
    }

    // MARK: - 窗口 CRUD

    public func GetById(_ id: String) -> WindowConfig? {
        Windows.first { $0.Id == id }
    }

    public func Add(_ config: WindowConfig) {
        Windows.append(config)
        Save()
    }

    /// 新增微屏并同步加入左右两侧 dock 顶部标签（双侧布局下所有窗口都能看到新微屏）。
    public func AddToAllDocks(_ config: WindowConfig) {
        Windows.append(config)
        if !LeftDock.WindowIds.contains(config.Id) { LeftDock.WindowIds.append(config.Id) }
        if !RightDock.WindowIds.contains(config.Id) { RightDock.WindowIds.append(config.Id) }
        Save()
    }

    public func Remove(_ id: String) {
        Windows.removeAll { $0.Id == id }
        LeftDock.WindowIds.removeAll { $0 == id }
        RightDock.WindowIds.removeAll { $0 == id }
        Save()
    }

    /// 新建一个空的「虚拟屏幕」（窗口标签），加入两侧 dock 并随即切为活动项。
    /// 对应 C# `MainWindow.CreateNewWindow`：新建 `WindowConfig` → 入 dock → 切到它。
    /// 名称走 `Lang.t`（用户可见文案红线），默认「新窗口」。
    @discardableResult
    public func CreateNewWindow() -> WindowConfig {
        let win = WindowConfig()
        win.Name = Lang.t("common.newWindow")
        win.`Type` = .Native
        win.ShowInTabs = true
        win.Panels = []
        Windows.append(win)
        if !LeftDock.WindowIds.contains(win.Id) { LeftDock.WindowIds.append(win.Id) }
        if !RightDock.WindowIds.contains(win.Id) { RightDock.WindowIds.append(win.Id) }
        // 新建即活动：两侧 dock 同序，各取新窗口在自身 WindowIds 里的下标
        if let li = LeftDock.WindowIds.firstIndex(of: win.Id) { LeftDock.ActiveIndex = li }
        if let ri = RightDock.WindowIds.firstIndex(of: win.Id) { RightDock.ActiveIndex = ri }
        Save()
        return win
    }

    /// 重命名窗口（虚拟屏幕标签名）。空名/纯空白忽略（对应 C# 编辑窗口的名称校验口径）。
    public func RenameWindow(_ id: String, _ name: String) {
        guard let win = GetById(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        win.Name = trimmed
        Save()
    }

    // MARK: - 示例数据播种

    /// 样例数据初始化的一次性标记 key（按账号作用域隔离，存 local_app_state）。
    private static let DefaultBarSeededFlag = "default_bar_seeded"

    /// 仅新安装（当前作用域未置标）且无任何 bar 时创建默认 bar 并填充示例面板；置标后删光也不再自动填充。
    /// 对应 C# `WindowConfigManager.EnsureDefault()`。
    ///
    /// 面板名走 `Lang.t(...)`（用户可见文案红线）；示例正文/URL 是"用户数据默认值"，
    /// 属 i18n 规则明确豁免项，沿用 C# 的编译区域常量（`#if API_REGION_EN`）。
    public func EnsureDefault() {
        if LocalDbService.getStateFlag(Self.DefaultBarSeededFlag) { return }
        // 全库只播一次：其他作用域已播过时，本作用域只置标不播（否则登出/切号会再播一份示例造成重复窗口）
        if LocalDbService.anyScopeStateFlag(Self.DefaultBarSeededFlag) {
            LocalDbService.setStateFlag(Self.DefaultBarSeededFlag)
            return
        }
        LocalDbService.setStateFlag(Self.DefaultBarSeededFlag)

        guard Windows.isEmpty else { return }

        #if API_REGION_EN
        let noteHowTo = "How to use SideDesk\n· Right-click the sidebar to add or edit modules\n· Drag a module's title bar to reorder\n· Change theme, language and dock side in Settings"
        let noteWelcome = "Welcome to SideDesk!\nA smart sidebar that lives on the edge of your screen: notes, todos, shortcuts, timers... always within reach, no window switching."
        let groupName = "Frequent Sites"
        let browserName = "MetaDesk"
        let browserUrl = "https://www.desktxp.com"
        let officialName = "Official Site"
        let bingName = "Bing"
        let todoEat = "Eat"
        let todoSleep = "Sleep"
        #else
        let noteHowTo = "如何使用微屏\n· 右键侧边栏可添加/编辑卡片\n· 拖拽卡片标题栏可排序\n· 设置中可换主题、语言与停靠位置"
        let noteWelcome = "欢迎使用微屏！\n这是一条常驻屏幕边缘的智能侧边栏：便签、待办、快捷方式、计时器……触手可及，无需切换窗口。"
        let groupName = "常用网址"
        let browserName = "元桌浏览器"
        let browserUrl = "https://yzllq.com"
        let officialName = "微屏官网"
        let bingName = "必应"
        let todoEat = "吃饭"
        let todoSleep = "睡觉"
        #endif

        let defaultWin = WindowConfig()
        defaultWin.Name = Lang.t("common.home")
        defaultWin.`Type` = .Native

        // ① 便签：使用指南 + 欢迎文案
        let sticky = PanelItem()
        sticky.`Type` = .StickyNotes
        sticky.StickyNotes = [
            { let n = StickyNote(); n.Content = noteHowTo; return n }(),
            { let n = StickyNote(); n.Content = noteWelcome; return n }(),
        ]

        // ② 快捷组：常用网址（单列列表）
        let quick = PanelItem()
        quick.`Type` = .QuickGroup
        quick.QuickGroupName = groupName
        quick.QuickColumns = 1
        func quickItem(_ name: String, _ url: String, _ sort: Int) -> QuickItem {
            let q = QuickItem()
            q.Name = name; q.`Type` = "url"; q.Target = url; q.SortIndex = sort
            q.BackgroundColor = nil   // 示例项透明底（QuickItem() 默认蓝仅用于新建兜底，示例不上色）
            return q
        }
        quick.QuickItems = [
            quickItem(browserName, browserUrl, 0),
            quickItem(bingName, "https://www.bing.com", 1),
            quickItem("DEEPSEEK", "https://chat.deepseek.com", 2),
            quickItem(officialName, Constants.URLs.homePageBaseUrl, 3),
        ]

        // ③ 分组：内嵌信号灯（红/黄/绿三灯竖排，与手动添加的默认配置一致）
        let group = PanelItem()
        group.`Type` = .Group
        group.Title = Lang.t("nativePanel.newGroup")
        group.IsExpanded = true
        let signal = PanelItem()
        signal.`Type` = .SignalLight
        signal.Title = Lang.t("nativePanel.signalLight")
        signal.SignalLightVertical = true
        func light(_ color: String) -> SignalLightItem {
            let s = SignalLightItem(); s.Color = color; s.Size = 36; s.Icon = ""; s.IsOn = true; return s
        }
        signal.SignalLights = [light("#FF4444"), light("#FFAA00"), light("#44CC44")]
        group.ChildPanels = [signal]

        // ④ 今日待办：示例任务
        let todo = PanelItem()
        todo.`Type` = .TodoList
        todo.TodoItems = [
            { let t = TodoItem(); t.Text = todoEat; return t }(),
            { let t = TodoItem(); t.Text = todoSleep; return t }(),
        ]

        // ⑤ 番茄闹钟：默认 25 分钟番茄钟
        let pomo = PanelItem()
        pomo.`Type` = .Pomodoro
        pomo.Pomodoro = PomodoroSettings()

        defaultWin.Panels = [sticky, quick, group, todo, pomo]
        Windows.append(defaultWin)
        LeftDock.WindowIds.append(defaultWin.Id)
        RightDock.WindowIds.append(defaultWin.Id)
        Save()
    }

    /// 兜底保证至少存在一个 bar：所有 bar 被删光时创建一个空原生 bar，
    /// 否则侧边栏折叠致右键失效、且无「新建微屏」入口，陷入死状态。
    /// 与 `EnsureDefault` 不同：这里只建一个空 bar（尊重用户已清空内容的意图）。
    public func EnsureAtLeastOneBar() {
        guard Windows.isEmpty else { return }
        let win = WindowConfig()
        win.Name = Lang.t("common.home")
        win.`Type` = .Native
        win.Panels = []
        AddToAllDocks(win)
    }

    /// dock 成员自愈：清理指向已删除窗口的孤儿 id（越界 ActiveIndex 回落末尾），
    /// 并把 ShowInTabs=true 但不在 dock 里的窗口按 Windows 顺序补回两侧 dock（只补末尾，保留既有拖拽顺序）。
    /// 对应 C# `WindowConfigManager.RepairDockMembership()`。仅修内存，随后续正常 Save 落库。
    public func RepairDockMembership() {
        var changed = false

        for dock in [LeftDock, RightDock] {
            let before = dock.WindowIds.count
            dock.WindowIds.removeAll { GetById($0) == nil }
            if dock.WindowIds.count != before { changed = true }
            if dock.ActiveIndex >= dock.WindowIds.count {
                dock.ActiveIndex = max(0, dock.WindowIds.count - 1)
            }
        }

        for win in Windows {
            guard win.ShowInTabs else { continue }
            if !LeftDock.WindowIds.contains(win.Id) { LeftDock.WindowIds.append(win.Id); changed = true }
            if !RightDock.WindowIds.contains(win.Id) { RightDock.WindowIds.append(win.Id); changed = true }
        }
        if changed {
            RuntimeLog.debug("[WindowConfig] dock membership repaired: \(LeftDock.WindowIds.count) left / \(RightDock.WindowIds.count) right")
        }
    }

    // MARK: - 面板树工具

    /// 深度优先遍历面板树（含子面板）。对应 C# `WindowConfigManager.EnumerateAllPanels`。
    public static func enumerateAllPanels(_ panels: [PanelItem]) -> [PanelItem] {
        var out: [PanelItem] = []
        for p in panels {
            out.append(p)
            if let children = p.ChildPanels { out.append(contentsOf: enumerateAllPanels(children)) }
        }
        return out
    }
}
