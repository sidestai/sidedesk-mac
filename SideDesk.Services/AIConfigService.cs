using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Newtonsoft.Json;
using SideDesk.Models;

namespace SideDesk.Services;

/// <summary>
/// AI 配置管理服务（#339 Models 去 ActiveRecord）：原 AIConfigManager 静态门面改为实例服务。
/// 管理 aiconfig.json / SQLite（local_app_state KV）的加载与保存，提供模型目录、服务商 Key、
/// 自定义模型的增删查改。模型目录（SupportedModels）为实例状态——每次重启从内置预设 + 持久化的
/// 自定义模型重建，内置预设删除后重启恢复。
/// </summary>
public class AIConfigService
{
    private const string DbKey = "ai_config";

    // 测试缝隙：隔离目录（ADR-0003 同款；null=真实路径）。设置后走独立 JSON 文件，
    // 不触碰真实 aiconfig.json / 业务库（fixes #215）。
    private string? _dirOverride;

    // 首次访问时由 GetConfig() 惰性加载并缓存
    private AIConfig? _config;
    private readonly object _lock = new();

    /// <summary>
    /// 测试缝隙：重定向 AI 配置持久化目录（ADR-0003 同款形态）。
    /// 设置后 GetConfig/SaveConfig 走独立 JSON 文件（&lt;dir&gt;/aiconfig.json）而非真实用户配置，
    /// 并清空内存缓存从隔离文件重载；读回真实配置请置 null。
    /// </summary>
    public string? DirOverride
    {
        get => _dirOverride;
        set
        {
            _dirOverride = value;
            lock (_lock) { _config = null; }
        }
    }

    /// <summary>aiconfig.json 路径：DirOverride 生效时指向隔离目录（语义同 LocalDbService.DirOverride）。</summary>
    private string FilePath
    {
        get
        {
            string folder = _dirOverride ?? Framework.AppPaths.DataDir;
            return Path.Combine(folder, "aiconfig.json");
        }
    }

    /// <summary>
    /// 内置（微屏提供的 API）预设模型目录——静态模板，不随实例变化。
    /// #676 产品定调：中转是主渠道（KTH 网关配 Key 即用全部主流模型），其它渠道一律走「自定义」；
    /// 直连厂商预设下线，定义留在 <see cref="LegacyDirectVendors"/> 仅供存量迁移。
    /// </summary>
    private static readonly AIModelInfo[] BuiltinCatalog =
    {
        // ---------- 中转（微屏自营网关，#674）----------
        // Key 由运营方发放（无公开申请页，ApiKeyUrl 留空隐藏引导链接）；模型清单不在预设里写死——
        // 配好 Key 后由 GatewayModelCatalogService 实时拉 {base}/models 展开模型级列表（#507 同款）。
        new AIModelInfo { Id = "kth-relay", Name = "微屏中转", ApiBaseUrl = "https://gateway.bigjing.com", DefaultModelId = "glm-5.3", Region = "relay" },
        // ---------- 自定义 ----------
        new AIModelInfo { Id = "custom", Name = "自定义", ApiBaseUrl = "", DefaultModelId = "", Region = "custom" }
    };

    /// <summary>
    /// 已下线的直连厂商预设（#676）：**仅存量迁移用**——ApiKeys/ServerKeyIds 里还留着 Key 的厂商，
    /// 由 <see cref="MigrateLegacyDirectVendors"/> 按原定义转入自定义列表（custom-&lt;id&gt;）；
    /// 从未配置过的不迁移（下线即不可新增）。
    /// </summary>
    private static readonly AIModelInfo[] LegacyDirectVendors =
    {
        new AIModelInfo { Id = "deepseek", Name = "深度求索 (DeepSeek)", ApiBaseUrl = "https://api.deepseek.com", DefaultModelId = "deepseek-flash", Region = "cn", ApiKeyUrl = "https://platform.deepseek.com/api_keys" },
        new AIModelInfo { Id = "qwen", Name = "阿里巴巴 (通义千问)", ApiBaseUrl = "https://dashscope.aliyuncs.com/compatible-mode", DefaultModelId = "qwen-plus", Region = "cn", ApiKeyUrl = "https://dashscope.console.aliyun.com/api-key" },
        new AIModelInfo { Id = "doubao", Name = "火山引擎豆包", ApiBaseUrl = "https://ark.cn-beijing.volces.com/api/v3", DefaultModelId = "doubao-1-5-pro-32k-250115", Region = "cn", ApiKeyUrl = "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey" },
        new AIModelInfo { Id = "wenxin", Name = "百度（文心一言）", ApiBaseUrl = "https://qianfan.baidubce.com/v2", DefaultModelId = "ernie-4.0-8k", Region = "cn", ApiKeyUrl = "https://console.bce.baidu.com/qianfan/ais/console/applicationConsole/application/v2" },
        new AIModelInfo { Id = "hunyuan", Name = "腾讯混元", ApiBaseUrl = "https://api.hunyuan.cloud.tencent.com/v1", DefaultModelId = "hunyuan-large", Region = "cn", ApiKeyUrl = "https://console.cloud.tencent.com/hunyuan/api-key" },
        new AIModelInfo { Id = "glm", Name = "智谱AI (GLM)", ApiBaseUrl = "https://open.bigmodel.cn/api/paas/v4", DefaultModelId = "glm-4", Region = "cn", ApiKeyUrl = "https://bigmodel.cn/usercenter/apikeys" },
        new AIModelInfo { Id = "kimi", Name = "月之暗面 (Kimi)", ApiBaseUrl = "https://api.moonshot.cn/v1", DefaultModelId = "moonshot-v1-8k", Region = "cn", ApiKeyUrl = "https://platform.moonshot.cn/console/api-keys" },
        new AIModelInfo { Id = "spark", Name = "科大讯飞 (星火)", ApiBaseUrl = "https://spark-api-open.xf-yun.com/v1", DefaultModelId = "general", Region = "cn", ApiKeyUrl = "https://console.xfyun.cn/services" },
        new AIModelInfo { Id = "minimax", Name = "MiniMax (海螺AI)", ApiBaseUrl = "https://api.minimax.chat/v1", DefaultModelId = "MiniMax-Text-01", Region = "cn", ApiKeyUrl = "https://platform.minimaxi.com/user-center/basic-information/interface-key" },
        new AIModelInfo { Id = "mimo", Name = "小米Mimo", ApiBaseUrl = "https://api.xiaomimimo.com/v1", DefaultModelId = "mimo-chat", Region = "cn", ApiKeyUrl = "https://xiaomimimo.com" },
        new AIModelInfo { Id = "tencentcloud", Name = "腾讯云", ApiBaseUrl = "https://api.lkeap.cloud.tencent.com/v1", DefaultModelId = "hunyuan-large", Region = "cn", ApiKeyUrl = "https://console.cloud.tencent.com/lkeap/api" },
        new AIModelInfo { Id = "openai", Name = "OpenAI", ApiBaseUrl = "https://api.openai.com", DefaultModelId = "gpt-3.5-turbo", Region = "intl", ApiKeyUrl = "https://platform.openai.com/api-keys" },
        new AIModelInfo { Id = "anthropic", Name = "Anthropic (Claude)", ApiBaseUrl = "https://api.anthropic.com", DefaultModelId = "claude-sonnet-4-20250514", Region = "intl", ApiKeyUrl = "https://console.anthropic.com/settings/keys" },
        new AIModelInfo { Id = "google", Name = "Google Gemini", ApiBaseUrl = "https://generativelanguage.googleapis.com/v1beta/openai", DefaultModelId = "gemini-2.0-flash", Region = "intl", ApiKeyUrl = "https://aistudio.google.com/apikey" },
        new AIModelInfo { Id = "xai", Name = "xAI (Grok)", ApiBaseUrl = "https://api.x.ai/v1", DefaultModelId = "grok-3", Region = "intl", ApiKeyUrl = "https://console.x.ai" },
        new AIModelInfo { Id = "mistral", Name = "Mistral AI", ApiBaseUrl = "https://api.mistral.ai/v1", DefaultModelId = "mistral-large-latest", Region = "intl", ApiKeyUrl = "https://console.mistral.ai/api-keys" },
        new AIModelInfo { Id = "cohere", Name = "Cohere", ApiBaseUrl = "https://api.cohere.ai/compatibility/v1", DefaultModelId = "command-r-plus", Region = "intl", ApiKeyUrl = "https://dashboard.cohere.com/api-keys" },
        new AIModelInfo { Id = "groq", Name = "Groq", ApiBaseUrl = "https://api.groq.com/openai/v1", DefaultModelId = "llama-3.3-70b-versatile", Region = "intl", ApiKeyUrl = "https://console.groq.com/keys" },
        new AIModelInfo { Id = "together", Name = "Together AI", ApiBaseUrl = "https://api.together.xyz/v1", DefaultModelId = "meta-llama/Llama-3.3-70B-Instruct-Turbo", Region = "intl", ApiKeyUrl = "https://api.together.xyz/settings/api-keys" },
        new AIModelInfo { Id = "perplexity", Name = "Perplexity", ApiBaseUrl = "https://api.perplexity.ai", DefaultModelId = "sonar", Region = "intl", ApiKeyUrl = "https://www.perplexity.ai/settings/api" },
    };

    /// <summary>当前可用模型目录（内置预设 + 用户自定义）；实例状态，重启从模板重建。</summary>
    public List<AIModelInfo> SupportedModels { get; } = new(BuiltinCatalog);

    public AIConfig GetConfig()
    {
        if (_config != null)
            return _config;

        lock (_lock)
        {
            if (_config != null)
                return _config;

            try
            {
                // 隔离模式（测试）：仅走独立 JSON 文件，完全不碰真实业务库 / aiconfig.json
                if (_dirOverride != null)
                {
                    if (File.Exists(FilePath))
                    {
                        string fileJson = File.ReadAllText(FilePath);
                        _config = JsonConvert.DeserializeObject<AIConfig>(fileJson);
                    }
                }
                // 真实模式：主存储 SQLite（local_app_state KV）；无值时从旧 aiconfig.json 一次性迁入
                else if (LocalDbService.DbExists)
                {
                    string? dbJson = LocalDbService.LoadBusinessData(DbKey);
                    if (!string.IsNullOrEmpty(dbJson))
                        _config = JsonConvert.DeserializeObject<AIConfig>(dbJson);
                    else if (File.Exists(FilePath))
                    {
                        string fileJson = File.ReadAllText(FilePath);
                        _config = JsonConvert.DeserializeObject<AIConfig>(fileJson);
                        if (_config != null)
                            LocalDbService.SaveBusinessData(DbKey, JsonConvert.SerializeObject(_config));
                    }
                }
                else if (File.Exists(FilePath))
                {
                    string json = File.ReadAllText(FilePath);
                    _config = JsonConvert.DeserializeObject<AIConfig>(json);
                }
            }
            catch
            {
                // Ignore load errors
            }

            if (_config == null)
            {
                _config = new AIConfig
                {
                    SelectedModelId = "kth-relay"
                };
            }

            MigrateLegacyKey(_config);
            MigrateLegacyDirectVendors(_config);
            RestoreCustomModels(_config);

            return _config;
        }
    }

    public void SaveConfig(AIConfig config)
    {
        lock (_lock)
        {
            try
            {
                _config = config;
                string json = JsonConvert.SerializeObject(config, Formatting.Indented);
                // 隔离模式（测试）：只写独立文件，不触碰真实业务库（fixes #215）
                if (_dirOverride != null)
                {
                    string dir = Path.GetDirectoryName(FilePath)!;
                    if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                    File.WriteAllText(FilePath, json);
                    return;
                }
                if (LocalDbService.DbExists)
                {
                    try { LocalDbService.SaveBusinessData(DbKey, json); return; }
                    catch { }
                }
                // db 不可用/未建立：退回旧 JSON 存储
                string realDir = Path.GetDirectoryName(FilePath)!;
                if (!Directory.Exists(realDir)) Directory.CreateDirectory(realDir);
                File.WriteAllText(FilePath, json);
            }
            catch
            {
                // Ignore save errors
            }
        }
    }

    public AIModelInfo GetSelectedModel()
    {
        var config = GetConfig();
        return SupportedModels.Find(m => m.Id == config.SelectedModelId) ?? SupportedModels[0];
    }

    /// <summary>
    /// 构造 OpenAI 兼容 chat/completions 端点（fixes #293）：base 末尾已带版本段（/v1、/v2、/v3、/v1beta 等）
    /// 时只补 /chat/completions，否则补默认的 /v1/chat/completions。全链路统一入口，避免各调用点
    /// 对已含版本的 base 重复拼出 /v1/v1（kimi/hunyuan/glm/doubao 等曾因此请求失败）。
    /// </summary>
    public static string BuildChatCompletionsUrl(string apiBaseUrl)
    {
        string b = (apiBaseUrl ?? string.Empty).TrimEnd('/');
        if (System.Text.RegularExpressions.Regex.IsMatch(b, @"/v\d+[A-Za-z]*$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            return b + "/chat/completions";
        return b + "/v1/chat/completions";
    }

    /// <summary>旧版单 Key 迁移：视为属于当时选中的服务商。</summary>
    private static void MigrateLegacyKey(AIConfig config)
    {
        if (config.ApiKeys == null)
            config.ApiKeys = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrEmpty(config.ApiKey)
            && !string.IsNullOrEmpty(config.SelectedModelId)
            && !config.ApiKeys.ContainsKey(config.SelectedModelId))
        {
            config.ApiKeys[config.SelectedModelId] = config.ApiKey;
        }
    }

    /// <summary>
    /// 直连厂商预设下线后的存量迁移（#676，幂等）：配置过 Key/云端记录的厂商改键为
    /// <c>custom-&lt;id&gt;</c> 并按原定义转入 CustomModels——选择器展示、表单编辑（#222 多条目
    /// 自定义路径）、云同步删除全部延续，用户无感；从未配置过的不迁移（下线即不可新增）。
    /// 必须在 <see cref="RestoreCustomModels"/> 之前调用（转入条目由它并入 SupportedModels）。
    /// </summary>
    private void MigrateLegacyDirectVendors(AIConfig config)
    {
        if ((config.ApiKeys == null || config.ApiKeys.Count == 0)
            && (config.ServerKeyIds == null || config.ServerKeyIds.Count == 0))
            return;
        config.CustomModels ??= new List<AIModelInfo>();
        bool changed = false;
        foreach (var legacy in LegacyDirectVendors)
        {
            bool hasKey = config.ApiKeys != null && config.ApiKeys.ContainsKey(legacy.Id);
            bool hasServerId = config.ServerKeyIds != null && config.ServerKeyIds.ContainsKey(legacy.Id);
            if (!hasKey && !hasServerId) continue;
            var newId = "custom-" + legacy.Id;
            // 同名自定义条目已存在（用户先手工建过）时不覆盖其定义，仅改键
            if (hasKey) { config.ApiKeys![newId] = config.ApiKeys[legacy.Id]; config.ApiKeys.Remove(legacy.Id); }
            if (hasServerId) { config.ServerKeyIds![newId] = config.ServerKeyIds[legacy.Id]; config.ServerKeyIds.Remove(legacy.Id); }
            if (!config.CustomModels.Exists(m => m.Id == newId))
            {
                config.CustomModels.Add(new AIModelInfo
                {
                    Id = newId,
                    Name = legacy.Name,
                    ApiBaseUrl = legacy.ApiBaseUrl,
                    DefaultModelId = legacy.DefaultModelId,
                    ApiKeyUrl = legacy.ApiKeyUrl,
                });
            }
            if (config.SelectedModelId == legacy.Id)
                config.SelectedModelId = newId;
            changed = true;
            Framework.RuntimeLog.Info("AIConfig", $"直连厂商预设下线迁移：{legacy.Id} → {newId}（#676）");
        }
        if (changed)
            SaveConfig(config);   // 落盘改键与 CustomModels（Monitor 可重入，同线程安全）
    }

    /// <summary>
    /// 自定义模型恢复（#71）：把持久化的 CustomModels 并入 SupportedModels（重启不丢）。
    /// 旧版本只有条 id="custom" 的内存定义——若其 Key 存在但列表为空，补建一条（名取 Key 旁的 BaseUrl/模型 ID 无法还原，用通用名）。
    /// 在 GetConfig 完成后调用（幂等：同 id 覆盖）。
    /// </summary>
    private void RestoreCustomModels(AIConfig config)
    {
        if (config.CustomModels == null) config.CustomModels = new List<AIModelInfo>();
        foreach (var m in config.CustomModels)
        {
            if (string.IsNullOrEmpty(m.Id)) continue;
            m.Region = "custom";
            AddOrUpdateModel(m);
        }
    }

    /// <summary>新增/更新自定义模型（#71：持久化到 CustomModels；id 为空时生成）。返回生效的模型定义。</summary>
    public AIModelInfo AddOrUpdateCustomModel(AIModelInfo model, string? apiKey = null)
    {
        var cfg = GetConfig();
        cfg.CustomModels ??= new List<AIModelInfo>();
        if (string.IsNullOrEmpty(model.Id))
            model.Id = "custom-" + Guid.NewGuid().ToString("N")[..8];
        model.Region = "custom";
        var idx = cfg.CustomModels.FindIndex(m => m.Id == model.Id);
        if (idx >= 0) cfg.CustomModels[idx] = model;
        else cfg.CustomModels.Add(model);
        if (!string.IsNullOrEmpty(apiKey))
        {
            cfg.ApiKeys ??= new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            cfg.ApiKeys[model.Id] = apiKey!;
        }
        AddOrUpdateModel(model);
        SaveConfig(cfg);
        return model;
    }

    /// <summary>移除自定义模型及其 Key（#71）。</summary>
    public void RemoveCustomModel(string id)
    {
        var cfg = GetConfig();
        cfg.CustomModels?.RemoveAll(m => m.Id == id);
        cfg.ApiKeys?.Remove(id);
        cfg.ServerKeyIds?.Remove(id);
        SupportedModels.RemoveAll(m => m.Id == id);
        if (cfg.SelectedModelId == id)
            cfg.SelectedModelId = SupportedModels.FirstOrDefault()?.Id;
        SaveConfig(cfg);
    }

    /// <summary>用户添加的自定义模型（持久化列表）。</summary>
    public List<AIModelInfo> GetCustomModels() => GetConfig().CustomModels ?? new List<AIModelInfo>();

    /// <summary>内置（微屏提供的 API）：SupportedModels 中除自定义外的预设。</summary>
    public List<AIModelInfo> GetBuiltinModels() => SupportedModels.FindAll(m => m.Region != "custom" && m.Id != "custom");

    /// <summary>设置当前选中的模型（持久化；供语音面板上拉选择器调用）。
    /// 同时清空 <see cref="AIConfig.CustomModelId"/>：厂商级选择 = 回到该厂商默认款，
    /// 也治愈「市场选过具体模型后切厂商，残留覆盖作用于新厂商」的旧疾（ApplyMarketModel 注释记录过）。
    /// 要选中网关下的具体模型用 <see cref="SelectCustomModel"/>（#507）。</summary>
    public void SelectModel(string id)
    {
        var cfg = GetConfig();
        cfg.SelectedModelId = id;
        cfg.CustomModelId = string.Empty;
        SaveConfig(cfg);
    }

    /// <summary>
    /// 选中自定义网关下的**具体模型**（#507 模型级选择）：SelectedModelId 切到该网关条目，
    /// CustomModelId 写入具体模型 ID——全部 chat 路径（AI 对话 / 语音问答 / 整理文字 / HTML 插件桥）
    /// 均按「CustomModelId 非空优先于厂商默认」下发，该全局覆盖与本方法语义天然一致
    /// （用户此刻在语音面板选的就是他要的模型）。
    /// </summary>
    public void SelectCustomModel(AIModelInfo gateway, string modelId)
    {
        if (gateway == null || string.IsNullOrEmpty(modelId)) return;
        var cfg = GetConfig();
        cfg.SelectedModelId = gateway.Id;
        cfg.CustomModelId = modelId;
        SaveConfig(cfg);
    }

    /// <summary>当前生效的具体模型 ID（CustomModelId 非空优先；供展示与请求下发统一取值）。</summary>
    public string GetEffectiveModelId(AIModelInfo model)
    {
        var cfg = GetConfig();
        return string.IsNullOrEmpty(cfg.CustomModelId) ? (model?.DefaultModelId ?? string.Empty) : cfg.CustomModelId;
    }

    /// <summary>
    /// 应用模型市场选中的模型：切换厂商 + 按需写入模型覆盖
    /// （modelId 为空或等于厂商默认模型时清除覆盖，否则写入 CustomModelId）。
    /// 注意：CustomModelId 是全局单值（与厂商无关），此后手动切换厂商时残留覆盖会作用于新厂商；
    /// 按厂商分桶是后续独立议题。返回该厂商是否已配置 API Key（false 时调用方应提示先去设置页配 Key）。
    /// </summary>
    public bool ApplyMarketModel(string providerId, string? modelId)
    {
        var provider = SupportedModels.Find(m => m.Id == providerId);
        if (provider == null) return false;
        SelectModel(providerId);
        var cfg = GetConfig();
        cfg.CustomModelId = string.IsNullOrEmpty(modelId) || modelId == provider.DefaultModelId
            ? string.Empty
            : modelId!;
        SaveConfig(cfg);
        return IsProviderConfigured(providerId);
    }

    /// <summary>取指定服务商的 API Key（优先按服务商字典，回退旧版单 Key）</summary>
    public string GetApiKeyFor(string providerId)
    {
        if (string.IsNullOrEmpty(providerId)) return string.Empty;
        var cfg = GetConfig();
        if (cfg.ApiKeys != null && cfg.ApiKeys.TryGetValue(providerId, out var key) && !string.IsNullOrEmpty(key))
            return key;
        if (providerId.Equals(cfg.SelectedModelId, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrEmpty(cfg.ApiKey))
            return cfg.ApiKey;
        return string.Empty;
    }

    /// <summary>服务商是否已配置（有 API Key）</summary>
    public bool IsProviderConfigured(string providerId) => !string.IsNullOrEmpty(GetApiKeyFor(providerId));

    /// <summary>已配置的服务商列表（保持预设顺序），未配置的不在主下拉中显示；英文语言下隐藏中国厂商</summary>
    public List<AIModelInfo> GetConfiguredModels() => SupportedModels.FindAll(m =>
        IsProviderConfigured(m.Id) && !(Framework.Lang.Current == Framework.Lang.En && m.Region == "cn"));

    /// <summary>新增/更新一个服务商定义（设置页「大模型」保存自定义厂商时调用；同 Id 覆盖）</summary>
    public void AddOrUpdateModel(AIModelInfo model)
    {
        int idx = SupportedModels.FindIndex(m => m.Id == model.Id);
        if (idx >= 0) SupportedModels[idx] = model;
        else SupportedModels.Insert(Math.Max(0, SupportedModels.Count - 1), model); // 保持在 custom 之前
    }

    /// <summary>移除一个服务商定义及其 Key（设置页删除时调用；内置预设也允许移除，重启后恢复）</summary>
    public void RemoveModel(string providerId)
    {
        var cfg = GetConfig();
        cfg.ApiKeys?.Remove(providerId);
        cfg.ServerKeyIds?.Remove(providerId);
        SupportedModels.RemoveAll(m => m.Id == providerId);
        if (cfg.SelectedModelId == providerId)
            cfg.SelectedModelId = SupportedModels.Count > 0 ? SupportedModels[0].Id : null;
        SaveConfig(cfg);
    }

    /// <summary>取服务商对应的云端记录 ID（未同步返回 null）</summary>
    public string? GetServerKeyId(string providerId)
    {
        var cfg = GetConfig();
        return cfg.ServerKeyIds != null && cfg.ServerKeyIds.TryGetValue(providerId, out var id) ? id : null;
    }

    /// <summary>记录服务商的云端记录 ID（同步成功后回写）</summary>
    public void SetServerKeyId(string providerId, string serverId)
    {
        var cfg = GetConfig();
        if (cfg.ServerKeyIds == null)
            cfg.ServerKeyIds = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        cfg.ServerKeyIds[providerId] = serverId;
        SaveConfig(cfg);
    }
}
