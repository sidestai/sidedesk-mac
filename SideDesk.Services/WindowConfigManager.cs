// Ported from Windows Models/WindowConfig.cs L386-879 (WindowConfigManager).
// Under the layered/seam architecture this persistence orchestrator lives in the
// SERVICE layer (SideDesk.Services assembly), not in Core. Namespace kept as
// SideDesk.Models so existing 'using SideDesk.Models;' call sites resolve it verbatim.
// One decoupling: Save()'s reverse call into CloudSyncService now goes through the
// ICloudSyncNotifier seam (CloudSync network layer is a later phase).
using Newtonsoft.Json;

namespace SideDesk.Models;

public class WindowConfigManager
{
    // 遗留存储路径：首次升级时作为迁移来源导入 SQLite；快照写盘已废弃，遗留文件由 Save 归档为 .bak-migrated
    private static readonly string _filePath = Path.Combine(
        Framework.AppPaths.DataDir, "windows.json");

    public List<WindowConfig> Windows { get; set; } = new();
    public DockWindowState LeftDock { get; set; } = new();
    public DockWindowState RightDock { get; set; } = new();
    /// <summary>全局后台数据看板项（不绑定任何面板，仅后台轮询）</summary>
    public List<DataDashboardItem> BackgroundDashboardItems { get; set; } = new();
    /// <summary>变量集定义（多变量聚合：求和/求平均/最大/最小/计数，生成本地新变量）</summary>
    public List<VariableSet> VariableSets { get; set; } = new();

    /// <summary>
    /// 本内存实例加载时所归属的数据作用域（"local" 或 "u:{密文}"），由 LocalDbService 加载时打标。
    /// 与 <see cref="Services.LocalDbService.CurrentScope"/> 不一致即表示登录态已变更、而窗口尚未按新作用域重载：
    /// 此时内存里是旧作用域的数据（登出重启后往往只剩兜底空窗口），任何“以内存为准”的全量写库或结构上传
    /// 都会把新作用域下的既有数据整体清空（本地 DeleteMissing + 服务端对账软删），因此必须一律拒绝。
    /// </summary>
    [Newtonsoft.Json.JsonIgnore]
    public string? LoadedScope { get; set; }

    public static WindowConfigManager Load()
    {
        var mgr = LoadCore();
        // 作用域戳兜底：LoadManager 已按实际读取的作用域打标；其余兜底路径（库损坏/旧 JSON 回退/异常）
        // 返回的实例语义是“当前作用域下没有数据”，同样按当前作用域打标
        if (string.IsNullOrEmpty(mgr.LoadedScope))
            mgr.LoadedScope = Services.LocalDbService.CurrentScope();
        // dock 成员自愈：dock 状态与窗口表是两份独立持久化，异常写入可能使二者脱节
        mgr.RepairDockMembership();
        // 快捷分组门面：将全局配置管理器注入 QuickGroupService（快捷数据已改存面板）
        Composition.AppContainer.Resolve<Services.QuickGroupService>().Init(mgr);
        // 遗留 JSON → SQLite 迁移预热：各管理器为惰性迁移（首次访问才触发），
        // 此处启动时主动触发一次，确保数据尽早落库而非滞留旧 JSON
        try { Composition.AppContainer.Resolve<Services.AIConfigService>().GetConfig(); } catch { }
        try { Composition.AppContainer.Resolve<Services.CloudSpaceService>().GetAll(); } catch { }
        try { DigitalEmployeeManager.Load(); } catch { }
        try { SideDesk.Services.TitleLockRuleManager.GetAll(); } catch { }
        return mgr;
    }

    private static WindowConfigManager LoadCore()
    {
        // 主存储：SQLite（sidedesk.db）；windows.json 仅作首次升级的迁移来源
        try
        {
            if (Services.LocalDbService.DbExists)
            {
                try
                {
                    var mgr = Services.LocalDbService.LoadManager();
                    MigrateLegacyStickyNotesOnce(mgr);
                    PurgeEmptyStickyNotesOnce(mgr);
                    ConsolidateDuplicateWindowsOnce(mgr);
                    mgr.ArchiveLegacyWindowsJsonOnce();
                    return mgr;
                }
                catch (Exception dbEx)
                {
                    // db 损坏/读取失败：改名留存坏库便于人工修复（SQLite WAL 下极罕见）；
                    // windows.json 快照已停止写盘不再作为回滚源，窗口数据由云同步从服务端重新拉取
                    Framework.RuntimeLog.Debug($"[LocalDb] database read failed: {dbEx.Message}");
                    try
                    {
                        string corrupt = Services.LocalDbService.DbPath + ".corrupt-" + DateTime.Now.ToString("yyyyMMdd-HHmmss");
                        if (File.Exists(Services.LocalDbService.DbPath)) File.Move(Services.LocalDbService.DbPath, corrupt);
                    }
                    catch { }
                    return new WindowConfigManager();
                }
            }
            if (File.Exists(_filePath))
            {
                // 首次升级：windows.json 导入 SQLite（成功后原文件改名 .bak-migrated 保留）
                if (Services.LocalDbService.ImportFromJsonFile(_filePath))
                {
                    var mgrDb = Services.LocalDbService.LoadManager();
                    MigrateLegacyStickyNotesOnce(mgrDb);
                    PurgeEmptyStickyNotesOnce(mgrDb);
                    ConsolidateDuplicateWindowsOnce(mgrDb);
                    return mgrDb;
                }
                // 导入失败兜底：仍按旧 JSON 方式加载（下次 Save 会再次尝试写入 SQLite）
                var json = File.ReadAllText(_filePath);
                var mgr = JsonConvert.DeserializeObject<WindowConfigManager>(json) ?? new WindowConfigManager();
                MigrateLegacyStickyNotesOnce(mgr);
                PurgeEmptyStickyNotesOnce(mgr);
                ConsolidateDuplicateWindowsOnce(mgr);
                return mgr;
            }
        }
        catch { }
        return new WindowConfigManager();
    }

    /// <summary>
    /// 旧版全局便签库一次性迁移：per-panel 存储引入前便签数据存于全局 sticky-notes.json。
    /// 升级后首次启动时将全局数据迁入尚无 per-panel 数据的遗留便签卡片，并写入完成标记；
    /// 之后新建/导入的便签卡片一律从空列表开始（否则新面板会被全局遗留数据污染）。
    /// </summary>
    private static void MigrateLegacyStickyNotesOnce(WindowConfigManager mgr)
    {
        try
        {
            string flagPath = Path.Combine(Path.GetDirectoryName(_filePath)!, "sticky-notes-migrated.flag");
            if (File.Exists(flagPath)) return;

            bool migrated = false;
            var globalNotes = Composition.AppContainer.Resolve<Services.StickyNoteService>().GetAll();
            if (globalNotes.Count > 0)
            {
                foreach (var win in mgr.Windows)
                {
                    foreach (var p in EnumerateAllPanels(win.Panels))
                    {
                        if (p.Type == PanelType.StickyNotes && p.StickyNotes == null)
                        {
                            p.StickyNotes = new List<StickyNote>(globalNotes);
                            migrated = true;
                        }
                    }
                }
            }
            File.WriteAllText(flagPath, DateTime.Now.ToString("o"));
            if (migrated) mgr.Save();
        }
        catch { }
    }

    private static IEnumerable<PanelItem> EnumerateAllPanels(List<PanelItem> panels)
    {
        foreach (var p in panels)
        {
            yield return p;
            if (p.ChildPanels != null)
                foreach (var c in EnumerateAllPanels(p.ChildPanels))
                    yield return c;
        }
    }

    /// <summary>
    /// 一次性清理被同步污染的空便签：旧版同步 bug 会把其他类型的行错合并为空白便签并持久化
    /// （便签编辑器有“空内容不落库”气闸，本地存在的空白便签均为污染数据）。
    /// 升级后首次启动时移除全部面板中的空白便签，并写入完成标记。
    /// </summary>
    private static void PurgeEmptyStickyNotesOnce(WindowConfigManager mgr)
    {
        try
        {
            string flagPath = Path.Combine(Path.GetDirectoryName(_filePath)!, "sticky-empty-purged.flag");
            if (File.Exists(flagPath)) return;

            bool changed = false;
            foreach (var win in mgr.Windows)
            {
                foreach (var p in EnumerateAllPanels(win.Panels))
                {
                    if (p.Type != PanelType.StickyNotes || p.StickyNotes == null || p.StickyNotes.Count == 0) continue;
                    int before = p.StickyNotes.Count;
                    p.StickyNotes.RemoveAll(n => string.IsNullOrWhiteSpace(n.Content));
                    if (p.StickyNotes.Count < before) changed = true;
                }
            }
            File.WriteAllText(flagPath, DateTime.Now.ToString("o"));
            if (changed) mgr.Save();
        }
        catch { }
    }

    /// <summary>
    /// 一次性合并重名重复窗口：旧版同步 bug（结构同步 500 + xid- 遗留密文反复新建）
    /// 使服务端产生重复窗口，结构拉取又把它们补齐成同名本地窗口。
    /// 升级后首次启动时，同名个人窗口仅保留卡片最多的一个，其余移除
    /// （其内容为同批 bug 的重复镜像，服务端会在下次同步对账时级联软删）。
    /// </summary>
    private static void ConsolidateDuplicateWindowsOnce(WindowConfigManager mgr)
    {
        try
        {
            string flagPath = Path.Combine(Path.GetDirectoryName(_filePath)!, "dup-windows-consolidated.flag");
            if (File.Exists(flagPath)) return;

            bool changed = false;
            var groups = mgr.Windows
                .Where(w => w.OwnerType != "team" && string.IsNullOrEmpty(w.ShareMode))
                .GroupBy(w => w.Name ?? "")
                .Where(g => g.Count() > 1)
                .ToList();
            foreach (var g in groups)
            {
                var keep = g.OrderByDescending(w => CountPanelsRecursive(w.Panels)).First();
                foreach (var w in g.Where(w => w.Id != keep.Id).ToList())
                {
                    mgr.Windows.Remove(w);
                    mgr.LeftDock.WindowIds.Remove(w.Id);
                    mgr.RightDock.WindowIds.Remove(w.Id);
                    changed = true;
                    Framework.RuntimeLog.Debug($"[WindowConfig] merged duplicate windows: removed {w.Name} ({w.Id}), kept {keep.Id}");
                }
            }
            File.WriteAllText(flagPath, DateTime.Now.ToString("o"));
            if (changed) mgr.Save();
        }
        catch { }
    }

    private static int CountPanelsRecursive(List<PanelItem> panels)
    {
        int n = 0;
        foreach (var p in panels)
        {
            n++;
            if (p.ChildPanels != null) n += CountPanelsRecursive(p.ChildPanels);
        }
        return n;
    }

    /// <summary>
    /// 一次性移除同一窗口内绑定相同 ServerId 的重复面板（保留遍历顺序中最先出现的一个，跨窗口镜像不受影响）。
    /// 遗留 xid- 密文经服务端认领收敛后，多个重复面板会被映射到同一服务端模块，此处去重。
    /// 在同步映射回写成功后调用；真正移除过重复面板才写完成标记，否则下次同步继续检查。
    /// </summary>
    public void DedupPanelsSharingServerIdOnce()
    {
        try
        {
            string flagPath = Path.Combine(Path.GetDirectoryName(_filePath)!, "dup-panels-deduped.flag");
            if (File.Exists(flagPath)) return;

            bool changed = false;
            foreach (var win in Windows)
            {
                var seen = new HashSet<string>();
                if (DedupPanelListByServerId(win.Panels, seen)) changed = true;
            }
            if (changed)
            {
                File.WriteAllText(flagPath, DateTime.Now.ToString("o"));
                Save();
            }
        }
        catch { }
    }

    private static bool DedupPanelListByServerId(List<PanelItem> panels, HashSet<string> seen)
    {
        bool changed = false;
        int i = 0;
        while (i < panels.Count)
        {
            var p = panels[i];
            if (!string.IsNullOrEmpty(p.ServerId) && !seen.Add(p.ServerId!))
            {
                panels.RemoveAt(i);
                changed = true;
                continue;
            }
            if (p.ChildPanels != null && DedupPanelListByServerId(p.ChildPanels, seen)) changed = true;
            i++;
        }
        return changed;
    }

    public void Save()
    {
        // 主存储：SQLite 单事务写入（原子、防写坏）
        try
        {
            Services.LocalDbService.SaveManager(this);
            ArchiveLegacyWindowsJsonOnce();
        }
        catch (Exception ex)
        {
            Framework.RuntimeLog.Debug($"[LocalDb] save failed: {ex.Message}");
        }
    
        // 行级同步：任何配置保存后通知云同步（防抖 2s + 快照对比确保不重复推送）
        // 经 ICloudSyncNotifier 接缝取用；未注册（如 Phase 2 存储层单独运行）时静默跳过。
        try { if (Composition.AppContainer.TryResolve<Services.ICloudSyncNotifier>(out var sync) && sync != null) sync.NotifyRowsChanged(); } catch { }
    }
    
    /// <summary>
    /// 一次性归档遗留 windows.json：快照写盘已废弃（SQLite 为唯一存储，备份打包时从内存实时生成），
    /// 旧文件改名 .bak-migrated 保留。
    /// </summary>
    private void ArchiveLegacyWindowsJsonOnce()
    {
        try
        {
            if (!File.Exists(_filePath)) return;
            File.Move(_filePath, _filePath + ".bak-migrated", overwrite: true);
        }
        catch { }
    }

    public WindowConfig? GetById(string id) => Windows.FirstOrDefault(w => w.Id == id);

    public void Add(WindowConfig config)
    {
        Windows.Add(config);
        Save();
    }

    /// <summary>
    /// 新增微屏并同步加入左右两侧 dock 的顶部标签（多屏/双侧布局下所有窗口都能看到新微屏）。
    /// </summary>
    public void AddToAllDocks(WindowConfig config)
    {
        Windows.Add(config);
        if (!LeftDock.WindowIds.Contains(config.Id)) LeftDock.WindowIds.Add(config.Id);
        if (!RightDock.WindowIds.Contains(config.Id)) RightDock.WindowIds.Add(config.Id);
        Save();
    }

    public void Remove(string id)
    {
        Windows.RemoveAll(w => w.Id == id);
        LeftDock.WindowIds.Remove(id);
        RightDock.WindowIds.Remove(id);
        Save();
    }

    /// <summary>样例数据初始化的一次性标记 key（按账号作用域隔离，存 local_app_state）</summary>
    private const string DefaultBarSeededFlag = "default_bar_seeded";

    /// <summary>
    /// 样例数据初始化：仅新安装（当前作用域未置标）且没有任何 bar 时，自动创建默认 bar 并填充示例面板；
    /// 置标后即使用户删光所有 bar 也不再自动填充。旧版升级首次启动若已有 bar 则只置标不建数据；
    /// 若 bar 为空视为用户已主动清空，同样不再补建。
    /// 示例面板顺序：便签（使用指南/欢迎）→ 常用网址快捷组 → 分组（信号灯）→ 今日待办 → 番茄闹钟。
    /// </summary>
    public void EnsureDefault()
    {
        if (Services.LocalDbService.GetStateFlag(DefaultBarSeededFlag)) return; // 已初始化过，永不再填充
        // 全库只播一次：其他作用域已播过示例（如曾在登录态首次安装）时，本作用域只置标不播 ——
        // 否则登出回 local / 切换账号会再播一份示例 bar，随后被晋升搬进账号作用域造成重复窗口
        if (Services.LocalDbService.AnyScopeStateFlag(DefaultBarSeededFlag))
        {
            Services.LocalDbService.SetStateFlag(DefaultBarSeededFlag);
            return;
        }
        Services.LocalDbService.SetStateFlag(DefaultBarSeededFlag);

        if (Windows.Count == 0)
        {
            // 播种文案按编译区域切换：中文构建用中文，国际构建（API_REGION_EN）用英文；
            // 产品英文名跟随 i18n 惯例 common.sideDeskScreen = SideDesk；元桌浏览器是另一条产品线，刻意不跟随
#if API_REGION_EN
            const string noteHowTo = "How to use SideDesk\n· Right-click the sidebar to add or edit modules\n· Drag a module's title bar to reorder\n· Change theme, language and dock side in Settings";
            const string noteWelcome = "Welcome to SideDesk!\nA smart sidebar that lives on the edge of your screen: notes, todos, shortcuts, timers... always within reach, no window switching.";
            const string groupName = "Frequent Sites";
            const string browserName = "MetaDesk";
            const string browserUrl = "https://www.desktxp.com";
            const string officialName = "Official Site";
            const string bingName = "Bing";
            const string todoEat = "Eat";
            const string todoSleep = "Sleep";
#else
            const string noteHowTo = "如何使用微屏\n· 右键侧边栏可添加/编辑卡片\n· 拖拽卡片标题栏可排序\n· 设置中可换主题、语言与停靠位置";
            const string noteWelcome = "欢迎使用微屏！\n这是一条常驻屏幕边缘的智能侧边栏：便签、待办、快捷方式、计时器……触手可及，无需切换窗口。";
            const string groupName = "常用网址";
            const string browserName = "元桌浏览器";
            const string browserUrl = "https://yzllq.com";
            const string officialName = "微屏官网";
            const string bingName = "必应";
            const string todoEat = "吃饭";
            const string todoSleep = "睡觉";
#endif
            var defaultWin = new WindowConfig
            {
                Name = Framework.Lang.T("common.home"),
                Type = WindowType.Native,
                Panels = new List<PanelItem>
                {
                    // ① 便签：使用指南 + 欢迎文案
                    new()
                    {
                        Type = PanelType.StickyNotes,
                        StickyNotes = new List<StickyNote>
                        {
                            new() { Content = noteHowTo },
                            new() { Content = noteWelcome }
                        }
                    },
                    // ② 快捷组：常用网址（单列列表）
                    new()
                    {
                        Type = PanelType.QuickGroup,
                        QuickGroupName = groupName,
                        QuickColumns = 1,
                        QuickItems = new List<QuickItem>
                        {
                            new() { Name = browserName, Type = "url", Target = browserUrl, SortIndex = 0 },
                            new() { Name = bingName, Type = "url", Target = "https://www.bing.com", SortIndex = 1 },
                            new() { Name = "DEEPSEEK", Type = "url", Target = "https://chat.deepseek.com", SortIndex = 2 },
                            new() { Name = officialName, Type = "url", Target = Constants.URLs.HomePageBaseUrl, SortIndex = 3 }
                        }
                    },
                    // ③ 分组：内嵌信号灯（红/黄/绿三灯竖排，与手动添加的默认配置一致）
                    new()
                    {
                        Type = PanelType.Group,
                        Title = Framework.Lang.T("nativePanel.newGroup"),
                        IsExpanded = true,
                        ChildPanels = new List<PanelItem>
                        {
                            new()
                            {
                                Type = PanelType.SignalLight,
                                Title = Framework.Lang.T("nativePanel.signalLight"),
                                SignalLightVertical = true,
                                SignalLights = new List<SignalLightItem>
                                {
                                    new() { Color = "#FF4444", Size = 36, Icon = "", IsOn = true },
                                    new() { Color = "#FFAA00", Size = 36, Icon = "", IsOn = true },
                                    new() { Color = "#44CC44", Size = 36, Icon = "", IsOn = true }
                                }
                            }
                        }
                    },
                    // ④ 今日待办：示例任务
                    new()
                    {
                        Type = PanelType.TodoList,
                        TodoItems = new List<TodoItem>
                        {
                            new() { Text = todoEat },
                            new() { Text = todoSleep }
                        }
                    },
                    // ⑤ 番茄闹钟：默认 25 分钟番茄钟
                    new() { Type = PanelType.Pomodoro, Pomodoro = new PomodoroSettings() }
                }
            };
            Windows.Add(defaultWin);
            LeftDock.WindowIds.Add(defaultWin.Id);
            RightDock.WindowIds.Add(defaultWin.Id);
            Save();
        }
    }

    /// <summary>
    /// 兜底保证至少存在一个 bar：所有 bar 被删光（或数据异常为空）时创建一个空的原生 bar。
    /// 否则侧边栏会 ClearContent 折叠 nativePanel → 右键失效，且空白态无「新建微屏」入口，陷入无法新增卡片的死状态。
    /// 与 EnsureDefault「首次安装播种示例面板」不同：这里只建一个空 bar（尊重用户已清空内容的意图），
    /// 空 bar 会显示「右键添加卡片」提示且右键可用。
    /// </summary>
    public void EnsureAtLeastOneBar()
    {
        if (Windows.Count > 0) return;
        AddToAllDocks(new WindowConfig
        {
            Name = Framework.Lang.T("common.home"),
            Type = WindowType.Native,
            Panels = new List<PanelItem>()
        });
    }

    /// <summary>
    /// dock 成员自愈：把 ShowInTabs=true 但不在 dock 里的窗口按 Windows 顺序补回两侧 dock。
    /// dock 状态（local_app_state）与窗口表（local_bar）是两份独立持久化：历史上「以内存为准」的
    /// 全量重写在内存为空时执行，会把 dock 写坏成只剩兜底窗口，而窗口表随后被写回/晋升补齐，
    /// 二者脱节后设置页（读 Windows）能看到窗口、主窗口标签栏（读 dock）却只剩一个。
    /// 以 ShowInTabs 为据不会复活用户主动隐藏的窗口（隐藏时 ShowInTabs=false 且已移出 dock）；
    /// 只补末尾不重建，保留用户拖拽调整过的既有标签顺序。仅修内存，随后续正常 Save 自然落库。
    /// </summary>
    public void RepairDockMembership()
    {
        bool changed = false;

        // 孤儿 id 清理：dock 里指向已不存在窗口的 id（删除/晋升剪枝硬删行时未同步清理 dock state，
        // 孤儿随 dock 晋升进入账号作用域）。孤儿占据索引会造成序号断层（标签只剩 2..N）
        // 且 ActiveIndex 落空无高亮、徽章指向不存在的项；清理后越界的 ActiveIndex 回落到末尾。
        foreach (var dock in new[] { LeftDock, RightDock })
        {
            int before = dock.WindowIds.Count;
            dock.WindowIds.RemoveAll(id => GetById(id) == null);
            if (dock.WindowIds.Count != before) changed = true;
            if (dock.ActiveIndex >= dock.WindowIds.Count)
                dock.ActiveIndex = Math.Max(0, dock.WindowIds.Count - 1);
        }

        foreach (var win in Windows)
        {
            if (!win.ShowInTabs) continue;
            if (!LeftDock.WindowIds.Contains(win.Id)) { LeftDock.WindowIds.Add(win.Id); changed = true; }
            if (!RightDock.WindowIds.Contains(win.Id)) { RightDock.WindowIds.Add(win.Id); changed = true; }
        }
        if (changed)
            Framework.RuntimeLog.Debug($"[WindowConfig] dock membership repaired: {LeftDock.WindowIds.Count} left / {RightDock.WindowIds.Count} right");
    }
}
