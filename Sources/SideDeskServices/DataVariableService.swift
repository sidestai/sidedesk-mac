import Foundation
import SideDeskCore

/// 数据看板变量的后端读接口（基址见 `Constants.URLs.serverBaseUrl`，与团队服务同一鉴权与信封格式）。
/// 对应 C# `Services.DataVariableService`。
///
/// 变量作用域：`corpId` 有值=团队内唯一，为空=个人内唯一。
/// 失败一律回落 nil/默认值，由调用方优雅降级（不阻断、不抛）。
///
/// 本批次只落地云端变量集拉取所需的 `listSetsAsync`；唯一性校验、变量列表、
/// 删除登记仍属 C# 侧同名方法，待 UI（变量详情窗）移植时补。
public final class DataVariableService {

    private let api: BackendApiClient

    /// - Parameter transport: 仅测试注入；生产走 URLSession（超时 10 秒与 C# 一致）
    public init(transport: BackendApiClient.Transport? = nil) {
        api = BackendApiClient(logTag: "[DataVariable]", timeout: 10, transport: transport)
    }

    /// `GET /api/sidebar/data-variable/sets` — 列出作用域内全部变量集（corpId 为空=个人）。
    /// 未登录直接返回 nil（不发请求）；失败返回 nil。
    public func listSetsAsync(corpId: String?) async -> [VariableSetInfo]? {
        if BackendApiClient.token().isEmpty { return nil }
        var path = "/api/sidebar/data-variable/sets"
        if let corpId, !corpId.isEmpty {
            path += "?corpId=" + BackendApiClient.queryValue(corpId)
        }
        return await api.sendList("GET", path)
    }
}
