using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Newtonsoft.Json.Linq;

namespace SideDesk.UI.Yaml;

/// <summary>
/// 节点与令牌注册表（ADR-0017 §2）的**运行期视图**：读 <c>resources/ui/nodes.v1.json</c>
/// 与 <c>tokens.v1.json</c>。
///
/// <para><b>为什么是产品代码而不是测试夹具</b>：第三方模块提交的 YAML 不进仓库，
/// 静态门禁够不着它 —— 运行期必须按**同一份**注册表再校验一次。CI 与运行期共用本类，
/// 是"注册表是唯一判据源"这句的落实方式。</para>
///
/// <para>加载失败（文件缺失/损坏）**抛异常**而不是回落空表：空表会让所有 YAML
/// 都因"未知节点"被拒，症状离现场很远。宁可启动时大声失败。</para>
/// </summary>
public sealed class UiRegistries
{
    /// <summary>YAML 声明的版本闸；不认识的值一律拒绝渲染，不静默降级</summary>
    public const string DocumentSchema = "sideui/v1";

    private readonly Dictionary<string, NodeSpec> _nodes;
    private readonly Dictionary<string, HashSet<string>> _tokens;
    private readonly Dictionary<string, Dictionary<string, string>> _tokenKeys;
    private readonly Dictionary<string, string> _defaults;
    private readonly Dictionary<string, IReadOnlyDictionary<string, string>> _styles;
    private readonly Dictionary<string, PresetSpec> _presets;

    public IReadOnlyDictionary<string, NodeSpec> Nodes => _nodes;

    /// <summary>
    /// 布局预设（ADR-0022 §3，presets 段）：参数声明 + 骨架树。**载入期校验骨架** ——
    /// 骨架里的节点类型/属性/token 引用违约即在 Load 时抛（与"加载失败大声失败"同哲学），
    /// 渲染期展开因此不必再防残废骨架。
    /// </summary>
    public IReadOnlyDictionary<string, PresetSpec> Presets => _presets;

    /// <summary>
    /// 属性默认值（ADR-0022 §1，presets.v1.json 的 defaults 段，键形如 <c>"Text.size"</c>）。
    /// **渲染器取默认只走这里** —— C# 里不出现默认值字面量，G7 lint 与渲染器同判据。
    /// 查不到 = 该槽位无默认（Button/Toggle 的隐式样式口子，UiValueSlots 的 null 语义保持）。
    /// </summary>
    public string? DefaultFor(string type, string prop) =>
        _defaults.TryGetValue($"{type}.{prop}", out var v) ? v : null;

    /// <summary>语义样式类（ADR-0022 §2，styles 段）：名字 → 属性展开表（如 hint → {color,size}）。</summary>
    public IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> Styles => _styles;

    /// <summary>按 token 类别取语义名集合（<c>brush</c> / <c>color</c> / <c>font</c> / <c>radius</c>）</summary>
    public IReadOnlyCollection<string> TokensOf(string kind) =>
        _tokens.TryGetValue(kind, out var set) ? set : Array.Empty<string>();

    /// <summary>
    /// 语义名 → 主题资源键（如 <c>brush</c> + <c>text.muted</c> → <c>BrushTextMuted</c>）。
    /// <b>渲染器取色只走这里</b> —— 于是代码里连一个 <c>"BrushTextMuted"</c> 字面量都不出现，
    /// 满足 <c>check-theme-coupling</c> 的「新文件耦合额度为 0」（ADR-0017 §4）。
    ///
    /// <para><c>brush</c> 段查不到时会回落到 <c>constant</c> 段（随包常量，见 tokens.v1.json）。
    /// 回落只给颜色槽位 —— 常量是颜色，不该出现在字号/圆角槽位里。</para>
    /// </summary>
    public string? ResourceKey(string kind, string name) => ResourceKeyCore(kind, name);

    private string? ResourceKeyCore(string kind, string name)
    {
        if (_tokenKeys.TryGetValue(kind, out var map) && map.TryGetValue(name, out var key)) return key;
        if (kind == "brush" && _tokenKeys.TryGetValue("constant", out var c) && c.TryGetValue(name, out var ck))
            return ck;
        return null;
    }

    /// <summary>
    /// 语义名是否合法（校验器用）。颜色槽位额外接受 <c>constant</c> 段的名字 ——
    /// 这与渲染器的回落规则**必须一致**，否则会出现"校验过了但渲染时查不到键"。
    /// </summary>
    public bool IsToken(string kind, string name) => ResourceKeyCore(kind, name) != null;

    /// <summary>注册表里出现过的全部属性名（props ∪ bindable）—— 用于"拼错的属性名"检测</summary>
    public IReadOnlyCollection<string> AllPropNames { get; }

    private UiRegistries(Dictionary<string, NodeSpec> nodes,
                         Dictionary<string, HashSet<string>> tokens,
                         Dictionary<string, Dictionary<string, string>> tokenKeys,
                         Dictionary<string, string> defaults,
                         Dictionary<string, IReadOnlyDictionary<string, string>> styles,
                         Dictionary<string, PresetSpec> presets)
    {
        _nodes = nodes;
        _tokens = tokens;
        _tokenKeys = tokenKeys;
        _defaults = defaults;
        _styles = styles;
        _presets = presets;
        AllPropNames = nodes.Values
            .SelectMany(n => n.Props.Keys.Concat(n.Bindable))
            .ToHashSet(StringComparer.Ordinal);
    }

    /// <summary>从 ui 资源目录加载（通常 <c>{BaseDirectory}/resources/ui</c>）。</summary>
    public static UiRegistries Load(string uiResourceDir)
    {
        var nodes = ParseNodes(File.ReadAllText(Path.Combine(uiResourceDir, "nodes.v1.json")));
        var tokens = ParseTokens(File.ReadAllText(Path.Combine(uiResourceDir, "tokens.v1.json")),
                                 out var tokenKeys);
        var (defaults, styles, presets) = ParsePresets(File.ReadAllText(Path.Combine(uiResourceDir, "presets.v1.json")), nodes, tokenKeys);
        return new UiRegistries(nodes, tokens, tokenKeys, defaults, styles, presets);
    }

    /// <summary>预设：参数声明（名 → kind）+ 骨架树（展开产物）。</summary>
    public sealed record PresetSpec(string Name,
        IReadOnlyDictionary<string, PropSpec> Params, UiNode Skeleton);

    /// <summary>
    /// presets.v1.json 的 defaults / styles / presets 三段。骨架在载入期校验：
    /// 节点类型 ∈ nodes 注册表、属性 ∈ 该节点声明、占位符 {p} 必须引用已声明参数、
    /// token 槽位的非占位符值必须是合法语义名 —— 违约抛，不静默。
    /// </summary>
    private static (Dictionary<string, string> Defaults,
                    Dictionary<string, IReadOnlyDictionary<string, string>> Styles,
                    Dictionary<string, PresetSpec> Presets) ParsePresets(
        string json, Dictionary<string, NodeSpec> nodes,
        Dictionary<string, Dictionary<string, string>> tokenKeys)
    {
        var root = JObject.Parse(json);
        var defaults = new Dictionary<string, string>(StringComparer.Ordinal);
        if (root["defaults"] is JObject d)
            foreach (var p in d)
                defaults[p.Key] = (string?)p.Value ?? "";

        var styles = new Dictionary<string, IReadOnlyDictionary<string, string>>(StringComparer.Ordinal);
        if (root["styles"] is JObject s)
            foreach (var p in s)
            {
                var map = new Dictionary<string, string>(StringComparer.Ordinal);
                if (p.Value is JObject spec)
                    foreach (var q in spec)
                        map[q.Key] = (string?)q.Value ?? "";
                styles[p.Key] = map;
            }

        var presets = new Dictionary<string, PresetSpec>(StringComparer.Ordinal);
        if (root["presets"] is JObject ps)
            foreach (var p in ps)
            {
                var o = (JObject?)p.Value ?? throw new InvalidOperationException($"预设 {p.Key} 的定义必须是对象");
                var paramSpecs = new Dictionary<string, PropSpec>(StringComparer.Ordinal);
                if (o["params"] is JObject pm)
                    foreach (var q in pm)
                    {
                        var kind = q.Value is JObject jo ? (string?)jo["kind"] ?? "" : (string?)q.Value ?? "";
                        paramSpecs[q.Key] = new PropSpec(kind, Array.Empty<string>());
                    }
                var skeleton = JsonToNode((JObject)o["expand"]!, p.Key);
                ValidateSkeleton(p.Key, paramSpecs, skeleton, nodes, tokenKeys);
                presets[p.Key] = new PresetSpec(p.Key, paramSpecs, skeleton);
            }
        return (defaults, styles, presets);
    }

    /// <summary>预设骨架 JSON → UiNode（v1 骨架只含 type/props/children；if/repeat 不进骨架，ADR-0022 未决）。</summary>
    private static UiNode JsonToNode(JObject o, string preset)
    {
        var props = new Dictionary<string, string>(StringComparer.Ordinal);
        if (o["props"] is JObject po)
            foreach (var q in po)
                props[q.Key] = (string?)q.Value ?? "";
        var children = new List<UiNode>();
        if (o["children"] is JArray ca)
            foreach (var c in ca)
                children.Add(JsonToNode((JObject)c!, preset));
        return new UiNode((string?)o["type"] ?? "", props,
            new Dictionary<string, string>(), new Dictionary<string, string>(), children, null);
    }

    private static void ValidateSkeleton(string preset, Dictionary<string, PropSpec> paramSpecs,
        UiNode skeleton, Dictionary<string, NodeSpec> nodes,
        Dictionary<string, Dictionary<string, string>> tokenKeys)
    {
        [System.Diagnostics.CodeAnalysis.DoesNotReturn]
        void Fail(string msg) => throw new InvalidOperationException($"预设 {preset} 骨架违约：{msg}");

        void Walk(UiNode n)
        {
            if (!nodes.TryGetValue(n.Type, out var spec))
                Fail($"节点类型 '{n.Type}' 不在 nodes.v1.json");
            else
                foreach (var kv in n.Props)
                {
                    if (!spec.Props.TryGetValue(kv.Key, out var ps))
                        Fail($"节点 {n.Type} 不支持属性 '{kv.Key}'");
                    // 整值占位符 {{p}}：任何槽位都必须引用已声明参数（text 槽位也一样，别漏）
                    if (kv.Value.Length >= 2 && kv.Value[0] == '{' && kv.Value[^1] == '}')
                    {
                        if (!paramSpecs.ContainsKey(kv.Value[1..^1]))
                            Fail($"占位符 {{{kv.Value[1..^1]}}} 引用未声明参数");
                        continue;
                    }
                    // token 类槽位的非占位符值必须是合法语义名（brush 含 constant 回落，与 ResourceKey 同判据）
                    if (ps.Kind == "colorToken" && !IsLegalToken(tokenKeys, "brush", kv.Value))
                        Fail($"节点 {n.Type}.{kv.Key} 的 '{kv.Value}' 不是合法颜色语义名");
                    if (ps.Kind == "sizeToken" && !IsLegalToken(tokenKeys, "font", kv.Value))
                        Fail($"节点 {n.Type}.{kv.Key} 的 '{kv.Value}' 不是合法字号语义名");
                }
            foreach (var c in n.Children) Walk(c);
        }
        Walk(skeleton);
    }

    private static bool IsLegalToken(Dictionary<string, Dictionary<string, string>> tokenKeys, string kind, string name)
    {
        if (tokenKeys.TryGetValue(kind, out var m) && m.ContainsKey(name)) return true;
        return kind == "brush" && tokenKeys.TryGetValue("constant", out var c) && c.ContainsKey(name);
    }

    // ---------- 解析 ----------

    private static Dictionary<string, NodeSpec> ParseNodes(string json)
    {
        var root = JObject.Parse(json);
        var result = new Dictionary<string, NodeSpec>(StringComparer.Ordinal);
        foreach (var p in (JObject)root["nodes"]!)
        {
            var props = new Dictionary<string, PropSpec>(StringComparer.Ordinal);
            if (p.Value?["props"] is JObject propsObj)
            {
                foreach (var q in propsObj)
                {
                    // 值有两种形状：字符串（kind 名）或 { kind, values }
                    if (q.Value is JObject spec)
                    {
                        var kind = (string?)spec["kind"] ?? "";
                        var choices = (spec["values"] as JArray)?.Select(v => (string?)v ?? "").ToArray()
                                      ?? Array.Empty<string>();
                        props[q.Key] = new PropSpec(kind, choices);
                    }
                    else
                    {
                        props[q.Key] = new PropSpec((string?)q.Value ?? "", Array.Empty<string>());
                    }
                }
            }
            var bindable = (p.Value?["bindable"] as JObject)?.Properties().Select(x => x.Name).ToArray()
                           ?? Array.Empty<string>();
            var events = (p.Value?["events"] as JArray)?.Select(v => (string?)v ?? "").ToArray()
                         ?? Array.Empty<string>();
            var required = (p.Value?["requires"] as JObject)?.Properties()
                           .SelectMany(x => (x.Value as JArray)?.Select(v => $"{x.Name}:{(string?)v}") ?? Enumerable.Empty<string>())
                           .ToArray() ?? Array.Empty<string>();
            result[p.Key] = new NodeSpec(
                p.Key, props, bindable, events,
                Children: p.Value?["children"]?.Value<bool>() ?? false,
                Required: required,
                // 容器但**子元素可选**（如 Box 的纯色块/占位格）。默认 false = 容器必须有子元素。
                ChildrenOptional: p.Value?["childrenOptional"]?.Value<bool>() ?? false);
        }
        return result;
    }

    private static Dictionary<string, HashSet<string>> ParseTokens(
        string json, out Dictionary<string, Dictionary<string, string>> keys)
    {
        var root = JObject.Parse(json);
        var result = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
        keys = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
        foreach (var section in new[] { "brush", "color", "font", "radius", "constant", "style", "other" })
        {
            if (root[section] is not JObject obj) continue;
            result[section] = obj.Properties().Select(x => x.Name).ToHashSet(StringComparer.Ordinal);
            keys[section] = obj.Properties().ToDictionary(x => x.Name, x => (string?)x.Value ?? "",
                                                         StringComparer.Ordinal);
        }
        return result;
    }
}

/// <summary>一个节点类型的声明（来自 <c>nodes.v1.json</c>）</summary>
public sealed record NodeSpec(
    string Type,
    IReadOnlyDictionary<string, PropSpec> Props,
    IReadOnlyCollection<string> Bindable,
    IReadOnlyCollection<string> Events,
    bool Children,
    IReadOnlyCollection<string> Required,
    bool ChildrenOptional = false);

/// <summary>一个属性的值契约。<paramref name="Kind"/> 取 <c>nodes.v1.json</c> 的 propKinds</summary>
public sealed record PropSpec(string Kind, IReadOnlyCollection<string> Choices);
