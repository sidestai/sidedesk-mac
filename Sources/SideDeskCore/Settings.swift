import Foundation

/// 共享 JSON 编解码配置（对齐 Windows 端 System.Text.Json：ISO8601 日期、缩进）。
/// Swift Codable 默认把 Date 编成 Double（timeIntervalSinceReferenceDate），会与
/// Windows 的 settings.json / 云同步线格式不兼容，故统一走 ISO8601 策略。
public enum SideDeskJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    /// 解码策略：先试带小数秒的 ISO8601（C# "o" 格式 `2026-01-01T00:00:00.1234567Z`），
    /// 再试不带小数秒的（Swift 编码输出）。默认 `.iso8601` 只认后者，会把 C# 写的
    /// 日期解成 nil 并被 `c.or` 静默重置，故必须两种都认。
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = fractionalFormatter.date(from: raw) { return date }
            if let date = plainFormatter.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO8601 date: \(raw)")
        }
        return d
    }
}

/// 宽松解码辅助：缺键 / 类型不符时回落默认值（匹配 C# JsonSerializer 对缺失键填默认的行为，
/// 兼容老配置文件缺少新增键的情况）。
extension KeyedDecodingContainer {
    func or<T: Decodable>(_ key: Key, _ def: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? def
    }
    func opt<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

extension UUID {
    /// 对应 .NET `Guid.Empty`。
    public static let empty = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

/// 单个显示器的停靠配置（停靠模式 + 每侧宽度/浮动独立）。对应 C# `MonitorDockSettings`。
public final class MonitorDockSettings: Codable {
    public var Layout: LayoutMode = .none

    public var LeftPanelWidth: Int = 105
    public var LeftHoverEnabled: Bool = true
    public var LeftHoverWidth: Int = 200

    public var RightPanelWidth: Int = 105
    public var RightHoverEnabled: Bool = false
    public var RightHoverWidth: Int = 200

    public init() {}

    /// 深拷贝一份配置（供临时显示等场景使用，避免与持久化对象共享引用）。
    public func Clone() -> MonitorDockSettings {
        let c = MonitorDockSettings()
        c.Layout = Layout
        c.LeftPanelWidth = LeftPanelWidth
        c.LeftHoverEnabled = LeftHoverEnabled
        c.LeftHoverWidth = LeftHoverWidth
        c.RightPanelWidth = RightPanelWidth
        c.RightHoverEnabled = RightHoverEnabled
        c.RightHoverWidth = RightHoverWidth
        return c
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Layout = c.or(.Layout, LayoutMode.none)
        LeftPanelWidth = c.or(.LeftPanelWidth, 105)
        LeftHoverEnabled = c.or(.LeftHoverEnabled, true)
        LeftHoverWidth = c.or(.LeftHoverWidth, 200)
        RightPanelWidth = c.or(.RightPanelWidth, 105)
        RightHoverEnabled = c.or(.RightHoverEnabled, false)
        RightHoverWidth = c.or(.RightHoverWidth, 200)
    }
}

/// 单个虚拟桌面对应的全部显示器停靠配置。对应 C# `DesktopDockProfile`。
public final class DesktopDockProfile: Codable {
    public var DesktopId: UUID = .empty
    public var DesktopName: String = ""
    public var Monitors: [MonitorDockSettings] = []

    public init() {}

    /// 获取指定显示器的停靠配置，不存在时自动扩展列表并填默认值。
    public func GetMonitor(_ index: Int) -> MonitorDockSettings {
        var i = index
        if i < 0 { i = 0 }
        while Monitors.count <= i { Monitors.append(MonitorDockSettings()) }
        return Monitors[i]
    }

    /// 从另一个 profile 复制所有显示器配置。
    public func CopyFrom(_ source: DesktopDockProfile) {
        Monitors.removeAll()
        for m in source.Monitors { Monitors.append(m.Clone()) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        DesktopId = c.or(.DesktopId, UUID.empty)
        DesktopName = c.or(.DesktopName, "")
        Monitors = c.or(.Monitors, [])
    }
}

/// 应用主配置（对应 `%AppData%`/`Application Support` 下 app-settings.json）。对应 C# `Settings`。
///
/// 属性名保留 C# PascalCase（1:1 对照），Codable 默认键名即与之相同，线格式跨端一致。
public final class Settings: Codable {

    public var Layout: LayoutMode = .left
    /// 旧版单宽度配置（#441）：仅由 Load 一次性迁移回填 Left/RightPanelWidth；勿删（兼容锚点）。
    public var PanelWidth: Int = 105

    public var LeftPanelWidth: Int = 105
    public var LeftHoverEnabled: Bool = true
    public var LeftHoverWidth: Int = 200

    public var RightPanelWidth: Int = 105
    public var RightHoverEnabled: Bool = false
    public var RightHoverWidth: Int = 200

    public var ThemeMode: String = "Dark"        // "Dark" / "Light" / "System"
    public var Language: String = "auto"          // auto / zh-CN / en …
    public var BackgroundOpacity: Double = 50     // 0-100%

    public var ShowNotificationStrip: Bool = true
    public var EnableTitleLock: Bool = true
    public var TitleLockUserOptOut: Bool = false
    public var EnableAutoUpdate: Bool = true
    public var EnableWindowSwitchHotkey: Bool = false

    public var EnableVoiceInputHotkey: Bool = true
    public var VoiceStartHotkey: String = "Ctrl+B"
    public var VoiceStopHotkey: String = "Ctrl+B"
    public var VoiceEngine: String = "auto"       // auto / whisper / sapi（macOS 端映射到 SFSpeech）
    public var VoiceOutputMode: String = "paste"  // paste / inject（ADR-0014）
    public var VoiceInjectMaxRetract: Int = 12

    public var EnableMcpServer: Bool = false
    public var AIChatMode: String = "auto"        // auto / web / client
    public var AgentEngine: String = ""

    public var EnableHttpServer: Bool = true
    public var HttpServerPort: Int = 19195

    public var DataConnectionMode: String = "extension"   // extension / cdp
    public var DataConnectionModeChosen: Bool = false
    public var CdpDebugPort: Int = 9222
    public var HiddenBrowserMode: String = "headless"     // headless / hidden
    public var EnableAutoLaunchHiddenBrowser: Bool = true

    // ========== 账户 / 云同步 ==========
    public var AccountToken: String?
    public var AccountUserId: String?
    public var AccountName: String?
    public var AccountAvatar: String?
    public var AccountLoginTime: Date?
    public var HasLoggedInBefore: Bool = false
    public var EnableCloudSync: Bool = false
    public var CloudSyncUserOptOut: Bool = false
    public var SyncEncryptEnabled: Bool = false
    public var HttpLogEnabled: Bool = true
    public var LogLevel: String = "Info"
    public var KeyboardLogEnabled: Bool = true
    /// WPF GPU 硬件加速开关；macOS 端无意义，保留仅为跨端字段兼容（no-op）。
    public var ForceSoftwareRendering: Bool = false
    /// DPAPI 加密后的派生密钥（Windows）；macOS 端由 Keychain 接缝另行处理，字段保留兼容。
    public var SyncDerivedKey: String?
    public var LastSettingsSyncTime: Date?

    // ========== 百度网盘 ==========
    public var BaiduPanAccessToken: String?
    public var BaiduPanRefreshToken: String?
    public var BaiduPanTokenExpiry: Date?

    // ========== 团队（Corp）切换 ==========
    public var SelectedCorpId: String?
    public var SelectedCorpName: String?
    public var LastCloudSyncTime: Date?

    public var CloudIdMap: [String: String] = [:]
    public var DisabledPlugins: Set<String> = []
    public var DismissedNotices: [String: Date] = [:]
    public var ReadNotificationIds: [String] = []

    /// 判断指定 key 的通知是否应显示（从未记录过，或抑制周期已过期）。
    public func ShouldShowNotice(_ key: String, suppressPeriod: TimeInterval? = nil) -> Bool {
        guard let time = DismissedNotices[key] else { return true }
        guard let period = suppressPeriod else { return false }   // 无周期 = 永久不再显示
        return Date().timeIntervalSince(time) > period
    }

    /// 记录通知已关闭/已点击（配合 ShouldShowNotice 实现免打扰）。
    public func DismissNotice(_ key: String) {
        DismissedNotices[key] = Date()
    }

    public var Monitors: [MonitorDockSettings] = []

    // ========== 虚拟桌面独立配置 ==========
    public var EnablePerVirtualDesktop: Bool = false
    public var VirtualDesktops: [DesktopDockProfile] = []

    public init() {}

    /// 获取指定显示器的停靠配置，不存在时自动扩展列表并填默认值。
    public func GetMonitor(_ index: Int) -> MonitorDockSettings {
        var i = index
        if i < 0 { i = 0 }
        while Monitors.count <= i { Monitors.append(MonitorDockSettings()) }
        return Monitors[i]
    }

    /// 获取指定虚拟桌面的配置 profile，不存在时自动创建并从全局 Monitors 复制。
    public func GetDesktopProfile(_ desktopId: UUID, createIfMissing: Bool = true) -> DesktopDockProfile {
        if let profile = VirtualDesktops.first(where: { $0.DesktopId == desktopId }) { return profile }
        if !createIfMissing {
            let p = DesktopDockProfile(); p.DesktopId = desktopId; return p
        }
        let profile = DesktopDockProfile()
        profile.DesktopId = desktopId
        for m in Monitors { profile.Monitors.append(m.Clone()) }
        VirtualDesktops.append(profile)
        return profile
    }

    /// 获取当前虚拟桌面+指定显示器的停靠配置；未启用分桌面则退化为全局 GetMonitor()。
    public func GetCurrentMonitor(_ monitorIndex: Int, desktopId: UUID? = nil) -> MonitorDockSettings {
        guard EnablePerVirtualDesktop, let id = desktopId, id != .empty else {
            return GetMonitor(monitorIndex)
        }
        return GetDesktopProfile(id).GetMonitor(monitorIndex)
    }

    /// 获取指定虚拟桌面 profile 中的显示器配置（设置 UI 绑定指定桌面用）。
    public func GetMonitorForDesktop(_ desktopId: UUID, _ monitorIndex: Int) -> MonitorDockSettings {
        GetDesktopProfile(desktopId).GetMonitor(monitorIndex)
    }

    // MARK: - 持久化

    /// 测试缝隙：覆盖配置目录（集成测试隔离用；nil=真实路径）。
    public static var DirOverride: String?

    /// 配置目录：~/Library/Application Support/SideDesk（与 db、日志同目录）。
    private static var SettingsDir: String { DirOverride ?? AppPaths.dataDir }

    /// 主配置文件路径：{dir}/app-settings.json（区别于 Framework.AppSettings 的 settings.json）。
    private static var SettingsPath: String {
        (SettingsDir as NSString).appendingPathComponent("app-settings.json")
    }

    public func Save() {
        do {
            try FileManager.default.createDirectory(atPath: Settings.SettingsDir, withIntermediateDirectories: true)
            let data = try SideDeskJSON.encoder().encode(self)
            try data.write(to: URL(fileURLWithPath: Settings.SettingsPath), options: .atomic)
        } catch {
            RuntimeLog.debug("[Settings] save failed: \(error.localizedDescription)")
        }
    }

    public static func Load() -> Settings {
        do {
            let path = SettingsPath
            if FileManager.default.fileExists(atPath: path) {
                let raw = try String(contentsOfFile: path, encoding: .utf8)
                // 旧配置判定：仅有 PanelWidth、无 Left/RightPanelWidth 键
                let hasPerSideWidth = raw.contains("LeftPanelWidth")
                let settings = try SideDeskJSON.decoder().decode(Settings.self, from: Data(raw.utf8))
                // 一次性迁移：旧配置把 PanelWidth 回填到左右两侧宽度
                if !hasPerSideWidth {
                    settings.LeftPanelWidth = settings.PanelWidth
                    settings.RightPanelWidth = settings.PanelWidth
                }
                // 一次性迁移：旧配置无 Monitors 列表，把全局配置迁到主显示器（下标 0）
                if settings.Monitors.isEmpty {
                    let m = MonitorDockSettings()
                    m.Layout = settings.Layout
                    m.LeftPanelWidth = settings.LeftPanelWidth
                    m.LeftHoverEnabled = settings.LeftHoverEnabled
                    m.LeftHoverWidth = settings.LeftHoverWidth
                    m.RightPanelWidth = settings.RightPanelWidth
                    m.RightHoverEnabled = settings.RightHoverEnabled
                    m.RightHoverWidth = settings.RightHoverWidth
                    settings.Monitors = [m]
                }
                return settings
            }
        } catch {
            RuntimeLog.debug("[Settings] load failed: \(error.localizedDescription)")
        }
        return Settings()
    }

    // MARK: - Codable（宽松解码；encode 由编译器合成，键名 = 属性名 PascalCase）

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Layout = c.or(.Layout, LayoutMode.left)
        PanelWidth = c.or(.PanelWidth, 105)
        LeftPanelWidth = c.or(.LeftPanelWidth, 105)
        LeftHoverEnabled = c.or(.LeftHoverEnabled, true)
        LeftHoverWidth = c.or(.LeftHoverWidth, 200)
        RightPanelWidth = c.or(.RightPanelWidth, 105)
        RightHoverEnabled = c.or(.RightHoverEnabled, false)
        RightHoverWidth = c.or(.RightHoverWidth, 200)
        ThemeMode = c.or(.ThemeMode, "Dark")
        Language = c.or(.Language, "auto")
        BackgroundOpacity = c.or(.BackgroundOpacity, 50)
        ShowNotificationStrip = c.or(.ShowNotificationStrip, true)
        EnableTitleLock = c.or(.EnableTitleLock, true)
        TitleLockUserOptOut = c.or(.TitleLockUserOptOut, false)
        EnableAutoUpdate = c.or(.EnableAutoUpdate, true)
        EnableWindowSwitchHotkey = c.or(.EnableWindowSwitchHotkey, false)
        EnableVoiceInputHotkey = c.or(.EnableVoiceInputHotkey, true)
        VoiceStartHotkey = c.or(.VoiceStartHotkey, "Ctrl+B")
        VoiceStopHotkey = c.or(.VoiceStopHotkey, "Ctrl+B")
        VoiceEngine = c.or(.VoiceEngine, "auto")
        VoiceOutputMode = c.or(.VoiceOutputMode, "paste")
        VoiceInjectMaxRetract = c.or(.VoiceInjectMaxRetract, 12)
        EnableMcpServer = c.or(.EnableMcpServer, false)
        AIChatMode = c.or(.AIChatMode, "auto")
        AgentEngine = c.or(.AgentEngine, "")
        EnableHttpServer = c.or(.EnableHttpServer, true)
        HttpServerPort = c.or(.HttpServerPort, 19195)
        DataConnectionMode = c.or(.DataConnectionMode, "extension")
        DataConnectionModeChosen = c.or(.DataConnectionModeChosen, false)
        CdpDebugPort = c.or(.CdpDebugPort, 9222)
        HiddenBrowserMode = c.or(.HiddenBrowserMode, "headless")
        EnableAutoLaunchHiddenBrowser = c.or(.EnableAutoLaunchHiddenBrowser, true)
        AccountToken = c.opt(.AccountToken)
        AccountUserId = c.opt(.AccountUserId)
        AccountName = c.opt(.AccountName)
        AccountAvatar = c.opt(.AccountAvatar)
        AccountLoginTime = c.opt(.AccountLoginTime)
        HasLoggedInBefore = c.or(.HasLoggedInBefore, false)
        EnableCloudSync = c.or(.EnableCloudSync, false)
        CloudSyncUserOptOut = c.or(.CloudSyncUserOptOut, false)
        SyncEncryptEnabled = c.or(.SyncEncryptEnabled, false)
        HttpLogEnabled = c.or(.HttpLogEnabled, true)
        LogLevel = c.or(.LogLevel, "Info")
        KeyboardLogEnabled = c.or(.KeyboardLogEnabled, true)
        ForceSoftwareRendering = c.or(.ForceSoftwareRendering, false)
        SyncDerivedKey = c.opt(.SyncDerivedKey)
        LastSettingsSyncTime = c.opt(.LastSettingsSyncTime)
        BaiduPanAccessToken = c.opt(.BaiduPanAccessToken)
        BaiduPanRefreshToken = c.opt(.BaiduPanRefreshToken)
        BaiduPanTokenExpiry = c.opt(.BaiduPanTokenExpiry)
        SelectedCorpId = c.opt(.SelectedCorpId)
        SelectedCorpName = c.opt(.SelectedCorpName)
        LastCloudSyncTime = c.opt(.LastCloudSyncTime)
        CloudIdMap = c.or(.CloudIdMap, [:])
        DisabledPlugins = c.or(.DisabledPlugins, [])
        DismissedNotices = c.or(.DismissedNotices, [:])
        ReadNotificationIds = c.or(.ReadNotificationIds, [])
        Monitors = c.or(.Monitors, [])
        EnablePerVirtualDesktop = c.or(.EnablePerVirtualDesktop, false)
        VirtualDesktops = c.or(.VirtualDesktops, [])
    }
}
