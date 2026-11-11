using System;
using System.Collections.Generic;
using System.IO;
using Newtonsoft.Json;
using SideDesk.Models;

namespace SideDesk.Services;

/// <summary>
/// 云空间管理服务（#339 Models 去 ActiveRecord）：原 CloudSpaceManager 静态门面改为实例服务。主存储 SQLite（local_app_state KV，原 cloud-spaces.json），首次运行自动填充内置预设。
/// </summary>
public class CloudSpaceService
{

    private const string DbKey = "cloud_spaces";
    private readonly string _filePath;
    // 由静态构造函数中的 Load() 填充；此处给空列表兜底
    private List<CloudSpace> _spaces = new List<CloudSpace>();
    private readonly object _lock = new object();

    public CloudSpaceService()
    {
        string folder = Framework.AppPaths.DataDir;
        if (!Directory.Exists(folder))
            Directory.CreateDirectory(folder);
        _filePath = Path.Combine(folder, "cloud-spaces.json");
        Load();
    }

    /// <summary>系统内置云空间预设（微屏云盘，不可删除/编辑）</summary>
    private List<CloudSpace> GetBuiltinSpaces() => new()
    {
        // #790：Id 必须固定——内置空间按 CloudSpaceId 被文件区回查，Guid.NewGuid() 会让
        // 重建（迁移/重装）后的旧导入项全部失配，点击云文件静默无反应。
        new CloudSpace { Id = CloudSpace.BuiltinSideDeskId, Name = "微屏云盘", Url = "内置", Icon = "☁️", Note = "微屏内置云存储服务", IsBuiltin = true },
    };

    private void Load()
    {
        lock (_lock)
        {
            // 主存储：SQLite；无值时从旧 cloud-spaces.json 一次性迁入
            if (LocalDbService.DbExists)
            {
                try
                {
                    string? dbJson = LocalDbService.LoadBusinessData(DbKey);
                    if (!string.IsNullOrEmpty(dbJson))
                    {
                        _spaces = JsonConvert.DeserializeObject<List<CloudSpace>>(dbJson) ?? new List<CloudSpace>();
                        MigrateBuiltins();
                        return;
                    }
                    if (File.Exists(_filePath))
                    {
                        string fileJson = File.ReadAllText(_filePath, System.Text.Encoding.UTF8);
                        _spaces = JsonConvert.DeserializeObject<List<CloudSpace>>(fileJson) ?? new List<CloudSpace>();
                        if (_spaces.Count > 0)
                            LocalDbService.SaveBusinessData(DbKey, JsonConvert.SerializeObject(_spaces));
                        MigrateBuiltins();
                        return;
                    }
                    // 首次运行：填充内置预设
                    _spaces = GetBuiltinSpaces();
                    SaveNoLock();
                    return;
                }
                catch { }
            }

            if (File.Exists(_filePath))
            {
                try
                {
                    string json = File.ReadAllText(_filePath, System.Text.Encoding.UTF8);
                    _spaces = JsonConvert.DeserializeObject<List<CloudSpace>>(json) ?? new List<CloudSpace>();
                }
                catch
                {
                    _spaces = new List<CloudSpace>();
                }
                MigrateBuiltins();
            }
            else
            {
                // 首次运行：填充内置预设
                _spaces = GetBuiltinSpaces();
                SaveNoLock();
            }
        }
    }

    /// <summary>迁移旧版内置预设：确保所有内置项存在，并移除不再是内置的旧条目</summary>
    private void MigrateBuiltins()
    {
        bool changed = false;
        var builtins = GetBuiltinSpaces();
        var builtinNames = new HashSet<string>(builtins.ConvertAll(b => b.Name));

        // 移除已不再是内置的旧条目（如旧版“百度网盘”内置项）
        int removed = _spaces.RemoveAll(s => s.IsBuiltin && !builtinNames.Contains(s.Name));
        if (removed > 0) changed = true;

        // 确保所有内置云空间始终存在
        foreach (var builtin in builtins)
        {
            var existing = _spaces.Find(s => s.IsBuiltin && s.Name == builtin.Name);
            if (existing == null)
            {
                _spaces.Insert(_spaces.FindIndex(s => s.IsBuiltin) < 0 ? 0 : _spaces.FindLastIndex(s => s.IsBuiltin) + 1, builtin);
                changed = true;
            }
            else if (existing.Id != builtin.Id)
            {
                // #790：旧版本把内置空间存成了随机 Guid，统一迁到固定 Id。
                var oldId = existing.Id;
                existing.Id = builtin.Id;
                changed = true;
                Framework.RuntimeLog.Info("Cloud", $"[CloudSpace] 内置空间 Id 迁移：{oldId} -> {builtin.Id}");
            }
        }
        if (changed) SaveNoLock();
    }

    public void Save()
    {
        lock (_lock)
            SaveNoLock();
    }

    private void SaveNoLock()
    {
        try
        {
            string json = JsonConvert.SerializeObject(_spaces, Formatting.Indented);
            if (LocalDbService.DbExists)
            {
                try { LocalDbService.SaveBusinessData(DbKey, json); return; }
                catch { }
            }
            // db 不可用/未建立：退回旧 JSON 存储
            File.WriteAllText(_filePath, json, System.Text.Encoding.UTF8);
        }
        catch { }
    }

    public List<CloudSpace> GetAll()
    {
        lock (_lock)
            return new List<CloudSpace>(_spaces);
    }

    /// <summary>云空间显示名称（内置项按当前语言翻译，用户项用原名；存储的 Name 保持不变仅作标识）</summary>
    public string GetDisplayName(CloudSpace space)
        => space.IsBuiltin ? Framework.Lang.T("cloudDrive.sideDeskDrive") : space.Name;

    /// <summary>云空间描述行（内置项显示翻译后的说明，用户项显示地址）</summary>
    public string GetDisplayUrl(CloudSpace space)
        => space.IsBuiltin ? Framework.Lang.T("cloudDrive.builtinNote") : space.Url;

    public void Add(CloudSpace space)
    {
        lock (_lock)
        {
            _spaces.Add(space);
            SaveNoLock();
        }
    }

    public void Update(CloudSpace space)
    {
        lock (_lock)
        {
            var existing = _spaces.FindIndex(s => s.Id == space.Id);
            if (existing >= 0)
                _spaces[existing] = space;
            SaveNoLock();
        }
    }

    public void Delete(string id)
    {
        lock (_lock)
        {
            // 内置云空间不可删除
            _spaces.RemoveAll(s => s.Id == id && !s.IsBuiltin);
            SaveNoLock();
        }
    }

}
