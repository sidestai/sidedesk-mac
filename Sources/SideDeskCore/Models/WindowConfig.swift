import Foundation

/// 卡片（面板）类型：与 `PanelItem.Type` 一一对应，序列化为整数存进 windows.json。
/// **新增成员只能追加在末尾**（持久化为整数）。对应 C# `Models.PanelType`。
public enum PanelType: Int, Codable, CaseIterable {
    case QuickGroup = 0
    case StickyNotes = 1
    case Clipboard = 2
    case SystemMonitor = 3
    case UsageStats = 4
    case AIChat = 5
    case FileArea = 6
    case ClipboardHistory = 7
    case DataDashboard = 8
    case Timer = 9
    case Group = 10
    case TodoList = 11
    case SignalLight = 12
    case DigitalEmployee = 13
    case Friend = 14
    case ImageCarousel = 15
    case DailyActivity = 16
    case Calendar = 17
    case Plugin = 18
    case ScreenTime = 19
    case Countdown = 20
    case Pomodoro = 21
    case WebBaidu = 22
    case CheckIn = 23
    case Dsh = 24          // 已弃用（迁至外部插件）：保留占位以免挪动后续枚值
    case Notes = 25
    case ModuleUi = 26
}

public enum WindowType: Int, Codable {
    case Native = 0
    case WebView = 1
}

/// 面板（卡片）。对应 C# `Models.PanelItem`（主文件 + DeskNote + ModuleUi 两个分部合并）。
public final class PanelItem: Codable {
    public var Id: String = UUID().uuidString
    public var ServerId: String?           // 云同步服务器端 ID（nil=尚未同步）
    public var `Type`: PanelType = .QuickGroup
    public var GroupId: String?            // 仅 QuickGroup 类型使用
    public var Title: String?              // 可选自定义标题
    public var ClipboardItems: [ClipboardSavedItem]?
    public var FileItems: [FileAreaItem]?
    public var DashboardItems: [DataDashboardItem]?
    public var TimerItems: [TimerItem]?
    public var CountdownItems: [CountdownItem]?
    public var ChildPanels: [PanelItem]?
    public var IsExpanded: Bool = true
    public var GroupBGColor: String?
    public var BGColor: String?
    public var StickyNotes: [StickyNote]?
    public var TodoItems: [TodoItem]?
    public var SkipWrapper: Bool = false
    public var HideFrame: Bool = false
    public var IsPinned: Bool = false
    public var DashboardColumns: Int = 1
    public var SignalLights: [SignalLightItem]?
    public var SignalLightVertical: Bool = false
    public var SignalLightSpacing: Double = 5
    public var SignalLightAlignment: String = "Center"
    public var FileAreaLayout: String = "List"
    public var FileAreaColumns: Int = 1
    public var PanelHeight: Double?
    public var DigitalEmployeeIds: [String]?
    public var DigitalEmployeeColumns: Int = 3
    public var FriendName: String?
    public var FriendAvatarPath: String?
    public var FriendEmoji: String?
    public var FriendStatusText: String?
    public var FriendOnlineStatus: String = "online"
    public var FriendDisplayMode: String = "HorizontalSmall"
    public var FriendUserIds: [String]?
    public var CarouselFolder: String?
    public var CarouselIntervalSeconds: Int = 5
    public var CarouselRandom: Bool = false
    public var CarouselIncludeSubfolders: Bool = false
    public var CarouselStretch: String = "Uniform"
    public var CarouselHeight: Double = 140
    public var CarouselAutoPlay: Bool = true
    public var PluginId: String?
    // ===== 快捷方式卡片 =====
    public var QuickItems: [QuickItem]?
    public var QuickGroupName: String = "快捷方式"
    public var QuickColumns: Int = 1
    public var QuickDisplayMode: String = "grid"
    public var QuickHideFrame: Bool = false
    public var QuickOrder: Int = 0
    public var ScreenTimeStyle: String = "List"
    public var DailyActivityView: String = "Month"
    public var DailyActivityType: String = "screen"
    public var Pomodoro: PomodoroSettings?
    public var CheckInItems: [CheckInItem]?
    public var CheckInColumns: Int = 2
    public var CheckInStyle: String = "IconTextVertical"
    public var OwnerType: String = "personal"
    public var TeamId: String?
    public var TeamName: String?
    public var ShareId: String?
    public var ShareCode: String?
    public var ShareMode: String?
    public var AllowEdit: Bool = true
    public var AllowDelete: Bool = true
    public var AllowReShare: Bool = false
    // ===== 分部：DeskNote =====
    public var DeskNotes: [DeskNote]?
    // ===== 分部：ModuleUi =====
    public var ModuleId: String?

    /// 引用分享且不允许编辑 → 内容只读。对应 C# `[JsonIgnore] IsShareReadOnly`。
    public var IsShareReadOnly: Bool { ShareMode == "reference" && !AllowEdit }
    /// 引用分享且不允许删除 → 禁止删除卡片/行。
    public var IsShareDeleteBlocked: Bool { ShareMode == "reference" && !AllowDelete }

    /// 从另一实例复制模块级设置（云同步 itemData 应用用）。对应 C# `ApplyItemDataToPanel`
    /// 的反射赋值口径：身份元数据（Id/ServerId/Type/ChildPanels）与 14 类行列表不复制——
    /// 前者以本地为准，后者由行级同步单独管理；归属（OwnerType/TeamId/TeamName）随
    /// itemData 上传也随其应用，属于模块设置。
    /// 返回是否有字段实际变化（决定是否刷新 UI）。
    @discardableResult
    public func copyModuleSettings(from o: PanelItem) -> Bool {
        var changed = false
        func cp<T: Equatable>(_ kp: ReferenceWritableKeyPath<PanelItem, T>, _ v: T) {
            if self[keyPath: kp] != v { self[keyPath: kp] = v; changed = true }
        }
        cp(\.OwnerType, o.OwnerType)
        cp(\.TeamId, o.TeamId)
        cp(\.TeamName, o.TeamName)
        cp(\.GroupId, o.GroupId)
        cp(\.Title, o.Title)
        cp(\.IsExpanded, o.IsExpanded)
        cp(\.GroupBGColor, o.GroupBGColor)
        cp(\.BGColor, o.BGColor)
        cp(\.SkipWrapper, o.SkipWrapper)
        cp(\.HideFrame, o.HideFrame)
        cp(\.IsPinned, o.IsPinned)
        cp(\.DashboardColumns, o.DashboardColumns)
        cp(\.SignalLightVertical, o.SignalLightVertical)
        cp(\.SignalLightSpacing, o.SignalLightSpacing)
        cp(\.SignalLightAlignment, o.SignalLightAlignment)
        cp(\.FileAreaLayout, o.FileAreaLayout)
        cp(\.FileAreaColumns, o.FileAreaColumns)
        cp(\.PanelHeight, o.PanelHeight)
        cp(\.DigitalEmployeeColumns, o.DigitalEmployeeColumns)
        cp(\.FriendName, o.FriendName)
        cp(\.FriendAvatarPath, o.FriendAvatarPath)
        cp(\.FriendEmoji, o.FriendEmoji)
        cp(\.FriendStatusText, o.FriendStatusText)
        cp(\.FriendOnlineStatus, o.FriendOnlineStatus)
        cp(\.FriendDisplayMode, o.FriendDisplayMode)
        cp(\.CarouselFolder, o.CarouselFolder)
        cp(\.CarouselIntervalSeconds, o.CarouselIntervalSeconds)
        cp(\.CarouselRandom, o.CarouselRandom)
        cp(\.CarouselIncludeSubfolders, o.CarouselIncludeSubfolders)
        cp(\.CarouselStretch, o.CarouselStretch)
        cp(\.CarouselHeight, o.CarouselHeight)
        cp(\.CarouselAutoPlay, o.CarouselAutoPlay)
        cp(\.PluginId, o.PluginId)
        cp(\.QuickGroupName, o.QuickGroupName)
        cp(\.QuickColumns, o.QuickColumns)
        cp(\.QuickDisplayMode, o.QuickDisplayMode)
        cp(\.QuickHideFrame, o.QuickHideFrame)
        cp(\.QuickOrder, o.QuickOrder)
        cp(\.ScreenTimeStyle, o.ScreenTimeStyle)
        cp(\.DailyActivityView, o.DailyActivityView)
        cp(\.DailyActivityType, o.DailyActivityType)
        cp(\.CheckInColumns, o.CheckInColumns)
        cp(\.CheckInStyle, o.CheckInStyle)
        cp(\.ShareId, o.ShareId)
        cp(\.ShareCode, o.ShareCode)
        cp(\.ShareMode, o.ShareMode)
        cp(\.AllowEdit, o.AllowEdit)
        cp(\.AllowDelete, o.AllowDelete)
        cp(\.AllowReShare, o.AllowReShare)
        cp(\.ModuleId, o.ModuleId)
        return changed
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, UUID().uuidString)
        ServerId = c.opt(.ServerId)
        `Type` = c.or(.`Type`, PanelType.QuickGroup)
        GroupId = c.opt(.GroupId)
        Title = c.opt(.Title)
        ClipboardItems = c.opt(.ClipboardItems)
        FileItems = c.opt(.FileItems)
        DashboardItems = c.opt(.DashboardItems)
        TimerItems = c.opt(.TimerItems)
        CountdownItems = c.opt(.CountdownItems)
        ChildPanels = c.opt(.ChildPanels)
        IsExpanded = c.or(.IsExpanded, true)
        GroupBGColor = c.opt(.GroupBGColor)
        BGColor = c.opt(.BGColor)
        StickyNotes = c.opt(.StickyNotes)
        TodoItems = c.opt(.TodoItems)
        SkipWrapper = c.or(.SkipWrapper, false)
        HideFrame = c.or(.HideFrame, false)
        IsPinned = c.or(.IsPinned, false)
        DashboardColumns = c.or(.DashboardColumns, 1)
        SignalLights = c.opt(.SignalLights)
        SignalLightVertical = c.or(.SignalLightVertical, false)
        SignalLightSpacing = c.or(.SignalLightSpacing, 5)
        SignalLightAlignment = c.or(.SignalLightAlignment, "Center")
        FileAreaLayout = c.or(.FileAreaLayout, "List")
        FileAreaColumns = c.or(.FileAreaColumns, 1)
        PanelHeight = c.opt(.PanelHeight)
        DigitalEmployeeIds = c.opt(.DigitalEmployeeIds)
        DigitalEmployeeColumns = c.or(.DigitalEmployeeColumns, 3)
        FriendName = c.opt(.FriendName)
        FriendAvatarPath = c.opt(.FriendAvatarPath)
        FriendEmoji = c.opt(.FriendEmoji)
        FriendStatusText = c.opt(.FriendStatusText)
        FriendOnlineStatus = c.or(.FriendOnlineStatus, "online")
        FriendDisplayMode = c.or(.FriendDisplayMode, "HorizontalSmall")
        FriendUserIds = c.opt(.FriendUserIds)
        CarouselFolder = c.opt(.CarouselFolder)
        CarouselIntervalSeconds = c.or(.CarouselIntervalSeconds, 5)
        CarouselRandom = c.or(.CarouselRandom, false)
        CarouselIncludeSubfolders = c.or(.CarouselIncludeSubfolders, false)
        CarouselStretch = c.or(.CarouselStretch, "Uniform")
        CarouselHeight = c.or(.CarouselHeight, 140)
        CarouselAutoPlay = c.or(.CarouselAutoPlay, true)
        PluginId = c.opt(.PluginId)
        QuickItems = c.opt(.QuickItems)
        QuickGroupName = c.or(.QuickGroupName, "快捷方式")
        QuickColumns = c.or(.QuickColumns, 1)
        QuickDisplayMode = c.or(.QuickDisplayMode, "grid")
        QuickHideFrame = c.or(.QuickHideFrame, false)
        QuickOrder = c.or(.QuickOrder, 0)
        ScreenTimeStyle = c.or(.ScreenTimeStyle, "List")
        DailyActivityView = c.or(.DailyActivityView, "Month")
        DailyActivityType = c.or(.DailyActivityType, "screen")
        Pomodoro = c.opt(.Pomodoro)
        CheckInItems = c.opt(.CheckInItems)
        CheckInColumns = c.or(.CheckInColumns, 2)
        CheckInStyle = c.or(.CheckInStyle, "IconTextVertical")
        OwnerType = c.or(.OwnerType, "personal")
        TeamId = c.opt(.TeamId)
        TeamName = c.opt(.TeamName)
        ShareId = c.opt(.ShareId)
        ShareCode = c.opt(.ShareCode)
        ShareMode = c.opt(.ShareMode)
        AllowEdit = c.or(.AllowEdit, true)
        AllowDelete = c.or(.AllowDelete, true)
        AllowReShare = c.or(.AllowReShare, false)
        DeskNotes = c.opt(.DeskNotes)
        ModuleId = c.opt(.ModuleId)
    }
}

/// 数字员工卡片行包装：行级存储/同步用。对应 C# `DigitalEmployeeRow`。
public final class DigitalEmployeeRow: Codable {
    public var Id: String = ""           // = EmployeeId
    public var EmployeeId: String = ""
    public init() {}
}

/// 好友卡片行包装：行级存储/同步用。对应 C# `FriendUserRow`。
public final class FriendUserRow: Codable {
    public var Id: String = ""           // = UserId
    public var UserId: String = ""
    public init() {}
}

public final class FileAreaItem: Codable {
    public var Id: String = UUID().uuidString
    public var Path: String = ""
    public var Name: String = ""
    /// 用户自定义别名：非空时优先于 Name 显示。
    public var Alias: String?
    public var IsFolder: Bool = false
    public var AddedAt: Date = Date()
    // ===== 云文件相关（IsCloudFile=true 时有效）=====
    public var IsCloudFile: Bool = false
    public var CloudSpaceId: String?
    public var CloudSpaceName: String?
    public var CloudSpaceIcon: String?
    public var CloudFileId: String?
    public var CloudUrl: String?
    public init() {}
}

public final class ClipboardSavedItem: Codable {
    public var Id: String = UUID().uuidString
    public var Content: String = ""
    public var ContentType: String = "Text"   // Text / Image / File
    public var SavedAt: Date = Date()
    public init() {}
}

/// 计时器项。对应 C# `TimerItem`（`TimeSpan ElapsedTime` → `TimeInterval` 秒）。
public final class TimerItem: Codable {
    public var Id: String = UUID().uuidString
    public var Name: String = "新计时"
    public var TimeoutSeconds: Int = 3600
    public var IsRunning: Bool = false
    public var StartTime: Date?
    /// 已累计时长（秒）。对应 C# `TimeSpan ElapsedTime`。
    public var ElapsedTime: TimeInterval = 0
    /// 计时结束时把本次时段写入每日活跃。
    public var StoreToDailyActivity: Bool = false
    /// 历史记录：日期 -> 总秒数。
    public var DailyRecords: [String: Int] = [:]

    public init() {}

    /// 总经过时间（秒，含当前运行时段）。
    public func GetElapsed() -> TimeInterval {
        if IsRunning, let start = StartTime {
            return ElapsedTime + Date().timeIntervalSince(start)
        }
        return ElapsedTime
    }
}

/// 倒计时项。对应 C# `CountdownItem`。
public final class CountdownItem: Codable {
    public var Id: String = UUID().uuidString
    public var Name: String = "新倒计时"
    public var TotalSeconds: Int = 3600
    public var RemainingSeconds: Double = 3600
    public var IsRunning: Bool = false
    public var StartTime: Date?
    public var IsFinished: Bool = false
    public var RemindFlash: Bool = true
    public var RemindPopup: Bool = true
    public var RemindAction: String = "None"   // None / Hibernate / Shutdown
    public init() {}

    /// 当前剩余时间（秒，含运行中实时计算）。
    public func GetRemaining() -> TimeInterval {
        if IsRunning, let start = StartTime {
            let remaining = RemainingSeconds - Date().timeIntervalSince(start)
            return max(0, remaining)
        }
        return max(0, RemainingSeconds)
    }
}

/// 今日待办项。对应 C# `TodoItem`。
public final class TodoItem: Codable {
    public var Id: String = UUID().uuidString
    public var Text: String = ""
    public var Description: String = ""
    public var IsDone: Bool = false
    public var CreatedAt: Date = Date()
    public var DueTime: Date?
    public var RemindBeforeMinutes: Int = -1   // -1=不提醒，0=准时
    public var Reminded: Bool = false
    public init() {}
}

/// 信号灯状态条件。对应 C# `SignalLightCondition`。
public final class SignalLightCondition: Codable {
    public var VarKey: String = ""
    public var Op: String = "EQ"       // EQ / GT / LT / MISSING
    public var Value: String = ""
    public init() {}
}

/// 信号灯项。对应 C# `SignalLightItem`。
public final class SignalLightItem: Codable {
    public var Id: String = UUID().uuidString
    public var Color: String = "#FF4444"
    public var Size: Double = 36
    public var Icon: String?
    public var IsOn: Bool = true
    public var LightStyle: String = "Circle"   // Circle / Square / Pixel
    public var OnConditions: [SignalLightCondition] = []
    public var OffConditions: [SignalLightCondition] = []
    public var BlinkConditions: [SignalLightCondition] = []
    public var OnConditionMode: String = "OR"
    public var OffConditionMode: String = "OR"
    public var BlinkConditionMode: String = "OR"
    public var BlinkIntervalSeconds: Double = 1
    public init() {}
}

/// 番茄闹钟设置与运行状态。对应 C# `PomodoroSettings`（TimeSpan → TimeInterval 秒）。
public final class PomodoroSettings: Codable {
    public var Id: String = UUID().uuidString
    public var WorkMinutes: Int = 25
    public var ShortBreakMinutes: Int = 5
    public var LongBreakMinutes: Int = 15
    public var LongBreakInterval: Int = 4
    public var AutoStartNext: Bool = false
    public var RemindFlash: Bool = true
    public var RemindPopup: Bool = true
    public var Mode: String = "Work"           // Work / ShortBreak / LongBreak
    public var RemainingSeconds: Double = 25 * 60
    public var IsRunning: Bool = false
    public var StartTime: Date?
    public var CompletedCount: Int = 0
    public var CompletedDate: String?          // yyyy-MM-dd
    public init() {}

    /// 当前模式的总时长（秒）。
    public func GetModeTotalSeconds() -> Int {
        switch Mode {
        case "ShortBreak": return ShortBreakMinutes * 60
        case "LongBreak":  return LongBreakMinutes * 60
        default:           return WorkMinutes * 60
        }
    }

    /// 当前剩余时间（秒，含运行中实时计算）。
    public func GetRemaining() -> TimeInterval {
        if IsRunning, let start = StartTime {
            let remaining = RemainingSeconds - Date().timeIntervalSince(start)
            return max(0, remaining)
        }
        return max(0, RemainingSeconds)
    }

    /// 确保计数为当天（跨天清零）。
    public func EnsureTodayCount() {
        let today = todayKey()
        if CompletedDate != today {
            CompletedDate = today
            CompletedCount = 0
        }
    }
}

/// 打卡项。对应 C# `CheckInItem`。
public final class CheckInItem: Codable {
    public var Id: String = UUID().uuidString
    public var Text: String = ""
    public var Icon: String = ""
    public var Color: String = "#4A90D9"
    public var Count: Int = 0
    public var CountDate: String?          // yyyy-MM-dd
    public var SortIndex: Int = 0
    public init() {}

    /// 确保计数为当天（跨天清零）。
    public func EnsureTodayCount() {
        let today = todayKey()
        if CountDate != today {
            CountDate = today
            Count = 0
        }
    }

    /// 当日打卡次数（跨天未点击返回 0，不改动持久值）。
    public func TodayCount() -> Int {
        CountDate == todayKey() ? Count : 0
    }
}

/// 侧栏窗口（bar）配置。对应 C# `WindowConfig`。
public final class WindowConfig: Codable {
    public var Id: String = UUID().uuidString
    public var ServerId: String?
    public var Name: String = "新窗口"
    public var BGColor: String?
    public var `Type`: WindowType = .Native
    public var Url: String?
    public var CreatedAt: Date = Date()
    public var Panels: [PanelItem] = []
    public var IsEditMode: Bool = false
    public var IsAppMode: Bool = false
    /// 窗口级启用的工具列表（底部工具栏）。默认含 AIChat（#511）。
    public var EnabledTools: [String] = ["AIChat"]
    public var KeyMouseRecorderEnabled: Bool = false
    public var ShowInTabs: Bool = true
    public var OwnerType: String = "personal"
    public var CorpId: String?
    public var ShareMode: String?
    public var SourceBarId: String?
    public var ShareId: String?
    public var ShareCode: String?
    public var AllowEdit: Bool = true
    public var AllowDelete: Bool = true
    public var AllowReShare: Bool = false

    public var IsShareReadOnly: Bool { ShareMode == "reference" && !AllowEdit }
    public var IsShareDeleteBlocked: Bool { ShareMode == "reference" && !AllowDelete }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, UUID().uuidString)
        ServerId = c.opt(.ServerId)
        Name = c.or(.Name, "新窗口")
        BGColor = c.opt(.BGColor)
        `Type` = c.or(.`Type`, WindowType.Native)
        Url = c.opt(.Url)
        CreatedAt = c.or(.CreatedAt, Date())
        Panels = c.or(.Panels, [])
        IsEditMode = c.or(.IsEditMode, false)
        IsAppMode = c.or(.IsAppMode, false)
        EnabledTools = c.or(.EnabledTools, ["AIChat"])
        KeyMouseRecorderEnabled = c.or(.KeyMouseRecorderEnabled, false)
        ShowInTabs = c.or(.ShowInTabs, true)
        OwnerType = c.or(.OwnerType, "personal")
        CorpId = c.opt(.CorpId)
        ShareMode = c.opt(.ShareMode)
        SourceBarId = c.opt(.SourceBarId)
        ShareId = c.opt(.ShareId)
        ShareCode = c.opt(.ShareCode)
        AllowEdit = c.or(.AllowEdit, true)
        AllowDelete = c.or(.AllowDelete, true)
        AllowReShare = c.or(.AllowReShare, false)
    }
}

/// 停靠窗口状态。对应 C# `DockWindowState`。
public final class DockWindowState: Codable {
    public var WindowIds: [String] = []
    public var ActiveIndex: Int = 0
    public init() {}
}

// MARK: - TimerItem 行为扩展（#340 契约统一）

extension TimerItem {
    /// 计时结束累计到当日记录。对应 C# `TimerItemExtensions.AccumulateToDailyRecord`。
    public func AccumulateToDailyRecord() {
        let today = todayKey()
        let secondsToAdd = Int(GetElapsed())
        DailyRecords[today, default: 0] += secondsToAdd
    }
}

// MARK: - 共享日期工具

/// yyyy-MM-dd 当天键（en_US_POSIX，避免本地历法/纪元偏差）。
private let _dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    return f
}()

func todayKey() -> String { _dayFormatter.string(from: Date()) }
