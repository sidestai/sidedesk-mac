import Foundation

/// WebDAV 存储源（对应 C# WebDavSource）。
/// 注：C# 的 `[JsonIgnore] Password`（依赖 WebDavSourceService.Decrypt）未在此保留——
/// 解密接缝在 macOS 走 Keychain，属服务层（T3/T4）。
public struct WebDavSource: Codable {
    public var Id: String
    /// 显示名称
    public var Name: String = ""
    /// WebDAV 服务器地址
    public var Url: String = ""
    /// 用户名（匿名可留空）
    public var Username: String = ""
    /// 密码（加密后的 base64 密文）
    public var PasswordEncrypted: String = ""
    /// 归属团队 ID（空 = 个人）
    public var CorpId: String?
    /// 归属团队名称（仅展示用）
    public var CorpName: String?
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
        Username = c.or(.Username, "")
        PasswordEncrypted = c.or(.PasswordEncrypted, "")
        CorpId = c.opt(.CorpId)
        CorpName = c.opt(.CorpName)
        CreatedAt = c.or(.CreatedAt, Date())
    }

    /// 规范化根地址：保证以 / 结尾
    public var BaseUrl: String {
        let u = Url.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return "" }
        return u.hasSuffix("/") ? u : u + "/"
    }
}
