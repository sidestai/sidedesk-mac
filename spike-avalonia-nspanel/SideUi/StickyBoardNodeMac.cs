using System;
using System.Collections.Generic;
using AppKit;
using CoreGraphics;
using Foundation;
using SideDesk.Models;
using SideDesk.UI.Yaml;

namespace SpikeNspanel.SideUi;

/// <summary>
/// 便签列表的宿主自绘节点（AppKit 版，对应 Windows 的 <c>StickyBoardNode</c>）。
///
/// <para><b>边界与 Windows 一致</b>：一行便签的视觉（22px 行高、编辑模式下 hover 才显形的 ✕、
/// emoji 预览文本、超 200 字截断的 tooltip）归节点；每行的点击/删除由宿主按位置挂
/// （<see cref="Create"/> 的 <paramref name="onClick"/> / <paramref name="onDelete"/> 回调，契约：第 i 行 ↔ 第 i 条便签）。
/// 高亮/焦点圈依赖 <c>StickyDesktopService</c>（mac 侧尚未移植），本次不做。</para>
///
/// <para>布局用<b>手动 frame</b>（不用 NSStackView/Auto Layout）—— 固定宽度的纵向定高列表用 frame 最稳，
/// 也避开根视图 autoresizing 与约束系统混用的坑。视觉逐项搬自 Windows：行外边距 2,1 / 行高 22 /
/// 右侧 18×18 透明 ✕ / 预览主文字色末端省略号 / tooltip 超 200 字截断。字号走 token（small=11、tiny=10）。</para>
/// </summary>
internal static class StickyBoardNodeMac
{
    /// <summary>行高（与 Windows StickyBoardNode 逐字一致：22）。</summary>
    internal const double RowHeight = 22;
    internal const double PadTop = 4;
    internal const double PadLeft = 4;
    internal const double PadRight = 4;

    /// <summary>按便签列表建一个纵向列表视图（手动布局）。</summary>
    public static NSView Create(UiRegistries reg, IReadOnlyList<StickyNote> notes, bool editMode,
                                Action<int>? onClick, Action<int>? onDelete)
    {
        var board = new StickyBoardView();
        for (var i = 0; i < notes.Count; i++)
        {
            var idx = i;   // 闭包捕获当前下标
            board.AddRow(new StickyRowView(reg, notes[i], editMode,
                                           () => onClick?.Invoke(idx),
                                           () => onDelete?.Invoke(idx)));
        }
        return board;
    }

    /// <summary>
    /// 行 tooltip 文本：原始 Markdown 直接展示会漏出图片网址、折叠块标签与多余空行，
    /// 先清洗成可读纯文本再按 200 字截断（与 Windows 同口径）。纯函数，可单测。
    /// </summary>
    internal static string? BuildTooltip(string? content)
    {
        if (string.IsNullOrWhiteSpace(content)) return null;
        var s = NotePreviewText.StripMarkup(content);
        s = System.Text.RegularExpressions.Regex.Replace(s, @"(?:\r?\n[ \t]*){2,}", "\n").Trim();
        if (s.Length == 0) return null;
        return s.Length > 200 ? s.Substring(0, 200) + "..." : s;
    }
}

/// <summary>便签列表容器：从上到下按 22px 定高摆放各行，随宽度变化重排（手动 frame 布局）。</summary>
internal sealed class StickyBoardView : NSView
{
    private readonly List<NSView> _rows = new();

    public StickyBoardView() : base(new CGRect(0, 0, 100, 100))
    {
        AutoresizingMask = NSViewResizingMask.WidthSizable | NSViewResizingMask.HeightSizable;
    }

    public void AddRow(NSView row)
    {
        _rows.Add(row);
        AddSubview(row);
    }

    public override void Layout()
    {
        base.Layout();
        var w = Bounds.Width;
        // AppKit 坐标 y 向上；从顶部开始往下摆
        nfloat y = Bounds.Height - (nfloat)StickyBoardNodeMac.PadTop;
        foreach (var row in _rows)
        {
            y -= (nfloat)StickyBoardNodeMac.RowHeight;
            row.Frame = new CGRect((nfloat)StickyBoardNodeMac.PadLeft, y,
                                   w - (nfloat)(StickyBoardNodeMac.PadLeft + StickyBoardNodeMac.PadRight),
                                   (nfloat)StickyBoardNodeMac.RowHeight);
            row.NeedsLayout = true;
        }
    }
}

/// <summary>单行便签：透明底 + 预览文本（末端省略号）+ hover 才显形的 ✕（编辑模式）。手动 frame 布局。</summary>
internal sealed class StickyRowView : NSView
{
    private readonly NSTextField _text;
    private readonly NSButton _delete;
    private readonly bool _editMode;
    private readonly Action _onClick;
    private readonly Action _onDelete;
    private NSTrackingArea? _tracking;
    private bool _hovering;

    public StickyRowView(UiRegistries reg, StickyNote note, bool editMode, Action onClick, Action onDelete)
        : base(new CGRect(0, 0, 92, 22))
    {
        _editMode = editMode;
        _onClick = onClick;
        _onDelete = onDelete;
        WantsLayer = true;
        Layer!.BackgroundColor = NSColor.Clear.CGColor;
        ToolTip = StickyBoardNodeMac.BuildTooltip(note.Content);

        _text = NSTextField.CreateLabel(note.Preview);
        _text.LineBreakMode = NSLineBreakMode.TruncatingTail;
        _text.TextColor = UiTokensMac.Brush(reg, "text.main");
        _text.Font = NSFont.SystemFontOfSize(UiTokensMac.Font(reg, "small"));
        _text.Selectable = false;
        AddSubview(_text);

        _delete = new NSButton(new CGRect(0, 0, 18, 18))
        {
            Title = "✕",
            Bordered = false,
            Transparent = true,
            Font = NSFont.SystemFontOfSize(UiTokensMac.Font(reg, "tiny")),
            Hidden = true,
        };
        _delete.Activated += (_, _) => _onDelete();
        AddSubview(_delete);
    }

    public override void Layout()
    {
        base.Layout();
        var h = Bounds.Height;
        var delSize = (nfloat)18;
        // ✕ 靠右、垂直居中
        _delete.Frame = new CGRect(Bounds.Width - delSize - 4, (h - delSize) / 2, delSize, delSize);
        // 文本填左侧，留出 ✕ 的位置
        var textWidth = Bounds.Width - 6 - delSize - 8;
        if (textWidth < 8) textWidth = 8;
        _text.Frame = new CGRect(6, (h - _text.FittingSize.Height) / 2, textWidth, _text.FittingSize.Height);
    }

    public override void UpdateTrackingAreas()
    {
        base.UpdateTrackingAreas();
        if (_tracking != null) RemoveTrackingArea(_tracking);
        _tracking = new NSTrackingArea(Bounds,
            NSTrackingAreaOptions.MouseEnteredAndExited | NSTrackingAreaOptions.ActiveInKeyWindow | NSTrackingAreaOptions.InVisibleRect,
            this, null);
        AddTrackingArea(_tracking);
    }

    public override void MouseEntered(NSEvent theEvent)
    {
        if (!_editMode) return;
        _hovering = true;
        _delete.Hidden = false;
    }

    public override void MouseExited(NSEvent theEvent)
    {
        if (!_editMode) return;
        _hovering = false;
        _delete.Hidden = true;
    }

    public override void MouseDown(NSEvent theEvent) => _onClick();
}
