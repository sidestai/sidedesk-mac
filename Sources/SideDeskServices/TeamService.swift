import Foundation
import SideDeskCore

/// 团队服务的后端读接口。对应 C# `Services.TeamService` 的 `ListTeamsAsync`（本批次只取变量集
/// 拉取所需的一端）；创建/加入/审批/邀请等写接口随 UI 批次再补。
///
/// 基址、Bearer 注入、信封解包与认证失败记账统一走 `BackendApiClient`——本类只写「方法 + 路径 + 回落值」。
public final class TeamService {

    private let api: BackendApiClient

    /// 最近一次请求是否因认证失败（401/403），供 UI 判断是否需要刷新登录状态
    public var LastAuthFailed: Bool { api.LastAuthFailed }

    /// - Parameter transport: 仅测试注入；生产走 URLSession（超时 30 秒与 C# 一致）
    public init(transport: BackendApiClient.Transport? = nil) {
        api = BackendApiClient(logTag: "[Team]", timeout: 30, transport: transport)
    }

    /// `GET /api/team/list` — 返回我所在的团队数组（含成员列表）；失败返回 nil。
    public func listTeamsAsync() async -> [Team]? {
        await api.sendList("GET", "/api/team/list")
    }
}
