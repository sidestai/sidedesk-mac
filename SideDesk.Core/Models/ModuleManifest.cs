namespace SideDesk.Models;

using System.Collections.Generic;
using Newtonsoft.Json;

/// <summary>
/// 第三方模块清单（<c>module.json</c>，模块 zip 包的根声明）。
///
/// <para>与仓内随包模块的差别：随包模块的 id/能力来自**契约生成常量**（contracts/&lt;m&gt;/v1/gen），
/// 第三方模块够不着那些常量，故身份与能力声明全部落在本清单里——安装期由宿主按同一份判据复检
/// （ADR-0019 §5「静态查仓库里的、运行时查装进来的」）。</para>
/// </summary>
public sealed class ModuleManifest
{
    /// <summary>模块 id（目录名 / 虚拟主机名 / 授权记账键；小写字母数字与连字符）</summary>
    [JsonProperty("id")]
    public string Id { get; set; } = "";

    /// <summary>显示名称</summary>
    [JsonProperty("name")]
    public string Name { get; set; } = "";

    /// <summary>多语言名称（语言代码 → 文本），缺失回落 <see cref="Name"/></summary>
    [JsonProperty("nameI18n")]
    public Dictionary<string, string> NameI18n { get; set; } = new();

    /// <summary>模块版本</summary>
    [JsonProperty("version")]
    public string Version { get; set; } = "1.0.0";

    /// <summary>描述</summary>
    [JsonProperty("description")]
    public string Description { get; set; } = "";

    /// <summary>多语言描述（语言代码 → 文本），缺失回落 <see cref="Description"/></summary>
    [JsonProperty("descriptionI18n")]
    public Dictionary<string, string> DescriptionI18n { get; set; } = new();

    /// <summary>作者</summary>
    [JsonProperty("author")]
    public string Author { get; set; } = "";

    /// <summary>入口文件名（相对模块目录；宿主按 modules/&lt;id&gt;/ 约定定位）。
    /// 语义按 <see cref="Kind"/> 分派：exe = 可执行文件、dll = 程序集文件、html = 通常留空（走 ModuleHtml/SettingsHtml）。</summary>
    [JsonProperty("entry")]
    public string Entry { get; set; } = "";

    /// <summary>
    /// 运行时形态原始字符串（#767）：<c>exe</c> / <c>dll</c> / <c>html</c>；缺失或未知回落 <c>exe</c>。
    /// 保留原字符串以便未知值也能进日志（宽松解析，坏一个字段不炸整份清单）。
    /// </summary>
    [JsonProperty("kind")]
    public string? KindRaw { get; set; }

    /// <summary>
    /// 仅 <see cref="ModuleKind.Dll"/>：IPlugin 实现类全名（如 <c>SystemCleaner.Plugin</c>）。
    /// 缺失时加载器扫描 dll 里所有 IPlugin 实现——恰好一个才加载，多实现拒绝（歧义即错）。
    /// </summary>
    [JsonProperty("typeName")]
    public string? TypeName { get; set; }

    /// <summary>仅 <see cref="ModuleKind.Html"/>：主界面 HTML 相对路径（如 <c>index.html</c>）。</summary>
    [JsonProperty("moduleHtml")]
    public string? ModuleHtml { get; set; }

    /// <summary>仅 <see cref="ModuleKind.Html"/>：设置页 HTML 相对路径（可选）。</summary>
    [JsonProperty("settingsHtml")]
    public string? SettingsHtml { get; set; }

    /// <summary>声明消费的能力族（消费面，ADR-0019 §1；授权判据在 ModuleApiBus 一处）</summary>
    [JsonProperty("capabilities")]
    public List<string> Capabilities { get; set; } = new();

    /// <summary>声明提供的能力（提供面；条目的 provider 必须等于本模块 id）</summary>
    [JsonProperty("provides")]
    public List<string> Provides { get; set; } = new();

    /// <summary>
    /// 挂载形态声明（#708，安装期）：本模块以什么形态出现在宿主里。可多选（如同时是卡片与工具），
    /// 取值见 <see cref="ModuleMounts"/> 白名单（card / background / tool / overlay）。
    /// 缺省（未声明/空）= 不挂任何 UI 面——模块只在被调用（能力提供/命令路由）时活着；
    /// 与「声明了无界面后台」的差别在 <c>background</c>：含它则宿主启动即拉（<c>ModuleBackgroundStarter</c>）。
    /// 未知值保留原样不参与分发（宽松解析，坏一个字段不炸整份清单）。
    /// </summary>
    [JsonProperty("mounts")]
    public List<string> Mounts { get; set; } = new();

    /// <summary>声明接管的旧提供方能力（ADR-0019 §3 / supersede）</summary>
    [JsonProperty("supersedes")]
    public List<string> Supersedes { get; set; } = new();

    /// <summary>图标：模块目录内 .svg 相对路径（推荐；宿主矢量渲染随主题填色）</summary>
    [JsonProperty("icon")]
    public string Icon { get; set; } = "";

    /// <summary>最低宿主版本</summary>
    [JsonProperty("minHostVersion")]
    public string? MinHostVersion { get; set; }

    /// <summary>依赖的宿主模块 API 版本（当前宿主支持 1）</summary>
    [JsonProperty("apiVersion")]
    public int ApiVersion { get; set; } = 1;

    /// <summary>模块所在目录（扫描时填充，不参与序列化）</summary>
    [JsonIgnore]
    public string? SourceDirectory { get; set; }

    /// <summary>
    /// 解析后的挂载形态集合（每次现解析不缓存：清单是小对象、列表通常 0~4 项，
    /// 换取无需线程安全）。未知值记 Debug 日志后跳过。
    /// </summary>
    [JsonIgnore]
    public IReadOnlyList<ModuleMountKind> MountKinds
    {
        get
        {
            var kinds = new List<ModuleMountKind>();
            foreach (var raw in Mounts)
            {
                if (ModuleMounts.TryParse(raw, out var kind)) kinds.Add(kind);
                else Framework.RuntimeLog.Debug("Modules", $"[manifest] {Id}: 未知挂载形态 '{raw}'（忽略）");
            }
            return kinds;
        }
    }

    /// <summary>是否挂了指定形态（各消费点的统一判定入口）。</summary>
    public bool HasMount(ModuleMountKind kind) => MountKinds.Contains(kind);

    /// <summary>
    /// 解析后的运行时形态（#767）：<see cref="KindRaw"/> 命中白名单则用它；
    /// 缺失或未知一律回落 <see cref="ModuleKind.Exe"/>（保持向后兼容——现有 module.json 一字不改也能跑）。
    /// 未知值记 Debug 日志便于排查（与 <see cref="MountKinds"/> 同口径）。
    /// </summary>
    [JsonIgnore]
    public ModuleKind Kind
    {
        get
        {
            if (string.IsNullOrEmpty(KindRaw)) return ModuleKind.Exe;
            if (ModuleKinds.TryParse(KindRaw, out var k)) return k;
            Framework.RuntimeLog.Debug("Modules", $"[manifest] {Id}: 未知 kind '{KindRaw}'（回落 exe）");
            return ModuleKind.Exe;
        }
    }


    /// <summary>按宿主当前语言解析的显示名称（精确匹配 → 区域前缀匹配 → 回落 Name）</summary>
    [JsonIgnore]
    public string DisplayName => Framework.PluginTextI18n.Resolve(NameI18n, Name);

    /// <summary>按宿主当前语言解析的显示描述</summary>
    [JsonIgnore]
    public string DisplayDescription => Framework.PluginTextI18n.Resolve(DescriptionI18n, Description);
}
