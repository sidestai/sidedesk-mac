using System;
using System.Collections.Generic;
using System.Linq;
using YamlDotNet.Serialization;

namespace SideDesk.UI.Yaml;

/// <summary>
/// 解析后的卡片声明（ADR-0017）。<b>这是渲染器的输入</b>，与 <see cref="UiDocumentValidator"/> 的分工是：
/// 校验器回答"这份声明合不合法"（返回**全部**错误），加载器回答"把它变成可渲染的树"。
///
/// <para><b>为什么会有两次遍历</b>：校验要在渲染前 fail-closed 且要一次报全部问题；
/// 加载只关心结构。两者共用同一份 YAML 对象图（都是 YamlDotNet 的
/// <c>IDictionary&lt;object,object?&gt;</c> 形状），合并成一次是 P2 的事 ——
/// 现在的重复是 ~40 行，换"校验与加载各司其职"，值得。</para>
///
/// <para><b>值一律是字符串</b>（已实测）：YamlDotNet 的 <c>Deserialize&lt;object?&gt;</c> 对普通标量返回
/// <c>string</c> —— <c>spacing: 6</c> 得到 <c>"6"</c>、<c>wrap: true</c> 得到 <c>"true"</c>（**不是** <c>True</c>）。
/// 所以下面的取值不做类型推断，需要数值/布尔的消费者自己 parse。</para>
/// </summary>
public sealed class UiDocument
{
    public required string Id { get; init; }
    public required string Title { get; init; }
    public required UiNode Root { get; init; }
    /// <summary>声明来源（文件名或模块 id），仅用于报错与日志定位</summary>
    public required string Source { get; init; }
}

/// <summary>布局树上的一个节点。<paramref name="Bind"/> 的值是 <c>{path}</c>（已去掉花括号）。</summary>
public sealed record UiNode(
    string Type,
    IReadOnlyDictionary<string, string> Props,
    IReadOnlyDictionary<string, string> Bind,
    IReadOnlyDictionary<string, string> Events,
    IReadOnlyList<UiNode> Children,
    string? If,
    string? RepeatSource = null,
    string? RepeatAs = null);

public static class UiDocumentLoader
{
    /// <summary>根对象的已知键 —— 与 <see cref="UiDocumentValidator"/> 的 RootKeys 同源（那里是权威判据）。</summary>
    private const string BodyKey = "body";

    /// <summary>
    /// 解析一份声明。失败返回 <c>null</c> 并给出错误列表（**不抛异常** —— 调用方是运行期加载路径，
    /// 一个坏卡片不该让整个面板树崩掉）。调用前应先用 <see cref="UiDocumentValidator"/> 校验。
    /// </summary>
    public static UiDocument? Load(string yamlText, string source, out IReadOnlyList<string> errors)
    {
        var errs = new List<string>();
        errors = errs;

        object? doc;
        try { doc = new DeserializerBuilder().Build().Deserialize<object?>(yamlText); }
        catch (Exception ex) { errs.Add($"{source}: YAML 解析失败 —— {ex.Message}"); return null; }

        if (doc is not IDictionary<object, object?> root)
        {
            errs.Add($"{source}: 根对象必须是映射");
            return null;
        }

        var id = Str(root, "id") ?? "";
        var title = Str(root, "title") ?? "";

        if (!root.TryGetValue(BodyKey, out var body) || body is not IDictionary<object, object?>)
        {
            errs.Add($"{source}: 缺少 body（布局树根）或 body 不是映射");
            return null;
        }

        var node = Convert(body, source, BodyKey, errs);
        if (node == null) return null;

        return new UiDocument { Id = id, Title = title, Root = node, Source = source };
    }

    private static UiNode? Convert(object? raw, string source, string path, List<string> errs)
    {
        if (raw is not IDictionary<object, object?> m)
        {
            errs.Add($"{source}: {path} 必须是节点映射");
            return null;
        }

        var type = Str(m, "type") ?? "";
        // preset 节点（ADR-0022 §3）：无 type，带 `preset: <名字>` + 参数 props。
        // 内部类型名固定 "Preset"，预设名放 props["preset"] —— 校验器按 PresetSpec.Params 判，
        // 渲染器展开成骨架树后走普通分派。参数义务（未知名/多键/children）归校验器。
        if (type.Length == 0 && m.TryGetValue("preset", out var pv) && pv?.ToString() is { Length: > 0 } pname)
        {
            var pprops = Scalars(m, "props");
            pprops["preset"] = pname;
            return new UiNode("Preset", pprops,
                new Dictionary<string, string>(), new Dictionary<string, string>(),
                new List<UiNode>(), null);
        }
        if (type.Length == 0)
        {
            errs.Add($"{source}: {path} 缺少 type");
            return null;
        }

        var props = Scalars(m, "props");
        var binds = Scalars(m, "bind");
        var events = Scalars(m, "events");

        // repeat: { source, as } —— 集合展开。两个字段的**义务**由校验器按注册表的 requires 判，
        // 这里只取值（缺了就是 null，校验器会拒）。
        string? repSource = null, repAs = null;
        if (m.TryGetValue("repeat", out var repRaw) && repRaw is IDictionary<object, object?> rep)
        {
            repSource = rep.TryGetValue("source", out var s) ? s?.ToString() : null;
            repAs = rep.TryGetValue("as", out var a) ? a?.ToString() : null;
        }

        // bind 的值形如 "{a.b}" —— 去掉花括号，越界/空值留给校验器报（这里静默丢弃即可）
        var bindPaths = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (k, v) in binds)
        {
            if (v.Length >= 2 && v[0] == '{' && v[^1] == '}') bindPaths[k] = v[1..^1];
            else bindPaths[k] = v;   // 非法形态：保留原值，渲染期取不到就退化成空
        }

        var children = new List<UiNode>();
        if (m.TryGetValue("children", out var chRaw) && chRaw is IEnumerable<object?> kids)
        {
            var i = 0;
            foreach (var kid in kids)
            {
                var child = Convert(kid, source, $"{path}.children[{i++}]", errs);
                if (child != null) children.Add(child);
            }
        }

        // if 与 bind 同款：路径存**剥掉花括号**的形态（渲染器 Resolve 直接用）。
        // 首次真实使用（屏幕时长卡的空态分支）才暴露：P2 实现 if 时直接存了原始串，
        // Resolve 收到 "{st.hasRows}" 永远查不到 —— 校验器验的是形态、模型存的是原串，
        // 两头都对，只有中间这一层漏了。
        var ifPath = Str(m, "if");
        if (ifPath is { Length: >= 2 } brace && brace[0] == '{' && brace[^1] == '}') ifPath = brace[1..^1];
        return new UiNode(type, props, bindPaths, events, children, ifPath, repSource, repAs);
    }

    /// <summary>取一个子映射的标量键值对（如 props / bind / events）</summary>
    private static Dictionary<string, string> Scalars(IDictionary<object, object?> m, string key)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        if (m.TryGetValue(key, out var raw) && raw is IDictionary<object, object?> sub)
            foreach (var p in sub)
                result[p.Key?.ToString() ?? ""] = p.Value?.ToString() ?? "";
        return result;
    }

    private static string? Str(IDictionary<object, object?> m, string key) =>
        m.TryGetValue(key, out var v) ? v?.ToString() : null;

    /// <summary>供渲染器与测试共用的<b>节点遍历</b>（前序）。</summary>
    public static IEnumerable<UiNode> Walk(UiNode node)
    {
        yield return node;
        foreach (var c in node.Children)
            foreach (var n in Walk(c))
                yield return n;
    }
}
