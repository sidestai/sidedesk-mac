import Foundation

/// 标题匹配模式（当 MatchPattern 非空时生效）。对应 C# `Models.TitleMatchMode`（序列化为整数）。
public enum TitleMatchMode: Int, Codable {
    case Equals = 0
    case Contains = 1
}

/// 单条标题锁定规则。对应 C# `Models.TitleLockRule`。
public final class TitleLockRule: Codable {
    public var ProcessName: String = ""
    public var OriginalTitle: String = ""
    public var ExecutableDir: String = ""
    public var LockText: String = ""
    /// 可选的模糊匹配字符串；非空时优先用于恢复/主动匹配，nil 表示走精确匹配。
    public var MatchPattern: String?
    public var MatchMode: TitleMatchMode = .Contains
    public var CreatedAt: Date = Date()
    public var UpdatedAt: Date = Date()
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ProcessName = c.or(.ProcessName, "")
        OriginalTitle = c.or(.OriginalTitle, "")
        ExecutableDir = c.or(.ExecutableDir, "")
        LockText = c.or(.LockText, "")
        MatchPattern = c.opt(.MatchPattern)
        MatchMode = c.or(.MatchMode, TitleMatchMode.Contains)
        CreatedAt = c.or(.CreatedAt, Date())
        UpdatedAt = c.or(.UpdatedAt, Date())
    }
}
