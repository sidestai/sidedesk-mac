namespace SideDesk.Models;

/// <summary>
/// <see cref="PanelItem"/> 的「模块卡」分片（#657 批 2）。
///
/// <para>单开一片而不是并进主文件：主文件在**文件行数冻结**名单里（ADR-0011 只减不增），
/// 与既有 <c>WindowConfig.DeskNote.cs</c> 同款做法——新领域的新字段落在新分片，主文件零增长。</para>
/// </summary>
public partial class PanelItem
{
    /// <summary>模块卡：第三方模块 id（module.json 里的 id）；空 = 尚未选择模块。</summary>
    public string? ModuleId { get; set; }
}
