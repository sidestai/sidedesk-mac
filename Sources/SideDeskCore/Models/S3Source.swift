import Foundation

/// S3 存储源：用户配置的 Amazon S3（或 S3 兼容协议）桶（对应 C# S3Source）。
/// 注：C# 的 `[JsonIgnore] SecretAccessKey/SessionToken`（依赖 S3SourceService.Decrypt，
/// Windows DPAPI）未在此保留——解密接缝在 macOS 走 Keychain，属服务层（T3/T4）。
public struct S3Source: Codable {
    public var Id: String
    /// 显示名称
    public var Name: String = ""
    /// 服务端点（空 = AWS 官方端点）
    public var Endpoint: String = ""
    /// 区域（AWS 默认 us-east-1）
    public var Region: String = "us-east-1"
    /// 桶名
    public var Bucket: String = ""
    public var AccessKeyId: String = ""
    /// SecretAccessKey（加密后的 base64 密文）
    public var SecretKeyEncrypted: String = ""
    /// 可选 STS 会话令牌（加密后的 base64 密文）
    public var SessionTokenEncrypted: String?
    /// 路径风格寻址（部分自定义端点需要）
    public var UsePathStyle: Bool = false
    /// 存储根前缀（不以 / 开头、以 / 结尾）
    public var Prefix: String = ""
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
        Endpoint = c.or(.Endpoint, "")
        Region = c.or(.Region, "us-east-1")
        Bucket = c.or(.Bucket, "")
        AccessKeyId = c.or(.AccessKeyId, "")
        SecretKeyEncrypted = c.or(.SecretKeyEncrypted, "")
        SessionTokenEncrypted = c.opt(.SessionTokenEncrypted)
        UsePathStyle = c.or(.UsePathStyle, false)
        Prefix = c.or(.Prefix, "")
        CorpId = c.opt(.CorpId)
        CorpName = c.opt(.CorpName)
        CreatedAt = c.or(.CreatedAt, Date())
    }

    /// 规范化前缀：去首斜杠，非空时保证以 / 结尾
    public var NormalizedPrefix: String {
        var p = Prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasPrefix("/") { p.removeFirst() }
        if p.isEmpty { return "" }
        return p.hasSuffix("/") ? p : p + "/"
    }
}
