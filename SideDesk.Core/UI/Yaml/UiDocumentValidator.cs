using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using YamlDotNet.Serialization;

namespace SideDesk.UI.Yaml;

/// <summary>
/// 卡片声明的**结构级**校验（ADR-0017 §6 的"权威道"）。
///
/// <para><b>与快道（<c>tools/check-ui-yaml.ps1</c>）的分工</b>：快道是 PowerShell 词法扫描，
/// 秒级、防手滑，但**做不到**这几件 —— 因为它不解析 YAML，而手写解析器是 bug 温床、
/// 门禁本身必须可信：</para>
/// <list type="bullet">
/// <item>根对象的**未知键**（宽容解析会让拼错静默生效）</item>
/// <item>「某属性是否属于**该节点**」（词法扫描只知道属性名，不知道它在哪个节点下）</item>
/// <item>叶子节点带 <c>children</c>、容器节点缺 <c>children</c>、<c>Repeat</c> 缺 <c>repeat</c></item>
/// <item><c>if</c> 里出现比较/运算（本 ADR 规定**只允许布尔路径**，计算归后端）</item>
/// <item>版本闸 <c>schema</c>（不认识就拒绝渲染，**不静默降级**）</item>
/// </list>
///
/// <para><b>它也是运行期的那一道</b>：第三方模块的 YAML 不进仓库、静态门禁够不着，
/// 安装/加载时必须用同一份实现再校验。所以本类是产品代码，不是测试夹具。</para>
/// </summary>
public static class UiDocumentValidator
{
    // ---- 根对象与节点对象允许出现的键（其余一律 ERROR）----
    private static readonly HashSet<string> RootKeys = new(StringComparer.Ordinal)
    {
        "schema", "id", "title", "icon", "category", "card",
        "backend", "capabilities", "data", "actions", "body"
    };

    private static readonly HashSet<string> NodeKeys = new(StringComparer.Ordinal)
    {
        "type", "id", "if", "repeat", "props", "bind", "events", "children", "preset"
    };

    // ---- 值契约 ----
    private static readonly Regex RxKeyRef = new(@"^@[A-Za-z0-9_.]+$", RegexOptions.Compiled);
    private static readonly Regex RxPath = new(@"^\{[^}]+\}$", RegexOptions.Compiled);
    private static readonly Regex RxHex = new(@"#[0-9a-fA-F]{3,8}\b", RegexOptions.Compiled);
    private static readonly Regex RxRgb = new(@"\brgba?\s*\(", RegexOptions.Compiled);

    /// <summary>
    /// <c>if</c> 只允许单个布尔路径。<b>禁止比较与运算</b> —— 那不是声明式布局该干的事，
    /// 一旦开口子，YAML 会以肉眼可见的速度长成一门语言（见 ADR-0017 §1）。
    /// </summary>
    private static readonly Regex RxForbiddenInExpr = new(@"[=<>!&|+\-*/()]", RegexOptions.Compiled);

    /// <summary>
    /// 校验一份卡片声明。返回**错误列表**（空 = 通过）。不抛异常 ——
    /// 调用方（运行期加载）需要拿到全部问题而不是第一个。
    /// </summary>
    /// <param name="yamlText">YAML 正文</param>
    /// <param name="reg">节点与令牌注册表</param>
    /// <param name="source">用于报错定位的来源名（文件名或模块 id）</param>
    public static IReadOnlyList<string> Validate(string yamlText, UiRegistries reg, string source)
    {
        var errs = new List<string>();
        object? doc;
        try
        {
            doc = new DeserializerBuilder().Build().Deserialize<object?>(yamlText);
        }
        catch (Exception ex)
        {
            errs.Add($"{source}: YAML 解析失败 —— {ex.Message}");
            return errs;
        }

        if (doc is not IDictionary<object, object?> root)
        {
            errs.Add($"{source}: 根对象必须是映射（键值对）");
            return errs;
        }

        // ① 根对象未知键
        foreach (var k in root.Keys)
        {
            var key = k?.ToString() ?? "";
            if (!RootKeys.Contains(key))
                errs.Add($"{source}: 根对象的未知键 '{key}'（宽容解析会让拼错静默生效）");
        }

        // ② 版本闸
        var schema = Str(root, "schema");
        if (string.IsNullOrEmpty(schema))
            errs.Add($"{source}: 缺少 schema（应为 \"{UiRegistries.DocumentSchema}\"）");
        else if (schema != UiRegistries.DocumentSchema)
            errs.Add($"{source}: 不认识的 schema '{schema}' —— 拒绝渲染，不静默降级");

        // ③ 标题：必须是 @key 或 {path}
        CheckTextSlot(errs, source, "title", Str(root, "title"));

        // ④ 布局树
        if (root.TryGetValue("body", out var body) && body != null)
            WalkNode(errs, reg, source, "body", body);
        else if (body == null)
            errs.Add($"{source}: 缺少 body（布局树根）");

        return errs;
    }

    /// <summary>收集文档里引用到的全部 i18n 键（<c>@domain.key</c>）—— 供"键必须存在于 13 部词典"的字典校验用。</summary>
    public static IReadOnlyCollection<string> CollectTextKeys(string yamlText)
    {
        var keys = new SortedSet<string>(StringComparer.Ordinal);
        object? doc;
        try { doc = new DeserializerBuilder().Build().Deserialize<object?>(yamlText); }
        catch { return Array.Empty<string>(); }
        WalkForKeys(doc, keys);
        return keys;
    }

    private static void WalkForKeys(object? node, SortedSet<string> sink)
    {
        switch (node)
        {
            case IDictionary<object, object?> map:
                foreach (var v in map.Values) WalkForKeys(v, sink);
                break;
            case IEnumerable<object?> list:
                foreach (var v in list) WalkForKeys(v, sink);
                break;
            case string s when RxKeyRef.IsMatch(s):
                sink.Add(s[1..]);
                break;
        }
    }

    // ---------- 节点遍历 ----------

    private static void WalkNode(List<string> errs, UiRegistries reg, string source, string path, object? raw)
    {
        if (raw is not IDictionary<object, object?> node)
        {
            errs.Add($"{source}: {path} 必须是节点映射");
            return;
        }

        foreach (var k in node.Keys)
        {
            var key = k?.ToString() ?? "";
            if (!NodeKeys.Contains(key))
                errs.Add($"{source}: {path} 的未知键 '{key}'");
        }

        // preset 节点（ADR-0022 §3）：无 type；参数键 ⊆ 预设声明、值按声明 kind 校验；
        // children 不允许（骨架归预设定义）。这里判完即 return —— 不走通用 type 校验。
        if (node.TryGetValue("preset", out var presetVal))
        {
            var pname = presetVal?.ToString() ?? "";
            var pHere = $"{path}(preset:{pname})";
            if (!string.IsNullOrEmpty(Str(node, "type")))
                errs.Add($"{source}: {pHere} 的 preset 与 type 同给 —— 预设节点没有 type");
            foreach (var k in node.Keys)
            {
                var key = k?.ToString() ?? "";
                if (key is not ("preset" or "props"))
                    errs.Add($"{source}: {pHere} 的未知键 '{key}'（预设节点只允许 preset/props）");
            }
            if (!reg.Presets.TryGetValue(pname, out var pspec))
            {
                errs.Add($"{source}: {pHere} 的未知预设 '{pname}'");
            }
            else if (node.TryGetValue("props", out var ppRaw) && ppRaw != null)
            {
                if (ppRaw is not IDictionary<object, object?> pps)
                    errs.Add($"{source}: {pHere} 的 props 必须是映射");
                else
                    foreach (var p in pps)
                    {
                        var name2 = p.Key?.ToString() ?? "";
                        if (!pspec.Params.TryGetValue(name2, out var ps2))
                        {
                            errs.Add($"{source}: {pHere} 不支持参数 '{name2}'");
                            continue;
                        }
                        CheckPropValue(errs, reg, source, pHere, name2, ps2, p.Value?.ToString() ?? "");
                    }
            }
            return;
        }

        var type = Str(node, "type");
        if (string.IsNullOrEmpty(type))
        {
            errs.Add($"{source}: {path} 缺少 type");
            return;
        }
        if (!reg.Nodes.TryGetValue(type, out var spec))
        {
            errs.Add($"{source}: {path} 的未知节点类型 '{type}'");
            return;
        }

        var here = $"{path}({type})";

        // 条件只允许布尔路径
        if (node.TryGetValue("if", out var ifv) && ifv != null)
        {
            var expr = ifv.ToString() ?? "";
            if (!RxPath.IsMatch(expr))
                errs.Add($"{source}: {here} 的 if 必须是单个 '{{path}}' —— 拿到 '{expr}'");
            else if (RxForbiddenInExpr.IsMatch(expr[1..^1]))
                errs.Add($"{source}: {here} 的 if 里出现比较/运算 '{expr}' —— 只允许布尔路径，计算归后端");
        }

        // props：键必须属于该节点；值按 kind 校验
        if (node.TryGetValue("props", out var propsRaw) && propsRaw != null)
        {
            if (propsRaw is not IDictionary<object, object?> props)
                errs.Add($"{source}: {here} 的 props 必须是映射");
            else
                foreach (var p in props)
                {
                    var name = p.Key?.ToString() ?? "";
                    if (!spec.Props.TryGetValue(name, out var ps))
                    {
                        errs.Add($"{source}: {here} 不支持属性 '{name}'");
                        continue;
                    }
                    CheckPropValue(errs, reg, source, here, name, ps, p.Value?.ToString() ?? "");
                }
        }

        // style（ADR-0022 §2）：值必须在词表内（注册表 presets.v1.json 的 styles 段）；
        // 与显式 color/size 同给 = ERROR —— 两套来源打架比冗余危险（不宽容解析同哲学）
        if (type == "Text" && propsRaw is IDictionary<object, object?> tprops
            && tprops.TryGetValue("style", out var styleVal))
        {
            var sv = styleVal?.ToString() ?? "";
            if (!reg.Styles.ContainsKey(sv))
                errs.Add($"{source}: {here} 的 style '{sv}' 不在词表内（hint/micro —— 新增需实测配对 ≥3 次，ADR-0022 §2）");
            foreach (var conflict in new[] { "color", "size" })
                if (tprops.TryGetValue(conflict, out var cv) && !string.IsNullOrEmpty(cv?.ToString()))
                    errs.Add($"{source}: {here} 的 style 与显式 '{conflict}' 同给 —— 两套来源打架（ADR-0022 §2）");
        }

        // bind：键必须是该节点声明为可绑定的
        if (node.TryGetValue("bind", out var bindRaw) && bindRaw != null)
        {
            if (bindRaw is not IDictionary<object, object?> binds)
                errs.Add($"{source}: {here} 的 bind 必须是映射");
            else
                foreach (var b in binds)
                {
                    var name = b.Key?.ToString() ?? "";
                    if (!spec.Bindable.Contains(name, StringComparer.Ordinal))
                        errs.Add($"{source}: {here} 的属性 '{name}' 不可绑定");
                    var val = b.Value?.ToString() ?? "";
                    if (!RxPath.IsMatch(val))
                        errs.Add($"{source}: {here} 的 bind.{name} 必须是 '{{path}}' —— 拿到 '{val}'");
                }
        }

        // events：键必须在声明的事件集合里；值只是动作名
        if (node.TryGetValue("events", out var evRaw) && evRaw != null)
        {
            if (evRaw is not IDictionary<object, object?> evs)
                errs.Add($"{source}: {here} 的 events 必须是映射");
            else
                foreach (var e in evs)
                {
                    var name = e.Key?.ToString() ?? "";
                    if (!spec.Events.Contains(name, StringComparer.Ordinal))
                        errs.Add($"{source}: {here} 不支持事件 '{name}'");
                }
        }

        // requires（如 Repeat 必须有 repeat.source / repeat.as）
        if (node.TryGetValue("repeat", out var repRaw) && repRaw != null)
        {
            if (repRaw is not IDictionary<object, object?> rep)
                errs.Add($"{source}: {here} 的 repeat 必须是映射");
            else
                foreach (var need in spec.Required.Where(r => r.StartsWith("repeat:", StringComparison.Ordinal)))
                {
                    var field = need["repeat:".Length..];
                    if (!rep.ContainsKey(field))
                        errs.Add($"{source}: {here} 的 repeat 缺少 '{field}'");
                }
        }
        else if (spec.Required.Any(r => r.StartsWith("repeat:", StringComparison.Ordinal)))
        {
            errs.Add($"{source}: {here} 必须声明 repeat（缺 {string.Join('/', spec.Required)}）");
        }

        // children：容器必须给，叶子必须不给
        var hasChildren = node.TryGetValue("children", out var chRaw) && chRaw != null;
        if (spec.Children && !spec.ChildrenOptional && !hasChildren)
            errs.Add($"{source}: {here} 是容器节点，缺少 children");
        if (!spec.Children && hasChildren)
            errs.Add($"{source}: {here} 是叶子节点，不接受 children");

        if (hasChildren)
        {
            if (chRaw is not IEnumerable<object?> kids)
            {
                errs.Add($"{source}: {here} 的 children 必须是列表");
            }
            else
            {
                var i = 0;
                foreach (var kid in kids) WalkNode(errs, reg, source, $"{here}.children[{i++}]", kid);
            }
        }
    }

    // ---------- 值校验 ----------

    private static void CheckPropValue(List<string> errs, UiRegistries reg, string source,
                                       string where, string name, PropSpec spec, string value)
    {
        // 绑定与键引用对任何 kind 都合法（值在运行期才定）
        var isBinding = RxPath.IsMatch(value);
        var isKey = RxKeyRef.IsMatch(value);

        // 反正是字面量的场合，先挡颜色（顺带补 fast lane 之外的纵深）
        if (!isBinding && (RxHex.IsMatch(value) || RxRgb.IsMatch(value)))
            errs.Add($"{source}: {where}.{name} 出现颜色字面量 '{value}'（改用 tokens.v1.json 的语义名）");

        switch (spec.Kind)
        {
            case "textToken":
                if (!isBinding && !isKey)
                    errs.Add($"{source}: {where}.{name} 必须是 '@key' 或 '{{path}}' —— 拿到 '{value}'");
                break;

            case "colorToken":
                CheckToken(errs, reg, source, where, name, "brush", value, isBinding);
                break;
            case "sizeToken":
                CheckToken(errs, reg, source, where, name, "font", value, isBinding);
                break;
            case "radiusToken":
                CheckToken(errs, reg, source, where, name, "radius", value, isBinding);
                break;

            case "bool":
                if (!isBinding && value != "true" && value != "false")
                    errs.Add($"{source}: {where}.{name} 必须是 true/false —— 拿到 '{value}'");
                break;

            case "choice":
                if (!isBinding && !spec.Choices.Contains(value, StringComparer.Ordinal))
                    errs.Add($"{source}: {where}.{name} 的值 '{value}' 不在白名单 [{(spec.Choices.Count == 0 ? "未声明" : string.Join('/', spec.Choices))}]");
                break;

            case "number":
                if (!isBinding && !double.TryParse(value, System.Globalization.NumberStyles.Float,
                                                   System.Globalization.CultureInfo.InvariantCulture, out _))
                    errs.Add($"{source}: {where}.{name} 必须是数值 —— 拿到 '{value}'");
                break;

            case "any":
                break;

            // glyph 是**唯一允许字面量**的文本槽位（图标不翻译，ADR-0017 §3）。
            // 有意不做任何检查 —— 加了检查就等于给图标槽位塞进 i18n 约束，与 ADR 相悖。
            case "glyph":
                break;

            // 对齐：绑定或白名单之一（与 choice 同形，但取值表在注册表外，所以单列一个 kind）
            case "align":
                if (!isBinding && value is not ("left" or "center" or "right" or "stretch"))
                    errs.Add($"{source}: {where}.{name} 的水平对齐 '{value}' 不在 [left/center/right/stretch]");
                break;

            case "alignV":
                if (!isBinding && value is not ("top" or "center" or "bottom" or "stretch"))
                    errs.Add($"{source}: {where}.{name} 的垂直对齐 '{value}' 不在 [top/center/bottom/stretch]");
                break;

            case "textAlign":
                if (!isBinding && value is not ("left" or "center" or "right" or "justify"))
                    errs.Add($"{source}: {where}.{name} 的文本对齐 '{value}' 不在 [left/center/right/justify]");
                break;

            // 边距：单个数字（四边相同）或 "左,上,右,下"
            case "thickness":
                if (!isBinding && !IsThickness(value))
                    errs.Add($"{source}: {where}.{name} 的边距 '{value}' 不是数字或 '左,上,右,下'");
                break;

            // 列宽：单个数字（等宽列数）或 "52,auto,*"
            case "columnSpec":
                if (!isBinding && !IsColumnSpec(value))
                    errs.Add($"{source}: {where}.{name} 的列宽 '{value}' 不是数字或 '数字|auto|*' 的逗号列表");
                break;

            default:
                errs.Add($"{source}: {where}.{name} 的 kind '{spec.Kind}' 不在 propKinds 里（注册表有问题）");
                break;
        }
    }

    /// <summary>单个数字或恰好四段的数字列表</summary>
    private static bool IsThickness(string v)
    {
        var parts = v.Split(',');
        if (parts.Length == 1) return IsNum(parts[0]);
        if (parts.Length != 4) return false;
        foreach (var p in parts) if (!IsNum(p)) return false;
        return true;
    }

    /// <summary>单个数字，或每段是 数字/auto/* 的逗号列表</summary>
    private static bool IsColumnSpec(string v)
    {
        var parts = v.Split(',');
        if (parts.Length == 1 && IsNum(parts[0])) return true;
        if (parts.Length < 2) return false;
        foreach (var p in parts)
        {
            var t = p.Trim();
            if (t != "auto" && t != "*" && !IsNum(t)) return false;
        }
        return true;
    }

    private static bool IsNum(string s) =>
        double.TryParse(s.Trim(), System.Globalization.NumberStyles.Float,
                        System.Globalization.CultureInfo.InvariantCulture, out _);

    private static void CheckToken(List<string> errs, UiRegistries reg, string source,
                                   string where, string name, string kind, string value, bool isBinding)
    {
        if (isBinding) return;
        if (!reg.IsToken(kind, value))
            errs.Add($"{source}: {where}.{name} 的值 '{value}' 不是 {kind} 语义名（见 tokens.v1.json）");
    }

    private static void CheckTextSlot(List<string> errs, string source, string name, string? value)
    {
        if (value == null) return;
        if (!RxKeyRef.IsMatch(value) && !RxPath.IsMatch(value))
            errs.Add($"{source}: {name} 必须是 '@key' 或 '{{path}}' —— 拿到 '{value}'");
    }

    private static string? Str(IDictionary<object, object?> map, string key) =>
        map.TryGetValue(key, out var v) ? v?.ToString() : null;
}
