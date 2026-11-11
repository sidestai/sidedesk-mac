using System;
using System.IO;
using AppKit;
using SideDesk.UI.Yaml;

namespace SpikeNspanel.SideUi;

/// <summary>
/// 卡片宿主（对应 Windows 的 <c>UiCardHost</c>，去掉 <c>Framework.Lang</c>/<c>RuntimeLog</c> 依赖，
/// 用 Console 桩）。职责：加载注册表（单例）→ 读卡片 YAML → 校验（fail-closed）→ 解析 → 渲染成 NSView。
/// </summary>
internal static class UiCardHostMac
{
    private static UiRegistries? _registries;

    /// <summary>
    /// 定位 <c>resources/ui</c> 目录。不同运行方式的 <c>AppContext.BaseDirectory</c> 不同
    /// （松散 dll = 输出目录；.app = Contents/MacOS 或 Contents/MonoBundle），而 Core 的
    /// <c>CopyToOutputDirectory</c> 只把资源放到松散输出目录。故从 BaseDirectory 起逐级上溯探测，
    /// 命中第一个含 <c>resources/ui/nodes.v1.json</c> 的目录。
    /// </summary>
    private static string UiDir
    {
        get
        {
            var probe = new DirectoryInfo(AppContext.BaseDirectory);
            for (var i = 0; i < 6 && probe != null; i++, probe = probe.Parent)
            {
                var candidate = Path.Combine(probe.FullName, "resources", "ui");
                if (File.Exists(Path.Combine(candidate, "nodes.v1.json"))) return candidate;
            }
            throw new DirectoryNotFoundException(
                $"找不到 resources/ui（从 {AppContext.BaseDirectory} 上溯 6 级均未命中 nodes.v1.json）");
        }
    }

    private static string CardsDir => Path.Combine(UiDir, "cards");

    /// <summary>注册表单例（从 <c>{BaseDirectory}/resources/ui</c> 加载；缺失即抛，不回落空表）。</summary>
    public static UiRegistries Registries => _registries ??= UiRegistries.Load(UiDir);

    /// <summary>
    /// 渲染一张卡片为 NSView。校验不通过或解析失败返回 null 并给出 <paramref name="reason"/>（不抛 ——
    /// 一张坏卡片不该让整个面板崩）。
    /// </summary>
    public static NSView? Build(string id, IUiDataSource? data, IUiActionHost? actions, out string reason)
    {
        reason = "";
        var path = Path.Combine(CardsDir, id + ".yaml");
        if (!File.Exists(path)) { reason = $"卡片文件不存在：{path}"; return null; }

        var yaml = File.ReadAllText(path);
        var reg = Registries;

        var errors = UiDocumentValidator.Validate(yaml, reg, id);
        if (errors.Count > 0) { reason = "校验失败：\n  " + string.Join("\n  ", errors); return null; }

        var doc = UiDocumentLoader.Load(yaml, id, out var loadErrors);
        if (doc == null) { reason = "解析失败：\n  " + string.Join("\n  ", loadErrors); return null; }

        return UiRendererMac.Build(doc, reg, data, actions);
    }
}
