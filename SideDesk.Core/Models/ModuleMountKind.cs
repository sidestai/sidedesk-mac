namespace SideDesk.Models;

using System.Collections.Generic;

/// <summary>
/// 模块挂载形态（module.json 的 <c>mounts</c> 字段，#708）：**安装期**声明"这个模块以什么形态
/// 出现在宿主里"，与**运行时**声明（<c>ui.declare</c>）分工——mounts 决定挂载点与激活策略，
/// ui.declare 决定界面具体长什么样。
///
/// <para>形态之间不互斥（数组多选），激活策略按形态分流：卡片懒激活挂卡片首次渲染，
/// 后台模块宿主启动即拉，工具/悬浮挂各自容器的首次打开。缺省（未声明 mounts）= 不挂任何
/// UI 面，模块只在被调用（能力提供/命令路由）时活着——"没声明"与"声明了无界面"因此可分。</para>
///
/// <para>与 <c>tools/check-module-manifest.ps1</c> 的 mounts 判据同源两实现（ADR-0019 §5 口径：
/// 静态查仓库里的、运行时查装进来的）——改枚举必须同步门禁白名单。</para>
/// </summary>
public enum ModuleMountKind
{
    /// <summary>卡片：可添加到左侧卡片流（PanelType.ModuleUi；懒激活挂卡片首次渲染）</summary>
    Card,

    /// <summary>后台：无界面模块，宿主启动即拉起边车常驻（能力仅供宿主/其他模块调用）</summary>
    Background,

    /// <summary>工具：工具页「第三方模块」区的工具面板（挂面板首次打开）</summary>
    Tool,

    /// <summary>悬浮：非卡片流的桌面悬浮窗（类似 AI 助手、语音的浮动形态；挂悬浮窗首次打开）</summary>
    Overlay,
}

/// <summary>
/// <c>mounts</c> 字段的字符串白名单与解析。清单是第三方 JSON，宿主侧**宽松解析**：
/// 未知值不炸反序列化（保留在 <see cref="ModuleManifest.Mounts"/> 原样），只不参与挂载分发
/// 并记日志——坏一个字段不能让整份清单失效（与 ModuleCatalog 坏清单跳过点名同一哲学）。
/// </summary>
public static class ModuleMounts
{
    /// <summary>卡片形态的清单字符串</summary>
    public const string Card = "card";

    /// <summary>后台形态的清单字符串</summary>
    public const string Background = "background";

    /// <summary>工具形态的清单字符串</summary>
    public const string Tool = "tool";

    /// <summary>悬浮形态的清单字符串</summary>
    public const string Overlay = "overlay";

    /// <summary>清单字符串 → 枚举（ordinal 精确匹配，大小写敏感与门禁一致）</summary>
    private static readonly Dictionary<string, ModuleMountKind> ParseTable = new(System.StringComparer.Ordinal)
    {
        [Card] = ModuleMountKind.Card,
        [Background] = ModuleMountKind.Background,
        [Tool] = ModuleMountKind.Tool,
        [Overlay] = ModuleMountKind.Overlay,
    };

    /// <summary>解析单个形态字符串（未知/空 = false）。</summary>
    public static bool TryParse(string? raw, out ModuleMountKind kind)
    {
        kind = default;
        if (string.IsNullOrEmpty(raw)) return false;
        return ParseTable.TryGetValue(raw, out kind);
    }

    /// <summary>枚举 → 清单字符串（白名单的逆向表；生成 JSON / 测试夹具用）。</summary>
    public static string ToToken(ModuleMountKind kind) => kind switch
    {
        ModuleMountKind.Card => Card,
        ModuleMountKind.Background => Background,
        ModuleMountKind.Tool => Tool,
        ModuleMountKind.Overlay => Overlay,
        _ => "",
    };

    /// <summary>形态的本地化名（插件页/工具页展示用）。显式完整键（非拼接）：i18n 门禁静态
    /// 引用检测只认字面量，拼接前缀会成为无映射孤儿。</summary>
    public static string DisplayName(ModuleMountKind kind) => Framework.Lang.T(kind switch
    {
        ModuleMountKind.Card => "moduleMounts.card",
        ModuleMountKind.Background => "moduleMounts.background",
        ModuleMountKind.Tool => "moduleMounts.tool",
        ModuleMountKind.Overlay => "moduleMounts.overlay",
        _ => "moduleMounts.card",
    });
}
