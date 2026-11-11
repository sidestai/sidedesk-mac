import Foundation

/// 团队成员。对应 C# `Services.TeamMember`（后端 `/api/team/*` 契约）。
public struct TeamMember: Codable {
    public var Id: String = ""
    public var Name: String = ""
    /// 头像 URL（可为空，空时前端用首字占位圆）
    public var Avatar: String?

    enum CodingKeys: String, CodingKey {
        case Id = "id"
        case Name = "name"
        case Avatar = "avatar"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, "")
        Name = c.or(.Name, "")
        Avatar = c.opt(.Avatar)
    }
}

/// 团队。对应 C# `Services.Team`（后端 `GET /api/team/list` 返回项）。
public struct Team: Codable {
    /// 团队加密串（corpId / encrypt2），与数据变量作用域同源
    public var Id: String = ""
    public var Name: String = ""
    public var Members: [TeamMember] = []
    /// 团队码（加入团队凭证，供成员分享）
    public var InviteCode: String?
    /// 当前用户是否为该团队管理员（创建者）：可审批申请/邀请成员
    public var IsAdmin: Bool = false

    enum CodingKeys: String, CodingKey {
        case Id = "id"
        case Name = "name"
        case Members = "members"
        case InviteCode = "inviteCode"
        case IsAdmin = "isAdmin"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, "")
        Name = c.or(.Name, "")
        Members = c.or(.Members, [])
        InviteCode = c.opt(.InviteCode)
        IsAdmin = c.or(.IsAdmin, false)
    }
}
