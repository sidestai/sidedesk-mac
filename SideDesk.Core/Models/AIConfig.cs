using System.Collections.Generic;

namespace SideDesk.Models
{
    public class AIModelInfo
    {
        public string Id { get; set; } = string.Empty;
        public string Name { get; set; } = string.Empty;
        public string ApiBaseUrl { get; set; } = string.Empty;
        public string DefaultModelId { get; set; } = string.Empty;
        /// <summary>所属区域：cn=中国 / intl=国际 / custom=自定义（仅用于设置页分组展示）</summary>
        public string Region { get; set; } = string.Empty;
        /// <summary>官方 API Key 申请地址（设置页展示用）</summary>
        public string ApiKeyUrl { get; set; } = string.Empty;
    }

    public class AIConfig
    {
        /// <summary>当前选中的服务商 id；旧配置文件无此字段或已无可用模型时为 null</summary>
        public string? SelectedModelId { get; set; }
        public string ApiKey { get; set; } = string.Empty;
        public string CustomModelId { get; set; } = string.Empty;
        /// <summary>按服务商保存的 API Key（provider id → key）；未配置的服务商不在主下拉中显示。旧配置文件可能为 null，读写处均有空值兜底</summary>
        public Dictionary<string, string>? ApiKeys { get; set; }
        /// <summary>已同步到云端的 Key 记录 ID（provider id → 服务端记录 id），用于云端删除/覆盖更新。未同步时为 null</summary>
        public Dictionary<string, string>? ServerKeyIds { get; set; }
        /// <summary>
        /// 用户添加的自定义模型（#71）：持久化的列表（旧版单条 "custom" 由 MigrateLegacyKey 迁入）。
        /// 启动时并入 SupportedModels 供选择器展示；ApiKey 仍存 ApiKeys 字典（id → key）。旧配置文件可能为 null。
        /// </summary>
        public List<AIModelInfo>? CustomModels { get; set; }
    }
}
