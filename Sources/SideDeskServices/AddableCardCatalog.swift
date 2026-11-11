import Foundation
import SideDeskCore

/// 可添加卡片的目录条目。对应 C# `NativeModePanel.AddableCard` record。
///
/// C#  record 里的 `RoutedEventHandler Add` 在 Swift 侧不需要：所有创建默认值收敛到
/// `AddableCardCatalog.makePanelItem(for:)`（WPF 的 handler 差异本质只是初始数据不同）。
/// `icon` 是 C# 的 UiIcons 语义名，mac 侧图标字体尚未移植，此处仅作数据保留。
public struct AddableCard: Identifiable, Equatable {
    public let icon: String
    public let titleKey: String
    public let type: PanelType
    public let categoryKey: String
    /// 入口收敛（对应 C# 的 `Hidden`）：仍在目录数据里，但不进「添加卡片」列表。
    public let hidden: Bool

    public var id: Int { type.rawValue }

    public init(icon: String, titleKey: String, type: PanelType,
                categoryKey: String, hidden: Bool = false) {
        self.icon = icon
        self.titleKey = titleKey
        self.type = type
        self.categoryKey = categoryKey
        self.hidden = hidden
    }
}

/// 「添加卡片」的分类分组。对应 C# `SideDesk.UI.CardCategory`。
public struct AddableCardCategory: Identifiable {
    public let titleKey: String
    public let cards: [AddableCard]
    public var id: String { titleKey }
}

/// 可添加卡片**单一事实源**。对应 C# `NativeModePanel.AddCards.cs` 的 `BuildAddableCards()`。
///
/// 与 C# 的差异（都因 mac 侧子系统尚未移植，属"少搬"而非改语义）：
/// - 去掉 `ModuleUi`（模块卡：C# 弹模块选择对话框，模块目录未移植）；
/// - 去掉 `Friend`（好友：C# 弹云端用户选择，登录态未移植）；
/// - 去掉分类收尾的「从团队卡片库添加」动作项（团队协作 UI 未移植），`addCard.catTeam` 分类因此通常为空；
/// - `QuickGroup` 的分组名输入对话框（C# `ShowGroupNameDialog`）未接：直接用模型默认名创建，
///   改名走后续的重命名入口。
///
/// 条目顺序 = 菜单线性序；分类分组顺序另见 `categoryOrder`（与 C# `CatalogCategoryOrder` 同）。
public enum AddableCardCatalog {

    public static let all: [AddableCard] = [
        AddableCard(icon: "bolt", titleKey: "common.shortcut", type: .QuickGroup, categoryKey: "addCard.catEfficiency"),
        AddableCard(icon: "edit", titleKey: "common.stickyNotes", type: .StickyNotes, categoryKey: "addCard.catBasic"),
        AddableCard(icon: "edit", titleKey: "common.notes", type: .Notes, categoryKey: "addCard.catBasic"),
        AddableCard(icon: "todo", titleKey: "common.todayTodos", type: .TodoList, categoryKey: "addCard.catTodo"),
        AddableCard(icon: "clipboard", titleKey: "common.clipboardFavorites", type: .Clipboard, categoryKey: "addCard.catTodo"),
        AddableCard(icon: "monitor", titleKey: "common.systemInfo", type: .SystemMonitor, categoryKey: "addCard.catData"),
        AddableCard(icon: "stats", titleKey: "common.usageStatistics", type: .UsageStats, categoryKey: "addCard.catData", hidden: true),
        AddableCard(icon: "stats", titleKey: "common.screenTime", type: .ScreenTime, categoryKey: "addCard.catData"),
        AddableCard(icon: "chat", titleKey: "common.aiChat", type: .AIChat, categoryKey: "addCard.catEfficiency"),
        AddableCard(icon: "folder", titleKey: "common.fileArea", type: .FileArea, categoryKey: "addCard.catBasic"),
        AddableCard(icon: "trend", titleKey: "common.dataDashboard", type: .DataDashboard, categoryKey: "addCard.catData"),
        AddableCard(icon: "timer", titleKey: "common.timer", type: .Timer, categoryKey: "addCard.catTime"),
        AddableCard(icon: "hourglass", titleKey: "common.countdown", type: .Countdown, categoryKey: "addCard.catTime"),
        AddableCard(icon: "tomato", titleKey: "common.pomodoroAlarm", type: .Pomodoro, categoryKey: "addCard.catEfficiency"),
        AddableCard(icon: "traffic", titleKey: "common.signalLight", type: .SignalLight, categoryKey: "addCard.catData"),
        AddableCard(icon: "check", titleKey: "common.checkIn", type: .CheckIn, categoryKey: "addCard.catTodo"),
        AddableCard(icon: "image", titleKey: "common.imageCarousel", type: .ImageCarousel, categoryKey: "addCard.catData"),
        AddableCard(icon: "fire", titleKey: "common.dailyActivity", type: .DailyActivity, categoryKey: "addCard.catTodo"),
        AddableCard(icon: "calendar", titleKey: "common.calendar", type: .Calendar, categoryKey: "addCard.catTime"),
        AddableCard(icon: "user", titleKey: "common.digitalEmployees", type: .DigitalEmployee, categoryKey: "addCard.catSocial", hidden: true),
        AddableCard(icon: "search", titleKey: "settings.baiduSearch", type: .WebBaidu, categoryKey: "addCard.catSocial"),
    ]

    /// 添加卡片对话框的分组顺序（对应 C# `CatalogCategoryOrder`）。
    public static let categoryOrder: [String] = [
        "addCard.catBasic", "addCard.catEfficiency", "addCard.catTodo",
        "addCard.catTime", "addCard.catData", "addCard.catSocial", "addCard.catTeam",
    ]

    /// 分组卡片（对应 C# `BuildCardCatalog` 在 catBasic 首位插入的结构项「分组」）：
    /// 它不是 `BuildAddableCards` 的成员，但同样是 PanelType 卡片，故在此单独造。
    public static let groupCard = AddableCard(
        icon: "group", titleKey: "common.group", type: .Group, categoryKey: "addCard.catBasic")

    /// 按分类分组后的目录（对应 C# `BuildCardCatalog()`）。`includeHidden` 仅用于核对数据表，
    /// UI 一律传 false（与 C# 的 `!c.Hidden` 过滤同义）。
    public static func categories(includeHidden: Bool = false) -> [AddableCardCategory] {
        var result: [AddableCardCategory] = []
        for catKey in categoryOrder {
            var cards = all.filter { $0.categoryKey == catKey && (includeHidden || !$0.hidden) }
            if catKey == "addCard.catBasic" && !cards.isEmpty {
                // 结构项「分组」始终排首位（C# entries.Insert(0, …)）
                cards.insert(groupCard, at: 0)
            }
            if !cards.isEmpty {
                result.append(AddableCardCategory(titleKey: catKey, cards: cards))
            }
        }
        return result
    }

    /// 新建卡片的初始数据。对应 C# `AddPanel(PanelType)` 与各 `AddXxxPanel_Click` 的默认值分支：
    /// 哪些类型带默认数据、哪些是空卡片，逐条与 C# 对齐（C# 注释明示 Timer/Pomodoro 等
    /// "带默认数据初始化，不能降级成 AddPanel(type)"，这里用同一张 switch 表达）。
    public static func makePanelItem(for type: PanelType) -> PanelItem {
        let item = PanelItem()
        item.`Type` = type
        switch type {
        case .StickyNotes:
            // C#：初始化为空列表，避免触发全局迁移逻辑
            item.StickyNotes = []
        case .Notes:
            item.DeskNotes = []
        case .TodoList:
            item.TodoItems = []
        case .Group:
            item.Title = Lang.t("nativePanel.newGroup")
            item.ChildPanels = []
            item.IsExpanded = true
        case .QuickGroup:
            // C# 先弹命名对话框再建卡（QuickColumns=2、空快捷项）；命名对话框未接，取模型默认名
            item.QuickColumns = 2
            item.QuickItems = []
        case .SignalLight:
            item.Title = Lang.t("nativePanel.signalLight")
            func light(_ color: String) -> SignalLightItem {
                let s = SignalLightItem()
                s.Color = color; s.Size = 36; s.Icon = ""; s.IsOn = true
                return s
            }
            item.SignalLights = [light("#FF4444"), light("#FFAA00"), light("#44CC44")]
        case .CheckIn:
            item.Title = Lang.t("common.checkIn")
            item.CheckInColumns = 2
            func preset(_ textKey: String, _ icon: String, _ color: String, _ sort: Int) -> CheckInItem {
                let c = CheckInItem()
                c.Text = Lang.t(textKey); c.Icon = icon; c.Color = color; c.SortIndex = sort
                return c
            }
            item.CheckInItems = [
                preset("nativePanel.presetDrinkWater", "💧", "#3498DB", 0),
                preset("nativePanel.presetStandUp", "🧍", "#2ECC71", 1),
                preset("nativePanel.presetEyeRest", "👀", "#E67E22", 2),
            ]
        case .Timer:
            item.Title = Lang.t("nativePanel.timer")
            // 默认 1 个计时器（C#：支持 0-n，空卡片会显得没建起来）
            item.TimerItems = [TimerItem()]
        case .Countdown:
            item.Title = Lang.t("nativePanel.countdown")
            item.CountdownItems = []
        case .Pomodoro:
            item.Title = Lang.t("nativePanel.pomodoro")
            item.Pomodoro = PomodoroSettings()
        case .DataDashboard:
            item.Title = Lang.t("common.dataDashboard")
            item.DashboardItems = []
        case .Clipboard, .SystemMonitor, .UsageStats, .ScreenTime, .AIChat, .FileArea,
             .ClipboardHistory, .DailyActivity, .Calendar, .ImageCarousel, .WebBaidu,
             .Plugin, .Dsh, .DigitalEmployee, .Friend, .ModuleUi:
            // C# `AddPanel(type)` 的空卡片分支：这些类型创建时不带默认数据
            break
        }
        return item
    }
}
