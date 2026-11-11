using System;
using System.Collections.Generic;
using System.Linq;
using SideDesk.Models;
using SideDesk.UI.Yaml;

namespace SpikeNspanel.SideUi;

/// <summary>
/// 便签卡片的数据源（对应 Windows 的 <c>StickyNoteSource</c>，去掉宿主 <c>PanelItem</c> 依赖，
/// 直接持有一份可变便签列表 —— mac 侧还没有面板宿主模型）。
///
/// <para><c>sn.notes</c> 是<b>类型直通</b>：节点要的是 <see cref="StickyNote"/> 原对象（预览文本、
/// 内容截断、按位置的行交互都按对象身份走，压成标量会丢身份）。排序（更新时间倒序）也归这里 ——
/// 节点渲染与宿主交互必须同序，两端都调 <see cref="Ordered"/>。</para>
/// </summary>
internal sealed class StickyNoteSourceMac : IUiDataSource
{
    private readonly List<StickyNote> _notes;
    private readonly bool _editMode;

    public StickyNoteSourceMac(List<StickyNote> notes, bool editMode)
    {
        _notes = notes;
        _editMode = editMode;
    }

    /// <summary>底层可变列表（宿主删除便签用；删除后由宿主全量重建面板）。</summary>
    public List<StickyNote> Notes => _notes;

    /// <summary>列表变化走宿主的全量重建，本源不做增量通知（与 Windows 同）。</summary>
    public event Action? Changed { add { } remove { } }

    public bool TryGet(string path, out object? value)
    {
        switch (path)
        {
            case "sn.notes": value = Ordered(_notes); return true;
            // 布尔槽位按 "true"/"false" 字符串判（Ordinal）—— 与既有数据源的约定一致
            case "sn.editMode": value = _editMode ? "true" : "false"; return true;
            default: value = null; return false;
        }
    }

    /// <summary>渲染顺序（更新时间倒序，原样搬自 Windows）—— 节点与宿主共用的唯一口径。</summary>
    public static List<StickyNote> Ordered(List<StickyNote> notes) =>
        notes.OrderByDescending(n => n.UpdatedAt).ToList();
}
