using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Newtonsoft.Json;
using SideDesk.Models;

namespace SideDesk.Services;

/// <summary>
/// 快捷分组管理服务（#335 Models 去 ActiveRecord）：原 QuickGroupManager 静态门面改为实例服务。
/// 全部操作代理到 WindowConfigManager 内的快捷面板（Type=QuickGroup）。
/// </summary>
public class QuickGroupService
{
    /// <summary>旧版默认分组的固定 ID（仅迁移时用于匹配未绑定面板）。</summary>
    private const string LEGACY_DEFAULT_GROUP_ID = "__default__";

    private WindowConfigManager? _mgr;

    /// <summary>WindowConfigManager.Load 完成后注入全局配置管理器（每次 Load 重赋值）。</summary>
    public void Init(WindowConfigManager mgr) => _mgr = mgr;

    private static string SideDeskFolder => Framework.AppPaths.DataDir;

    /// <summary>按声明顺序枚举全部快捷面板（含嵌套子面板）。</summary>
    private List<PanelItem> EnumerateQuickPanels()
    {
        var result = new List<PanelItem>();
        if (_mgr == null) return result;
        void Collect(List<PanelItem> panels)
        {
            foreach (var p in panels)
            {
                if (p.Type == PanelType.QuickGroup) result.Add(p);
                if (p.ChildPanels != null) Collect(p.ChildPanels);
            }
        }
        foreach (var win in _mgr.Windows)
            if (win.Panels != null) Collect(win.Panels);
        return result;
    }

    private PanelItem? FindPanel(string groupId) =>
        EnumerateQuickPanels().FirstOrDefault(p => p.Id == groupId);

    public List<QuickGroup> GetAll() =>
        EnumerateQuickPanels().Select(p => new QuickGroup(p)).ToList();

    public void Save() => _mgr?.Save();

    /// <summary>新增快捷面板：优先 targetWindow，缺省落第一个窗口。</summary>
    public void AddGroup(QuickGroup group, WindowConfig? targetWindow = null)
    {
        if (_mgr == null || _mgr.Windows.Count == 0) return;
        var win = targetWindow ?? _mgr.Windows[0];
        win.Panels ??= new List<PanelItem>();
        win.Panels.Add(group.Panel);
    }

    /// <summary>按 Id 删除快捷面板（递归查找嵌套子面板）。</summary>
    public void RemoveGroup(string groupId)
    {
        if (_mgr == null) return;
        bool RemoveFrom(List<PanelItem> panels)
        {
            var target = panels.FirstOrDefault(p => p.Id == groupId);
            if (target != null) { panels.Remove(target); return true; }
            foreach (var p in panels)
                if (p.ChildPanels != null && RemoveFrom(p.ChildPanels)) return true;
            return false;
        }
        foreach (var win in _mgr.Windows)
            if (win.Panels != null && RemoveFrom(win.Panels)) return;
    }

    /// <summary>获取可用快捷面板 Id：已有面板取第一个，否则新建一个。</summary>
    public string GetOrCreateDefaultGroup()
    {
        var panels = EnumerateQuickPanels();
        if (panels.Count > 0) return panels[0].Id;
        var g = new QuickGroup { Name = "快捷方式", Columns = 2 };
        AddGroup(g);
        return g.Id;
    }

    public void AddItem(string groupId, QuickItem item)
    {
        var p = FindPanel(groupId);
        if (p == null) return;
        var list = p.QuickItems ??= new List<QuickItem>();
        item.SortIndex = list.Count; // 新项追加到末尾并赋予末位序号（列表始终按 SortIndex 有序）
        list.Add(item);
    }

    public void RemoveItem(string groupId, string itemId)
    {
        var p = FindPanel(groupId);
        p?.QuickItems?.RemoveAll(i => i.Id == itemId);
    }

    /// <summary>重排分组内所有项的 SortIndex 为 0..n-1（拖拽调序/跨组移动后调用）。</summary>
    public void ReindexItems(string groupId)
    {
        var p = FindPanel(groupId);
        if (p?.QuickItems == null) return;
        for (int i = 0; i < p.QuickItems.Count; i++)
            p.QuickItems[i].SortIndex = i;
    }

    /// <summary>
    /// 按 SortIndex 稳定排序（相同序号按创建时间兜底，保证多端一致）。
    /// 本地加载/云端拉取后调用；旧数据无 SortIndex 时全为 0，退化为按创建时间排序。
    /// </summary>
    public static void SortByIndex(List<QuickItem>? items)
    {
        if (items == null || items.Count < 2) return;
        var sorted = items.OrderBy(i => i.SortIndex).ThenBy(i => i.CreatedAt).ToList();
        for (int i = 0; i < items.Count; i++)
            items[i] = sorted[i];
    }

    /// <summary>门面模式下属性直接代理到面板，无需额外回写（保留方法签名兼容调用点）。</summary>
    public void UpdateGroup(QuickGroup group) { }

    /// <summary>退出时调用：删除「来自添加窗口」且未勾选长期窗口的临时项。返回删除数量。</summary>
    public int RemoveTransientWindowItems()
    {
        int count = 0;
        foreach (var p in EnumerateQuickPanels())
        {
            if (p.QuickItems == null) continue;
            count += p.QuickItems.RemoveAll(it => it != null && it.Source == "window" && !it.IsLongTermWindow);
        }
        return count;
    }

    /// <summary>旧版 quickgroups.json 分组结构（仅迁移反序列化用）。</summary>
    private class LegacyQuickGroup
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public int Columns { get; set; } = 1;
        public bool IsExpanded { get; set; } = true;
        public int Order { get; set; }
        public bool HideFrame { get; set; }
        public string DisplayMode { get; set; } = "grid";
        public string OwnerType { get; set; } = "personal";
        public string? TeamId { get; set; }
        public string? TeamName { get; set; }
        public List<QuickItem> Items { get; set; } = new List<QuickItem>();
        public List<PanelItem>? ChildPanels { get; set; }
    }

    /// <summary>更早的 bookmarks/aitools/programs 遗留文件结构（仅迁移反序列化用）。</summary>
    private class LegacyBookmark
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public string Url { get; set; } = "";
        public bool UseAppMode { get; set; } = true;
        public string BackgroundColor { get; set; } = "";
        public DateTime CreatedAt { get; set; }
    }

    private class LegacyAiTool
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public string Url { get; set; } = "";
        public string BackgroundColor { get; set; } = "";
        public DateTime CreatedAt { get; set; }
    }

    private class LegacyProgram
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public string Command { get; set; } = "";
        public string Arguments { get; set; } = "";
        public string BackgroundColor { get; set; } = "";
        public DateTime CreatedAt { get; set; }
    }

    /// <summary>
    /// 一次性历史数据迁移（由 LocalDbService 在首次行级落库前调用）：
    /// 1) quickgroups.json 的分组设置与快捷项写入对应快捷面板（按 GroupId 匹配，未绑定面板接收默认组），
    ///    孤儿分组新建快捷面板承载；
    /// 2) 无 quickgroups.json 时，从更早的 bookmarks/aitools/programs JSON 迁移（保持原语义）；
    /// 3) 处理完的文件改名 .bak 留存。返回是否有数据变更。
    /// </summary>
    public bool MigrateLegacyOnce()
    {
        if (_mgr == null || _mgr.Windows.Count == 0) return false;
        bool changed = false;
        string folder = SideDeskFolder;

        string quickFile = Path.Combine(folder, "quickgroups.json");
        if (File.Exists(quickFile))
        {
            try
            {
                var groups = JsonConvert.DeserializeObject<List<LegacyQuickGroup>>(File.ReadAllText(quickFile));
                if (groups != null)
                {
                    foreach (var g in groups.OrderBy(x => x.Order))
                    {
                        // GroupId 绑定的面板优先；未绑定面板接收旧默认组
                        var panel = EnumerateQuickPanels().FirstOrDefault(p => p.GroupId == g.Id)
                            ?? (g.Id == LEGACY_DEFAULT_GROUP_ID
                                ? EnumerateQuickPanels().FirstOrDefault(p => string.IsNullOrEmpty(p.GroupId))
                                : null);
                        if (panel != null)
                        {
                            ApplyLegacyGroup(panel, g);
                            panel.GroupId = null; // 迁移完成后 GroupId 不再使用
                            changed = true;
                            continue;
                        }
                        // 孤儿分组：新建快捷面板承载
                        var np = new PanelItem { Type = PanelType.QuickGroup };
                        ApplyLegacyGroup(np, g);
                        var win = _mgr!.Windows[0];
                        win.Panels ??= new List<PanelItem>();
                        win.Panels.Add(np);
                        changed = true;
                    }
                    // 未匹配到任何分组的 GroupId 清理，避免残留引用
                    foreach (var p in EnumerateQuickPanels())
                    {
                        if (!string.IsNullOrEmpty(p.GroupId))
                        {
                            p.GroupId = null;
                            changed = true;
                        }
                    }
                }
                File.Move(quickFile, quickFile + ".bak", true);
            }
            catch (Exception ex)
            {
                Framework.RuntimeLog.Debug($"[QuickGroup] quickgroups.json migration failed: {ex.Message}");
            }
            return changed;
        }

        // 更早的遗留文件（原 MigrateFromLegacy 语义：仅无 quickgroups.json 时执行）
        changed |= MigrateLegacyFile<LegacyBookmark>("bookmarks.json", "书签", b => new QuickItem
        {
            Id = b.Id,
            Name = b.Name,
            Type = "url",
            Target = b.Url,
            UseAppMode = b.UseAppMode,
            BackgroundColor = b.BackgroundColor,
            CreatedAt = b.CreatedAt
        });
        changed |= MigrateLegacyFile<LegacyAiTool>("aitools.json", "AI 工具", t => new QuickItem
        {
            Id = t.Id,
            Name = t.Name,
            Type = "url",
            Target = t.Url,
            UseAppMode = true,
            BackgroundColor = t.BackgroundColor,
            CreatedAt = t.CreatedAt
        });
        changed |= MigrateLegacyFile<LegacyProgram>("programs.json", "程序", p => new QuickItem
        {
            Id = p.Id,
            Name = p.Name,
            Type = "program",
            Target = string.IsNullOrEmpty(p.Arguments) ? p.Command : p.Command + " " + p.Arguments,
            UseAppMode = false,
            BackgroundColor = p.BackgroundColor,
            CreatedAt = p.CreatedAt
        });
        return changed;
    }

    private static void ApplyLegacyGroup(PanelItem panel, LegacyQuickGroup g)
    {
        panel.QuickGroupName = string.IsNullOrEmpty(g.Name) ? Framework.Lang.T("common.shortcut") : g.Name;
        panel.QuickColumns = g.Columns > 0 ? g.Columns : 1;
        panel.IsExpanded = g.IsExpanded;
        panel.QuickHideFrame = g.HideFrame;
        panel.QuickDisplayMode = string.IsNullOrEmpty(g.DisplayMode) ? "grid" : g.DisplayMode;
        panel.QuickOrder = g.Order;
        panel.OwnerType = string.IsNullOrEmpty(g.OwnerType) ? "personal" : g.OwnerType;
        panel.TeamId = g.TeamId;
        panel.TeamName = g.TeamName;
        panel.QuickItems = g.Items ?? new List<QuickItem>();
        if (g.ChildPanels != null && g.ChildPanels.Count > 0)
        {
            panel.ChildPanels ??= new List<PanelItem>();
            panel.ChildPanels.AddRange(g.ChildPanels);
        }
    }

    private bool MigrateLegacyFile<T>(string fileName, string panelName, Func<T, QuickItem> convert)
    {
        string path = Path.Combine(SideDeskFolder, fileName);
        if (!File.Exists(path)) return false;
        try
        {
            var legacy = JsonConvert.DeserializeObject<List<T>>(File.ReadAllText(path));
            if (legacy == null || legacy.Count == 0)
            {
                File.Move(path, path + ".bak", true);
                return false;
            }
            var panel = new PanelItem
            {
                Type = PanelType.QuickGroup,
                QuickGroupName = panelName,
                QuickColumns = 1,
                QuickItems = legacy.Select(convert).ToList()
            };
            var win = _mgr!.Windows[0];
            win.Panels ??= new List<PanelItem>();
            win.Panels.Add(panel);
            File.Move(path, path + ".bak", true);
            return true;
        }
        catch (Exception ex)
        {
            Framework.RuntimeLog.Debug($"[QuickGroup] {fileName} migration failed: {ex.Message}");
            return false;
        }
    }
}
