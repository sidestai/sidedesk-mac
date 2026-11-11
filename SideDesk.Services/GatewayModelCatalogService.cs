using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using SideDesk.Models;

namespace SideDesk.Services;

/// <summary>网关模型目录条目（modelId + 展示名），供语音模型选择器按**模型级**展示。</summary>
public class GatewayModelEntry
{
    /// <summary>发给 API 的真实模型 ID（如 glm-5.3-flash）</summary>
    public string ModelId { get; set; } = string.Empty;

    /// <summary>展示名（目录未提供或与 ModelId 相同时即用 ModelId）</summary>
    public string DisplayName { get; set; } = string.Empty;
}

/// <summary>
/// 网关模型目录服务（#507）：对**已配置的自定义网关模型**（Region=custom 且有 Key）拉取
/// OpenAI 兼容的 <c>GET {base}/models</c>，返回模型级清单，供语音模型选择器对齐网关实际
/// 提供的模型（如 KTH 生产机网关的 glm-5.3 / glm-5.3-flash / deepseek-v4-pro 等）。
///
/// <para><b>过滤规则</b>：embedding / rerank 类模型 ID 不进对话选择器（bge-* / *embedding* /
/// *rerank* 等模式，见 <see cref="IsChatModel"/>）；同 ID 去重，按 ID 排序稳定展示。</para>
///
/// <para><b>失败语义</b>：本服务是选择器的**增强数据源**，不是依赖——任何失败（未配置、
/// 网络错、超时、响应形状不符）都返回空列表并落 Warn 日志，调用方回落上次缓存（<see cref="LoadCached"/>），
/// 绝不阻塞 UI、不弹错误框（与 VoicePolishLlmClient 的「增强不依赖」纪律一致）。</para>
///
/// <para><b>传输缝隙</b>：<see cref="HttpFactory"/> 可注入替身（单测不联网，见 GatewayModelCatalogTests）。</para>
/// </summary>
public class GatewayModelCatalogService
{
    /// <summary>HTTP 传输缝隙：() => HttpClient。单测注入本地假服务器或 stub。</summary>
    public static Func<HttpClient> HttpFactory { get; set; } = () => new HttpClient();

    /// <summary>列表请求超时（毫秒）：选择器打开时的拉取不能让用户等网络慢网关。</summary>
    private static int TimeoutMs => Framework.Tuning.Int("llm", "gatewayModels.timeoutMs", 4000);

    /// <summary>
    /// 拉取指定网关（自定义模型条目）的模型清单。失败返回空列表（不抛异常）。
    /// </summary>
    public async Task<List<GatewayModelEntry>> FetchAsync(AIModelInfo gateway, string apiKey, CancellationToken ct = default)
    {
        if (gateway == null || string.IsNullOrWhiteSpace(gateway.ApiBaseUrl) || string.IsNullOrWhiteSpace(apiKey))
            return new();

        var url = BuildModelsUrl(gateway.ApiBaseUrl);
        try
        {
            using var http = HttpFactory();
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(Math.Max(1000, TimeoutMs));
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.Add("Authorization", "Bearer " + apiKey);

            using var resp = await http.SendAsync(req, cts.Token).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                Framework.RuntimeLog.Warn("AIConfig", $"网关模型目录拉取失败：HTTP {(int)resp.StatusCode}（{url}）");
                return new();
            }
            var json = await resp.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
            var list = ParseModelIds(json);
            // 拉取成功即写缓存：失败回落（LoadCached）与选择器秒开都依赖这里，
            // 调用方无需关心缓存写入（空列表不缓存，见 SaveCache）
            SaveCache(gateway.Id, list);
            Framework.RuntimeLog.Debug($"[GatewayModels] {url} → {list.Count} 个对话模型");
            return list;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            Framework.RuntimeLog.Warn("AIConfig", $"网关模型目录拉取超时（{TimeoutMs}ms）：{url}");
            return new();
        }
        catch (Exception ex)
        {
            Framework.RuntimeLog.Warn("AIConfig", $"网关模型目录拉取异常（{url}）：{ex.Message}");
            return new();
        }
    }

    /// <summary>
    /// 解析 OpenAI 兼容 models 响应（{"data":[{"id":"...","owned_by":"..."}]}）：
    /// 只留对话模型、去重、按 ID 排序。公开静态纯函数（单测直测，不联网）。
    /// </summary>
    public static List<GatewayModelEntry> ParseModelIds(string json)
    {
        var result = new List<GatewayModelEntry>();
        try
        {
            var root = JObject.Parse(json);
            if (root["data"] is not { } arr) return result;
            foreach (var item in arr)
            {
                var id = item?["id"]?.ToString();
                if (string.IsNullOrWhiteSpace(id) || !IsChatModel(id)) continue;
                var name = item?["name"]?.ToString();
                result.Add(new GatewayModelEntry
                {
                    ModelId = id,
                    DisplayName = string.IsNullOrWhiteSpace(name) ? id : name!,
                });
            }
        }
        catch (Exception ex)
        {
            Framework.RuntimeLog.Warn("AIConfig", $"网关模型目录响应解析失败：{ex.Message}");
        }
        // 同 ID 去重 + 排序：展示顺序稳定，不随网关返回顺序抖动
        return result
            .GroupBy(e => e.ModelId, StringComparer.OrdinalIgnoreCase)
            .Select(g => g.First())
            .OrderBy(e => e.ModelId, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    /// <summary>
    /// 是否对话模型：embedding / rerank / 重排序类不进对话选择器。
    /// 模式按 ID 与 owned_by 双判（KTH 网关实测 embedding 类为 bge-* / *-Embedding-* 形态，
    /// owned_by=siliconflow；其余 owned_by 语义是「上游厂商」不能作排除依据，见 GatewayModelCatalogTests）。
    /// </summary>
    internal static bool IsChatModel(string modelId)
    {
        if (string.IsNullOrWhiteSpace(modelId)) return false;
        var lower = modelId.ToLowerInvariant();
        return lower.Contains("embedding") is false
            && lower.Contains("embed") is false
            && lower.Contains("rerank") is false
            && lower.Contains("bge-") is false;
    }

    /// <summary>
    /// 构造 models 端点：base 已带版本段（/v1 等）只补 /models，否则补 /v1/models
    /// （与 <see cref="AIConfigService.BuildChatCompletionsUrl"/> 同判据——支持 one-api/new-api
    /// 这类挂在根路径或 /v1 下的网关）。
    /// </summary>
    public static string BuildModelsUrl(string apiBaseUrl)
    {
        var b = (apiBaseUrl ?? string.Empty).TrimEnd('/');
        if (System.Text.RegularExpressions.Regex.IsMatch(b, @"/v\d+[A-Za-z]*$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            return b + "/models";
        return b + "/v1/models";
    }

    // ==================== 缓存（内存级：会话内跨次打开选择器复用；失败回落） ====================

    private static readonly Dictionary<string, List<GatewayModelEntry>> _cache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly object _cacheLock = new();

    /// <summary>缓存写入（拉取成功后调用；空列表不缓存——失败态不该覆盖上次成功结果）。</summary>
    internal static void SaveCache(string gatewayId, List<GatewayModelEntry> entries)
    {
        if (entries.Count == 0) return;
        lock (_cacheLock) { _cache[gatewayId] = entries; }
    }

    /// <summary>读缓存（无缓存返回空列表）。选择器打开瞬间先渲染缓存，再后台刷新。</summary>
    internal static List<GatewayModelEntry> LoadCached(string gatewayId)
    {
        lock (_cacheLock)
        {
            return _cache.TryGetValue(gatewayId, out var v) ? new List<GatewayModelEntry>(v) : new List<GatewayModelEntry>();
        }
    }

    /// <summary>清缓存（测试隔离用）。</summary>
    internal static void ResetCache()
    {
        lock (_cacheLock) { _cache.Clear(); }
    }
}
