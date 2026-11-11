using System;
using System.Collections.Generic;
using AppKit;
using CoreGraphics;
using SideDesk.UI.Yaml;

namespace SpikeNspanel.SideUi;

/// <summary>
/// AppKit 侧的语义 token 取值点（对应 Windows 的 <c>UiTokens</c> + <c>ThemeManager</c> 资源字典）。
///
/// <para><b>纪律与 Windows 一致</b>：语义名 → 资源键经 <see cref="UiRegistries.ResourceKey"/> 取，
/// 代码里不出现语义名字面量；资源键 → 具体值查本文件的表（相当于 ThemeManager 往 Application 资源里
/// 塞的那套 Brush/FontSize）。取不到键回落默认值，绝不“不设”（不设就等于靠继承，宿主底色一变即破相）。</para>
///
/// <para>默认暗色主题的基色逐字取自 <c>ThemeManager.ApplyTheme</c> 的回落值：
/// bg <c>#161616</c> / text <c>#FFFFFF</c> / accent <c>#3B82F6</c>，其余次要色按同款 Blend/WithAlpha 派生。</para>
/// </summary>
internal static class UiTokensMac
{
    // 基色（ThemeManager 的默认回落）。0..1 分量。
    private static readonly CGColor Bg = FromHex("#161616");
    private static readonly CGColor Text = FromHex("#FFFFFF");
    private static readonly CGColor Accent = FromHex("#3B82F6");
    private static readonly CGColor White = FromHex("#FFFFFF");
    private static readonly CGColor Black = FromHex("#000000");

    // 派生次要色（与 ThemeManager.ApplyTheme 同公式）。
    private static readonly CGColor Border = Blend(Bg, Text, 0.15);
    private static readonly CGColor TextSec = Blend(Text, Bg, 0.35);
    private static readonly CGColor TextMuted = Blend(Text, Bg, 0.60);
    private static readonly CGColor AccentText = Luminance(Accent) > 0.6 ? Black : White;
    private static readonly CGColor Separator = WithAlpha(Border, 0.50);
    private static readonly CGColor HoverBg = WithAlpha(White, 0.08);
    private static readonly CGColor SelectedBg = WithAlpha(Accent, 0.20);

    /// <summary>资源键（tokens.v1.json 的 value，如 <c>BrushTextMuted</c>）→ 具体 NSColor。</summary>
    private static readonly Dictionary<string, NSColor> BrushByKey = new(StringComparer.Ordinal)
    {
        ["BrushBG"] = ToNS(Bg),
        ["BrushBorder"] = ToNS(Border),
        ["BrushAccent"] = ToNS(Accent),
        ["BrushAccentText"] = ToNS(AccentText),
        ["BrushTextMain"] = ToNS(Text),
        ["BrushTextSec"] = ToNS(TextSec),
        ["BrushTextMuted"] = ToNS(TextMuted),
        ["BrushSeparator"] = ToNS(Separator),
        ["BrushListViewItemMouseOver"] = ToNS(HoverBg),
        ["BrushListViewItemSelectedBG"] = ToNS(SelectedBg),
        ["BrushTransparent"] = NSColor.Clear,
    };

    /// <summary>资源键（如 <c>FontSizeSmall</c>）→ 实际字号（Typography.xaml 逐字）。</summary>
    private static readonly Dictionary<string, nfloat> FontByKey = new(StringComparer.Ordinal)
    {
        ["FontSizeTiny"] = 10,
        ["FontSizeSmall"] = 11,
        ["FontSizeSmallPlus"] = 12,
        ["FontSizeNormal"] = 13,
        ["FontSizeNormalPlus"] = 14,
        ["FontSizeLarge"] = 15,
        ["FontSizeSubtitle"] = 18,
        ["FontSizeTitle"] = 20,
    };

    /// <summary>语义色 → NSColor。<paramref name="fallbackSemantic"/> 为声明省略时的默认语义名（如 text.main）。</summary>
    public static NSColor Brush(UiRegistries reg, string? semantic, string fallbackSemantic = "text.main")
    {
        var name = string.IsNullOrEmpty(semantic) ? fallbackSemantic : semantic!;
        var key = reg.ResourceKey("brush", name) ?? reg.ResourceKey("constant", name);
        if (key != null && BrushByKey.TryGetValue(key, out var c)) return c;
        return ToNS(Text);   // 兜底主文字色，绝不“不设”
    }

    /// <summary>语义字号 → 实际值；查不到回落 <paramref name="fallback"/>（同 Windows UiTokens.Font）。</summary>
    public static nfloat Font(UiRegistries reg, string? semantic, double fallback = 11)
    {
        if (string.IsNullOrEmpty(semantic)) return (nfloat)fallback;
        var key = reg.ResourceKey("font", semantic!);
        return key != null && FontByKey.TryGetValue(key, out var v) ? v : (nfloat)fallback;
    }

    /// <summary>语义圆角 → 半径点数（Windows 的 CornerRadius* 资源在 mac 侧按等值点数给）。</summary>
    public static nfloat Radius(UiRegistries reg, string? semantic, double fallback = 4) => semantic switch
    {
        "small" => (nfloat)3,
        "card" => (nfloat)6,
        "large" => (nfloat)10,
        "xlarge" => (nfloat)14,
        _ => (nfloat)fallback,
    };

    // ---- 颜色工具（对应 ThemeManager 的 Blend / WithAlpha / Luminance / ParseColor）----

    /// <summary>CGColor → NSColor（AppKit 无 FromColor(CGColor) 重载，按 RGBA 分量重建）。</summary>
    private static NSColor ToNS(CGColor c)
    {
        var cc = c.Components!;
        var a = cc.Length > 3 ? cc[3] : (nfloat)1;
        return NSColor.FromRgba(cc[0], cc[1], cc[2], a);
    }

    private static CGColor FromHex(string hex)
    {
        var h = hex.TrimStart('#');
        byte R = Convert.ToByte(h.Substring(0, 2), 16);
        byte G = Convert.ToByte(h.Substring(2, 2), 16);
        byte B = Convert.ToByte(h.Substring(4, 2), 16);
        return new CGColor(R / 255f, G / 255f, B / 255f, 1f);
    }

    /// <summary>把 a 向 b 混合 t（t=0 得 a，t=1 得 b）—— 与 ThemeManager.Blend 同义。</summary>
    private static CGColor Blend(CGColor a, CGColor b, double t)
    {
        var ca = a.Components; var cb = b.Components;
        return new CGColor(
            (nfloat)(ca[0] + (cb[0] - ca[0]) * t),
            (nfloat)(ca[1] + (cb[1] - ca[1]) * t),
            (nfloat)(ca[2] + (cb[2] - ca[2]) * t),
            1f);
    }

    private static CGColor WithAlpha(CGColor c, double a)
    {
        var cc = c.Components;
        return new CGColor(cc[0], cc[1], cc[2], (nfloat)a);
    }

    private static double Luminance(CGColor c)
    {
        var cc = c.Components;
        return 0.299 * cc[0] + 0.587 * cc[1] + 0.114 * cc[2];
    }
}
