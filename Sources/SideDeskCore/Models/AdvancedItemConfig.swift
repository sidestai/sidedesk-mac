import Foundation

/// 高级项（扩展）动作配置：序列化为 JSON 存入 QuickItem.AdvancedConfigJson（对应 C# AdvancedItemConfig）。
/// ActionType 决定执行行为，各字段按类型取用；未涉及字段保持默认值。
public struct AdvancedItemConfig: Codable {
    /// 动作类型：url / exec / keys / paste / script / clipboard / search
    public var ActionType: String = "url"

    // ===== 通用 =====
    public var Description: String?
    public var Keywords: String?
    /// 全局热键（仅存储，暂不注册）
    public var Hotkey: String?

    // ===== url =====
    public var Url: String?
    /// ProgramRegistry 浏览器 Id（空=系统默认）
    public var BrowserId: String?
    /// 以 APP 模式打开（--app）
    public var UseAppMode: Bool = false
    /// 浏览器 Profile Id（可选）
    public var ProfileId: String?

    // ===== exec =====
    public var ProgramPath: String?
    public var LaunchArgs: String?
    public var WorkingDir: String?
    /// 启动方式：normal / admin / minimized / hidden
    public var LaunchMode: String = "normal"

    // ===== keys =====
    /// 按键序列，每项如 "Ctrl+Shift+P"
    public var KeySequences: [String] = []
    /// 每步间隔（毫秒）
    public var StepIntervalMs: Int = 50
    /// 触发后延迟（毫秒）
    public var TriggerDelayMs: Int = 100

    // ===== paste =====
    public var PasteText: String?
    /// 粘贴方式：ctrlv / type / clipboard
    public var PasteMode: String = "ctrlv"
    /// 完成后是否恢复原剪贴板
    public var RestoreClipboard: Bool = true

    // ===== script =====
    /// 脚本运行时：powershell / cmd（macOS 侧对应 shell，运行语义在服务层适配）
    public var ScriptRuntime: String = "powershell"
    public var ScriptCode: String?
    /// 输出处理：notify / paste / copy / none
    public var ScriptOutput: String = "notify"
    /// 脚本超时（秒）
    public var ScriptTimeoutSec: Int = 10

    // ===== clipboard =====
    public var ClipboardText: String?
    /// 完成后是否显示气泡通知
    public var ClipboardNotify: Bool = true

    // ===== search =====
    /// 搜索引擎模板，含 {query} 占位符
    public var SearchTemplate: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ActionType = c.or(.ActionType, "url")
        Description = c.opt(.Description)
        Keywords = c.opt(.Keywords)
        Hotkey = c.opt(.Hotkey)
        Url = c.opt(.Url)
        BrowserId = c.opt(.BrowserId)
        UseAppMode = c.or(.UseAppMode, false)
        ProfileId = c.opt(.ProfileId)
        ProgramPath = c.opt(.ProgramPath)
        LaunchArgs = c.opt(.LaunchArgs)
        WorkingDir = c.opt(.WorkingDir)
        LaunchMode = c.or(.LaunchMode, "normal")
        KeySequences = c.or(.KeySequences, [])
        StepIntervalMs = c.or(.StepIntervalMs, 50)
        TriggerDelayMs = c.or(.TriggerDelayMs, 100)
        PasteText = c.opt(.PasteText)
        PasteMode = c.or(.PasteMode, "ctrlv")
        RestoreClipboard = c.or(.RestoreClipboard, true)
        ScriptRuntime = c.or(.ScriptRuntime, "powershell")
        ScriptCode = c.opt(.ScriptCode)
        ScriptOutput = c.or(.ScriptOutput, "notify")
        ScriptTimeoutSec = c.or(.ScriptTimeoutSec, 10)
        ClipboardText = c.opt(.ClipboardText)
        ClipboardNotify = c.or(.ClipboardNotify, true)
        SearchTemplate = c.opt(.SearchTemplate)
    }

    /// 序列化为缩进 JSON（存储格式）
    public func toJson() -> String {
        guard let data = try? SideDeskJSON.encoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// 从 JSON 反序列化；失败返回 nil
    public static func tryParse(_ json: String?) -> AdvancedItemConfig? {
        guard let json = json,
              !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8) else { return nil }
        return try? SideDeskJSON.decoder().decode(AdvancedItemConfig.self, from: data)
    }
}
