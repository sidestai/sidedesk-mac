using System.Collections.Generic;

namespace SideDesk.Models;

/// <summary>「记事」卡片的数据分片（2026-10-05 自 WindowConfig.cs 拆出，ADR-0011）。</summary>
public partial class PanelItem
{
    public List<DeskNote>? DeskNotes { get; set; }     // 记事数据（per-panel）
}
