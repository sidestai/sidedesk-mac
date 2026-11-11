// Ported from Windows Models/DigitalEmployee.cs L40-131 (DigitalEmployeeManager).
// Persistence orchestrator -> SERVICE layer (see WindowConfigManager.cs note).
using System.IO;
using Newtonsoft.Json;

namespace SideDesk.Models;

/// <summary>
/// 数字员工全局管理器：所有员工统一存储，卡片中通过 Id 引用需要展示的员工
/// </summary>
public class DigitalEmployeeManager
{
    private const string DbKey = "digital_employees";
    private static readonly string _filePath = Path.Combine(
        Framework.AppPaths.DataDir, "digital-employees.json");

    public List<DigitalEmployee> Employees { get; set; } = new();

    public static DigitalEmployeeManager Load()
    {
        try
        {
            // 主存储：SQLite（local_app_state KV）；无值时从旧 digital-employees.json 一次性迁入
            if (Services.LocalDbService.DbExists)
            {
                string? dbJson = Services.LocalDbService.LoadBusinessData(DbKey);
                if (!string.IsNullOrEmpty(dbJson))
                    return JsonConvert.DeserializeObject<DigitalEmployeeManager>(dbJson) ?? new DigitalEmployeeManager();
                if (File.Exists(_filePath))
                {
                    var fileJson = File.ReadAllText(_filePath);
                    var mgr = JsonConvert.DeserializeObject<DigitalEmployeeManager>(fileJson);
                    if (mgr != null)
                    {
                        if (mgr.Employees.Count > 0)
                            Services.LocalDbService.SaveBusinessData(DbKey, JsonConvert.SerializeObject(mgr));
                        return mgr;
                    }
                }
                return new DigitalEmployeeManager();
            }
            if (File.Exists(_filePath))
            {
                var json = File.ReadAllText(_filePath);
                return JsonConvert.DeserializeObject<DigitalEmployeeManager>(json) ?? new DigitalEmployeeManager();
            }
        }
        catch { }
        return new DigitalEmployeeManager();
    }

    public void Save()
    {
        try
        {
            var dir = Path.GetDirectoryName(_filePath)!;
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            var json = JsonConvert.SerializeObject(this, Formatting.Indented);
            if (Services.LocalDbService.DbExists)
            {
                try { Services.LocalDbService.SaveBusinessData(DbKey, json); return; }
                catch { }
            }
            // db 不可用/未建立：退回旧 JSON 存储
            File.WriteAllText(_filePath, json);
        }
        catch { }
    }

    public DigitalEmployee? GetById(string id) => Employees.FirstOrDefault(e => e.Id == id);

    public DigitalEmployee Add(string? name = null)
    {
        name ??= Framework.Lang.T("digitalEmployee.newEmployee");
        var emp = new DigitalEmployee { Name = name };
        Employees.Add(emp);
        Save();
        return emp;
    }

    public void Remove(string id)
    {
        Employees.RemoveAll(e => e.Id == id);
        Save();
    }

    /// <summary>首次使用时填充几个示例员工</summary>
    public void EnsureDefault()
    {
        if (Employees.Count == 0)
        {
            Employees.Add(new DigitalEmployee { Name = "小智", Emoji = "🤖", Role = "AI 助理", Department = "智能中台", Description = "负责日常问答与信息检索。", Skills = "问答、检索、总结" });
            Employees.Add(new DigitalEmployee { Name = "文心", Emoji = "✍️", Role = "文案专员", Department = "内容组", Description = "负责文案撰写与润色。", Skills = "写作、润色、翻译" });
            Employees.Add(new DigitalEmployee { Name = "数据侠", Emoji = "📊", Role = "数据分析", Department = "数据组", Description = "负责数据统计与可视化。", Skills = "统计、报表、分析" });
            Save();
        }
    }
}
