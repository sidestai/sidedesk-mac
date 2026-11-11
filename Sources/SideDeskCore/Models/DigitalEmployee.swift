import Foundation

/// 数字员工（对应 C# DigitalEmployee）。
/// 注：DigitalEmployeeManager 依赖 Services.LocalDbService（SQLite KV 主存储 + JSON 迁移），
/// 属服务层，推迟到 T3 移植。
public struct DigitalEmployee: Codable {
    public var Id: String
    public var Name: String = "新员工"
    /// 头像图片文件路径（为空则用首字母/emoji 占位）
    public var AvatarPath: String = ""
    /// 无图片时可用 emoji 作为头像
    public var Emoji: String = ""
    /// 职位/角色
    public var Role: String = ""
    /// 部门
    public var Department: String = ""
    /// 简介/职责描述
    public var Description: String = ""
    /// 擅长/技能
    public var Skills: String = ""
    /// 联系方式（邮箱/工号等）
    public var Contact: String = ""
    /// 状态：online / busy / offline
    public var Status: String = "online"
    public var CreatedAt: Date

    public init() {
        Id = UUID().uuidString
        CreatedAt = Date()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, UUID().uuidString)
        Name = c.or(.Name, "新员工")
        AvatarPath = c.or(.AvatarPath, "")
        Emoji = c.or(.Emoji, "")
        Role = c.or(.Role, "")
        Department = c.or(.Department, "")
        Description = c.or(.Description, "")
        Skills = c.or(.Skills, "")
        Contact = c.or(.Contact, "")
        Status = c.or(.Status, "online")
        CreatedAt = c.or(.CreatedAt, Date())
    }

    /// 头像占位显示文字：优先 emoji，否则名字首字符
    public var AvatarFallback: String {
        let e = Emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e }
        let n = Name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "?" }
        return String(n.prefix(1))
    }

    /// 状态显示文本
    public var StatusText: String {
        switch Status {
        case "online": return Lang.t("common.online")
        case "busy": return Lang.t("digitalEmployee.busy")
        case "offline": return Lang.t("common.offline")
        default: return Lang.t("common.online")
        }
    }
}
