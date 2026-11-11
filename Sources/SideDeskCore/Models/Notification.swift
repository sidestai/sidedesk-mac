import Foundation

/// 通知显示模式（对应 C# NotificationDisplayMode，整数序列化与 Newtonsoft 一致）
public enum NotificationDisplayMode: Int, Codable {
    /// 横幅：通知栏内显示卡片，超时自动消失
    case banner = 0
    /// 弹出：模态对话框，需用户操作
    case alert = 1
    /// 静默：仅进入通知中心
    case silent = 2
}

/// 通知优先级（越高越先显示）
public enum NotificationPriority: Int, Codable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3
}

/// 通知动作类型
public enum NotificationActionType: Int, Codable {
    case openUrl = 0
    case openWebView = 1
    case openSettings = 2
    case openFile = 3
    case showFileLocation = 4
    case showMessagebox = 5
    case runCommand = 6
    case snooze = 7
    case inputReply = 8
    case dismiss = 9
    case teamApplyHandle = 10
    case installAgentCli = 11
    case cancelJob = 12
    case unknown = 13

    /// 从字符串解析（镜像 C# ParseActionType）
    public static func parse(_ type: String?) -> NotificationActionType {
        switch type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "open_url": return .openUrl
        case "open_webview": return .openWebView
        case "open_settings": return .openSettings
        case "open_file": return .openFile
        case "show_file_location": return .showFileLocation
        case "show_messagebox": return .showMessagebox
        case "run_command": return .runCommand
        case "snooze", "remind_later": return .snooze
        case "input_reply": return .inputReply
        case "dismiss": return .dismiss
        case "team_apply_handle": return .teamApplyHandle
        case "install_agent_cli": return .installAgentCli
        case "cancel_job": return .cancelJob
        default: return .unknown
        }
    }
}

/// 通知动作定义：type + label + payload（对应 C# NotificationAction）。
/// C# 的 Dictionary<string, object> payload 用 [String: JSONValue] 承载以支持 Codable 往返。
public struct NotificationAction: Codable {
    public var `Type`: String = ""
    public var Label: String?
    public var Payload: [String: JSONValue]?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        `Type` = c.or(.Type, "")
        Label = c.opt(.Label)
        Payload = c.opt(.Payload)
    }

    /// 解析后的动作类型枚举
    public var ActionType: NotificationActionType { NotificationActionType.parse(`Type`) }

    /// 从 JSONSerialization 字典解析单个动作
    public static func fromJson(_ dict: [String: Any]?) -> NotificationAction? {
        guard let dict = dict,
              let type = dict["type"] as? String,
              !type.isEmpty else { return nil }
        var a = NotificationAction()
        a.`Type` = type
        a.Label = dict["label"] as? String
        if let p = dict["payload"] as? [String: Any] {
            var payload: [String: JSONValue] = [:]
            for (k, v) in p { payload[k] = JSONValue(any: v) }
            a.Payload = payload
        }
        return a
    }

    public func payloadString(_ key: String, _ fallback: String = "") -> String {
        Payload?[key]?.stringValue ?? fallback
    }

    public func payloadNumber(_ key: String, _ fallback: Double = 0) -> Double {
        Payload?[key]?.doubleValue ?? fallback
    }

    public func payloadBool(_ key: String, _ fallback: Bool = false) -> Bool {
        Payload?[key]?.boolValue ?? fallback
    }
}

/// 通知载荷：对应后端 WebSocket 推送的 notification 事件 data 部分（对应 C# NotificationPayload）。
/// 服务端 JSON 字段用 snake_case，经 fromJson 映射；本地持久化用 PascalCase（Codable 合成）。
public struct NotificationPayload: Codable {
    /// 通知唯一 ID
    public var Id: String = newGuidId()
    /// 标题（粗体主文案）
    public var Title: String = ""
    /// 正文
    public var Body: String?
    /// 发送时间
    public var Timestamp: Date = Date()
    /// 多少秒后自动消失（0 为常驻）
    public var Timeout: Int = 8
    /// 是否允许关闭
    public var AllowClose: Bool = true
    /// 优先级
    public var Priority: NotificationPriority = .normal
    /// 分组 ID（同组只显示最新一条）
    public var GroupId: String?
    /// 背景颜色
    public var BackgroundColor: String?
    /// 文字颜色
    public var TextColor: String?
    /// 出现时是否播放声音
    public var Sound: Bool = false
    /// 进度值 0-100（nil 表示不显示进度条）
    public var Progress: Int?
    /// 显示模式
    public var DisplayMode: NotificationDisplayMode = .banner
    /// 通知中的大图（URL 或本地路径）
    public var LargeImage: String?
    /// 操作按钮列表
    public var Buttons: [NotificationAction]?
    /// 点击通知主体触发的默认行为
    public var ClickMain: NotificationAction?
    /// 是否已读
    public var IsRead: Bool = false
    /// 服务端通知行 ID（null 表示纯本地通知）
    public var ServerId: String?
    /// 通知免打扰标识
    public var NoticeKey: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, newGuidId())
        Title = c.or(.Title, "")
        Body = c.opt(.Body)
        Timestamp = c.or(.Timestamp, Date())
        Timeout = c.or(.Timeout, 8)
        AllowClose = c.or(.AllowClose, true)
        Priority = c.or(.Priority, .normal)
        GroupId = c.opt(.GroupId)
        BackgroundColor = c.opt(.BackgroundColor)
        TextColor = c.opt(.TextColor)
        Sound = c.or(.Sound, false)
        Progress = c.opt(.Progress)
        DisplayMode = c.or(.DisplayMode, .banner)
        LargeImage = c.opt(.LargeImage)
        Buttons = c.opt(.Buttons)
        ClickMain = c.opt(.ClickMain)
        IsRead = c.or(.IsRead, false)
        ServerId = c.opt(.ServerId)
        NoticeKey = c.opt(.NoticeKey)
    }

    /// 是否显示未读红点：未读且发送时间在 1 个月内
    public var ShowUnread: Bool {
        !IsRead && Date().timeIntervalSince(Timestamp) <= 30 * 24 * 3600
    }

    /// 从 WebSocket JSON data 字典解析通知载荷（snake_case 字段映射）
    public static func fromJson(_ data: [String: Any]) -> NotificationPayload {
        var n = NotificationPayload()
        n.Id = (data["id"] as? String) ?? newGuidId()
        n.Title = (data["title"] as? String) ?? ""
        n.Body = (data["body"] as? String) ?? (data["content"] as? String)

        // timestamp: 毫秒时间戳，不传则用当前时间
        if let ms = data["timestamp"] as? NSNumber {
            n.Timestamp = Date(timeIntervalSince1970: ms.doubleValue / 1000.0)
        }

        n.Timeout = (data["timeout"] as? NSNumber)?.intValue ?? 8
        n.AllowClose = (data["allow_close"] as? NSNumber)?.boolValue ?? true

        switch (data["priority"] as? String)?.lowercased() {
        case "low": n.Priority = .low
        case "high": n.Priority = .high
        case "critical": n.Priority = .critical
        default: n.Priority = .normal
        }

        let gid = data["group_id"] as? String
        n.GroupId = (gid?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? gid : nil

        n.BackgroundColor = data["background_color"] as? String
        n.TextColor = data["text_color"] as? String
        n.Sound = (data["sound"] as? NSNumber)?.boolValue ?? false
        n.Progress = (data["progress"] as? NSNumber)?.intValue

        switch (data["display_mode"] as? String)?.lowercased() {
        case "alert": n.DisplayMode = .alert
        case "silent": n.DisplayMode = .silent
        default: n.DisplayMode = .banner
        }

        n.LargeImage = data["large_image"] as? String

        if let btnArray = data["buttons"] as? [[String: Any]] {
            var buttons: [NotificationAction] = []
            for btn in btnArray {
                if let a = NotificationAction.fromJson(btn) { buttons.append(a) }
            }
            n.Buttons = buttons.isEmpty ? nil : buttons
        }

        let clickMain = (data["click_main"] as? [String: Any]) ?? (data["clickMain"] as? [String: Any])
        n.ClickMain = NotificationAction.fromJson(clickMain)

        n.NoticeKey = data["notice_key"] as? String

        return n
    }
}
