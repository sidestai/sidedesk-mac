import Foundation

/// 云空间条目：用户配置的网盘/云存储快捷入口（对应 C# CloudSpace）
public struct CloudSpace: Codable {
    /// 内置「微屏云盘」的固定 Id：内置空间必须跨安装/迁移保持同一 Id
    public static let BuiltinSideDeskId = "builtin-sidedesk-cloud"

    public var Id: String
    /// 显示名称
    public var Name: String = ""
    /// 访问地址
    public var Url: String = ""
    /// 图标（emoji 或图标路径）
    public var Icon: String = "☁️"
    /// 备注说明
    public var Note: String?
    /// 关联的存储源 ID（如 S3Source.Id）
    public var RefId: String?
    /// 关联存储源类型（"s3" / "webdav"）
    public var RefType: String?
    /// 是否为系统内置预设
    public var IsBuiltin: Bool = false
    public var CreatedAt: Date

    public init() {
        Id = newGuidId()
        CreatedAt = Date()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, newGuidId())
        Name = c.or(.Name, "")
        Url = c.or(.Url, "")
        Icon = c.or(.Icon, "☁️")
        Note = c.opt(.Note)
        RefId = c.opt(.RefId)
        RefType = c.opt(.RefType)
        IsBuiltin = c.or(.IsBuiltin, false)
        CreatedAt = c.or(.CreatedAt, Date())
    }
}
