using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Newtonsoft.Json;
using SideDesk.Models;

namespace SideDesk.Services;

/// <summary>
/// 便签管理服务（#339 Models 去 ActiveRecord）：原 StickyNoteManager 静态门面改为实例服务。主存储 SQLite（local_global_note 表），首次访问时从旧 sticky-notes.json 一次性迁入。
/// </summary>
public class StickyNoteService
{

    private readonly string _filePath;
    private List<StickyNote> _notes;
    private bool _loaded;
    private readonly object _lock = new object();

    public StickyNoteService()
    {
        string folder = Framework.AppPaths.DataDir;
        if (!Directory.Exists(folder))
            Directory.CreateDirectory(folder);
        _filePath = Path.Combine(folder, "sticky-notes.json");
        _notes = new List<StickyNote>();
    }

    /// <summary>
    /// 惰性加载：主存储为 SQLite（local_global_note 表），首次访问时从旧 sticky-notes.json 一次性迁入；
    /// db 尚未建立（首启未完成 windows.json 导入）时暂用 JSON，db 就绪后的下次保存自动迁入。
    /// </summary>
    private void EnsureLoaded()
    {
        lock (_lock)
        {
            if (_loaded) return;
            _loaded = true;
            if (LocalDbService.DbExists)
            {
                try
                {
                    var dbNotes = LocalDbService.LoadGlobalNotes();
                    if (dbNotes.Count > 0)
                    {
                        _notes = dbNotes;
                        return;
                    }
                    // 表为空：从旧 JSON 一次性迁入（迁入后 JSON 仅作备份，不再读写）
                    var fileNotes = LoadFromFile();
                    if (fileNotes.Count > 0)
                        LocalDbService.SaveGlobalNotes(fileNotes);
                    _notes = fileNotes;
                    return;
                }
                catch { }
            }
            _notes = LoadFromFile();
        }
    }

    private List<StickyNote> LoadFromFile()
    {
        if (File.Exists(_filePath))
        {
            try
            {
                string json = File.ReadAllText(_filePath, System.Text.Encoding.UTF8);
                return JsonConvert.DeserializeObject<List<StickyNote>>(json) ?? new List<StickyNote>();
            }
            catch { }
        }
        return new List<StickyNote>();
    }

    /// <summary>把便签内容同步进 AI 记忆（#430）：入库幂等（内容未变则跳过）；失败不影响便签存储。</summary>
    private static void SyncToMemory(StickyNote note)
    {
        try
        {
            var content = (note.Content ?? "").Trim();
            if (content.Length == 0) return;
            var title = content.Split('\n')[0].Trim();
            if (title.Length > 40) title = title[..40];
            MemoryStoreService.Ingest("sticky:" + note.Id, title, content);
        }
        catch (Exception ex) { SideDesk.Framework.RuntimeLog.Info("[MemoryStore] sticky ingest skipped: " + ex.Message); }
    }

    public void Save()
    {
        lock (_lock)
        {
            if (LocalDbService.DbExists)
            {
                try { LocalDbService.SaveGlobalNotes(_notes); return; }
                catch { }
            }
            // db 不可用/未建立：退回旧 JSON 存储
            try
            {
                string json = JsonConvert.SerializeObject(_notes, Formatting.Indented);
                File.WriteAllText(_filePath, json, System.Text.Encoding.UTF8);
            }
            catch { }
        }
    }

    public List<StickyNote> GetAll()
    {
        lock (_lock)
        {
            EnsureLoaded();
            return _notes.OrderByDescending(n => n.UpdatedAt).ToList();
        }
    }

    public void Add(StickyNote note)
    {
        lock (_lock)
        {
            EnsureLoaded();
            _notes.Add(note);
            SyncToMemory(note);
        }
        Save();
    }

    public void Update(StickyNote note)
    {
        lock (_lock)
        {
            EnsureLoaded();
            var existing = _notes.FirstOrDefault(n => n.Id == note.Id);
            if (existing != null)
            {
                existing.Content = note.Content;
                existing.UpdatedAt = DateTime.Now;
                SyncToMemory(existing);
            }
        }
        Save();
    }

    public void Delete(string id)
    {
        lock (_lock)
        {
            EnsureLoaded();
            _notes.RemoveAll(n => n.Id == id);
        }
        NoteImageStore.DeleteNoteImages(NoteImageKind.StickyNote, id);  // #216 回收该便签的孤儿图片
        Save();
    }

    /// <summary>按 Id 查便签；不存在返回 null。</summary>
    public StickyNote? GetById(string id)
    {
        lock (_lock)
        {
            EnsureLoaded();
            return _notes.FirstOrDefault(n => n.Id == id);
        }
    }

}
