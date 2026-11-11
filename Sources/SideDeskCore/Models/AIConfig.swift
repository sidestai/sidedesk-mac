import Foundation

/// AI 服务商/模型信息（对应 C# AIModelInfo）
public struct AIModelInfo: Codable, Equatable {
    public var Id: String = ""
    public var Name: String = ""
    public var ApiBaseUrl: String = ""
    public var DefaultModelId: String = ""
    /// 所属区域：cn / intl / custom（仅设置页分组展示）
    public var Region: String = ""
    /// 官方 API Key 申请地址（设置页展示用）
    public var ApiKeyUrl: String = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, "")
        Name = c.or(.Name, "")
        ApiBaseUrl = c.or(.ApiBaseUrl, "")
        DefaultModelId = c.or(.DefaultModelId, "")
        Region = c.or(.Region, "")
        ApiKeyUrl = c.or(.ApiKeyUrl, "")
    }
}

/// AI 配置（对应 C# AIConfig）
public struct AIConfig: Codable {
    /// 当前选中的服务商 id；旧配置无此字段时为 nil
    public var SelectedModelId: String?
    public var ApiKey: String = ""
    public var CustomModelId: String = ""
    /// 按服务商保存的 API Key（provider id → key）
    public var ApiKeys: [String: String]?
    /// 已同步到云端的 Key 记录 ID（provider id → 服务端记录 id）
    public var ServerKeyIds: [String: String]?
    /// 用户添加的自定义模型（持久化列表，启动时并入 SupportedModels）
    public var CustomModels: [AIModelInfo]?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        SelectedModelId = c.opt(.SelectedModelId)
        ApiKey = c.or(.ApiKey, "")
        CustomModelId = c.or(.CustomModelId, "")
        ApiKeys = c.opt(.ApiKeys)
        ServerKeyIds = c.opt(.ServerKeyIds)
        CustomModels = c.opt(.CustomModels)
    }
}
