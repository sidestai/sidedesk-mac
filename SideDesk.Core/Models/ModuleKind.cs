namespace SideDesk.Models;

using System;
using System.Collections.Generic;

/// <summary>
/// 模块**运行时形态**（<c>module.json</c> 的 <c>kind</c> 字段，#767）：**安装期**声明"这个模块
/// 底下是怎么跑的"，宿主按 kind 分派到三套加载器之一——运行时架构不动，只是清单层压平。
///
/// <para>与 <see cref="ModuleMountKind"/>（挂载形态）正交：kind 说"怎么加载"，mounts 说"挂到哪"。
/// 三 kind 都可以搭四种 mounts（受各自加载器能力约束，比如 dll 与 html 目前不支持 tool/overlay
/// 的 sideui/v1 声明流）。</para>
///
/// <para><b>为什么需要</b>：老 <c>plugin.json</c> 与新 <c>module.json</c> 双轨并存——插件作者要
/// 学两套字段、宿主要维护两套扫描点、门禁要同时读两个文件名。清单层统一到 <c>module.json</c>
/// + <c>kind</c> 字段后，作者视角只有一份规范，宿主分派点集中在一处。</para>
///
/// <para>与 <c>tools/check-module-manifest.ps1</c> 的 kind 白名单同源两实现（ADR-0019 §5 口径：
/// 静态查仓库里的、运行时查装进来的）——改枚举必须同步门禁白名单。</para>
/// </summary>
public enum ModuleKind
{
    /// <summary>
    /// 独立进程 sidecar（新模块系统，NDJSON/JSON-RPC 协议）——**缺省值**。
    /// <see cref="ModuleManifest.Entry"/> 是可执行文件名（相对模块目录）。
    /// </summary>
    Exe,

    /// <summary>
    /// 宿主进程内 .NET DLL（老 native 插件系统）：<c>Assembly.LoadFrom</c> + 反射 <c>IPlugin</c>。
    /// <see cref="ModuleManifest.Entry"/> 是 dll 文件名；<see cref="ModuleManifest.TypeName"/> 可选
    /// （缺失时扫描 dll 里所有 IPlugin 实现，多实现则拒绝加载）。
    /// </summary>
    Dll,

    /// <summary>
    /// WebView2 沙箱 HTML 插件（老 html 插件系统）。
    /// <see cref="ModuleManifest.ModuleHtml"/> / <see cref="ModuleManifest.SettingsHtml"/> 至少有一个。
    /// </summary>
    Html,
}

/// <summary>
/// <c>kind</c> 字段的字符串白名单与解析。清单是第三方 JSON，宿主侧**宽松解析**：
/// 未知值不炸反序列化（保留在 <see cref="ModuleManifest.KindRaw"/> 原样），只回落到 <see cref="ModuleKind.Exe"/>
/// 并记日志——坏一个字段不能让整份清单失效（与 <see cref="ModuleMounts"/> 同一哲学）。
/// </summary>
public static class ModuleKinds
{
    /// <summary>独立进程 sidecar 的清单字符串（缺省）</summary>
    public const string Exe = "exe";

    /// <summary>宿主进程内 .NET DLL 的清单字符串</summary>
    public const string Dll = "dll";

    /// <summary>WebView2 沙箱 HTML 插件的清单字符串</summary>
    public const string Html = "html";

    /// <summary>清单字符串 → 枚举（ordinal 精确匹配，大小写敏感与门禁一致）</summary>
    private static readonly Dictionary<string, ModuleKind> ParseTable = new(StringComparer.Ordinal)
    {
        [Exe] = ModuleKind.Exe,
        [Dll] = ModuleKind.Dll,
        [Html] = ModuleKind.Html,
    };

    /// <summary>解析单个 kind 字符串（未知/空 = false）。</summary>
    public static bool TryParse(string? raw, out ModuleKind kind)
    {
        kind = default;
        if (string.IsNullOrEmpty(raw)) return false;
        return ParseTable.TryGetValue(raw, out kind);
    }

    /// <summary>枚举 → 清单字符串（白名单的逆向表；生成 JSON / 测试夹具用）。</summary>
    public static string ToToken(ModuleKind kind) => kind switch
    {
        ModuleKind.Exe => Exe,
        ModuleKind.Dll => Dll,
        ModuleKind.Html => Html,
        _ => "",
    };

    /// <summary>
    /// 从 <c>plugin.json</c> 内容推断 kind（兼容读取时用；#767 三步走的第 1 步）：
    /// 有 <c>mode: "html"</c> → html；<c>entry</c> 后缀 <c>.dll</c> → dll；否则 → exe。
    /// 显式 <c>kind</c> 字段永远优先——推断只在缺失时兜底。
    /// </summary>
    public static ModuleKind Infer(string? modeField, string? entryField)
    {
        if (string.Equals(modeField, "html", StringComparison.Ordinal)) return ModuleKind.Html;
        if (!string.IsNullOrEmpty(entryField) &&
            entryField.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)) return ModuleKind.Dll;
        return ModuleKind.Exe;
    }
}
