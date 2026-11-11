import Foundation

/// 快捷项。对应 C# `Models.QuickItem`。
///
/// 注：C# 的 `[JsonIgnore] IntPtr WindowHandle` 运行时句柄字段未在 Core 模型中保留——
/// 它从不持久化，macOS 端由窗口/UI 层按 Id 侧表跟踪（更清晰的分层）。
public final class QuickItem: Codable {
    public var Id: String
    public var Name: String = ""
    /// Emoji 图标字符（如 📁）。
    public var Icon: String?
    /// "url" / "program"。
    public var `Type`: String = "url"
    /// 网址或程序路径。
    public var Target: String = ""
    /// URL 类型：是否 App 模式打开。
    public var UseAppMode: Bool = true
    /// URL 类型：是否用内置浏览器弹窗打开（#57）；默认外部浏览器。
    public var UseBuiltinBrowser: Bool = false
    public var BackgroundColor: String?   // #RRGGBB；nil/空 = 透明
    public var CreatedAt: Date

    /// 是否窗口置顶。
    public var AlwaysOnTop: Bool = false
    /// 是否允许该窗口在系统 Dock/任务切换中显示。
    public var ShowInTaskbar: Bool = false

    /// 是否保存为「长期窗口」：启动时按匹配规则接管现有窗口。
    public var IsLongTermWindow: Bool = false
    public var MatchTitle: String?
    public var MatchTitleMode: String = "contains"   // exact / contains
    public var MatchClass: String?
    public var MatchExe: String?

    /// 项来源标记："window" = 通过「添加窗口」接管创建；非接管项为 nil。
    public var Source: String?

    public var BrowserExeId: String?
    public var BrowserProfileId: String?
    /// 程序启动时的命令行参数（无参数为 nil）。
    public var LaunchArgs: String?
    public var BrowserId: String?
    public var ProfileId: String?
    /// 高级项（Type="advanced"）动作配置 JSON；非高级项为 nil。
    public var AdvancedConfigJson: String?
    /// 组内排序序号（越小越靠前）。
    public var SortIndex: Int = 0

    public init() {
        Id = newGuidId()
        CreatedAt = Date()
        BackgroundColor = "#3498DB"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, newGuidId())
        Name = c.or(.Name, "")
        Icon = c.opt(.Icon)
        `Type` = c.or(.`Type`, "url")
        Target = c.or(.Target, "")
        UseAppMode = c.or(.UseAppMode, true)
        UseBuiltinBrowser = c.or(.UseBuiltinBrowser, false)
        BackgroundColor = c.opt(.BackgroundColor)
        CreatedAt = c.or(.CreatedAt, Date())
        AlwaysOnTop = c.or(.AlwaysOnTop, false)
        ShowInTaskbar = c.or(.ShowInTaskbar, false)
        IsLongTermWindow = c.or(.IsLongTermWindow, false)
        MatchTitle = c.opt(.MatchTitle)
        MatchTitleMode = c.or(.MatchTitleMode, "contains")
        MatchClass = c.opt(.MatchClass)
        MatchExe = c.opt(.MatchExe)
        Source = c.opt(.Source)
        BrowserExeId = c.opt(.BrowserExeId)
        BrowserProfileId = c.opt(.BrowserProfileId)
        LaunchArgs = c.opt(.LaunchArgs)
        BrowserId = c.opt(.BrowserId)
        ProfileId = c.opt(.ProfileId)
        AdvancedConfigJson = c.opt(.AdvancedConfigJson)
        SortIndex = c.or(.SortIndex, 0)
    }
}

/// 快捷卡片「分组」内存门面：与 `PanelItem(Type=QuickGroup)` 一一对应，所有属性代理到面板。
/// 仅为兼容 UI 层调用保留，不参与持久化。对应 C# `Models.QuickGroup`。
public final class QuickGroup {
    /// 底层面板（所有属性的真实存储处）。
    public let Panel: PanelItem

    public convenience init() { self.init(PanelItem()) }

    public init(_ panel: PanelItem) {
        Panel = panel
        panel.`Type` = .QuickGroup
    }

    public var Id: String { Panel.Id }
    public var Name: String { get { Panel.QuickGroupName } set { Panel.QuickGroupName = newValue } }
    public var Columns: Int { get { Panel.QuickColumns } set { Panel.QuickColumns = newValue } }
    public var IsExpanded: Bool { get { Panel.IsExpanded } set { Panel.IsExpanded = newValue } }
    public var HideFrame: Bool { get { Panel.QuickHideFrame } set { Panel.QuickHideFrame = newValue } }
    public var DisplayMode: String { get { Panel.QuickDisplayMode } set { Panel.QuickDisplayMode = newValue } }
    public var Order: Int { get { Panel.QuickOrder } set { Panel.QuickOrder = newValue } }
    public var OwnerType: String { get { Panel.OwnerType } set { Panel.OwnerType = newValue } }
    public var TeamId: String? { get { Panel.TeamId } set { Panel.TeamId = newValue } }
    public var TeamName: String? { get { Panel.TeamName } set { Panel.TeamName = newValue } }

    /// 快捷项：直接引用面板列表本体，增删即时生效。
    public var Items: [QuickItem] {
        get { Panel.QuickItems ?? [] }
        set { Panel.QuickItems = newValue }
    }

    /// 分组内子卡片列表。
    public var ChildPanels: [PanelItem]? {
        get { Panel.ChildPanels }
        set { Panel.ChildPanels = newValue }
    }
}

// ===== 浏览器 Profile 管理 =====

public final class BrowserExeEntry: Codable {
    public var Id: String = newGuidId()
    public var Name: String = ""        // 显示名，如 "Chrome"、"Edge"
    public var ExePath: String = ""     // 浏览器可执行文件完整路径
    public init() {}
}

public final class BrowserProfileEntry: Codable {
    public var Id: String = newGuidId()
    public var Name: String = ""          // 显示名，如 "工作"、"个人"
    public var UserDataDir: String = ""   // user-data 目录完整路径
    public init() {}
}

public final class BrowserProfileData: Codable {
    public var Exes: [BrowserExeEntry] = []
    public var Profiles: [BrowserProfileEntry] = []
    public init() {}
}
