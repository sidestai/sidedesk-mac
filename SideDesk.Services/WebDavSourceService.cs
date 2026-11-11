using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json;
using SideDesk.Models;

namespace SideDesk.Services;

/// <summary>
/// WebDAV 存储源管理服务（#339 Models 去 ActiveRecord）：原 WebDavSourceManager 静态门面改为实例服务。主存储 SQLite（local_app_state KV），密码字段以 DPAPI 加密落库。Encrypt/Decrypt 为纯函数保持 static。
/// </summary>
public class WebDavSourceService
{

    private const string DbKey = "webdav_sources";
    private readonly string _filePath;
    // 由静态构造函数中的 Load() 填充；此处给空列表兜底
    private List<WebDavSource> _sources = new List<WebDavSource>();
    private readonly object _lock = new object();

    public WebDavSourceService()
    {
        string folder = Framework.AppPaths.DataDir;
        if (!Directory.Exists(folder))
            Directory.CreateDirectory(folder);
        _filePath = Path.Combine(folder, "webdav-sources.json");
        Load();
    }

    private void Load()
    {
        lock (_lock)
        {
            try
            {
                if (LocalDbService.DbExists)
                {
                    string? dbJson = LocalDbService.LoadBusinessData(DbKey);
                    if (!string.IsNullOrEmpty(dbJson))
                    {
                        _sources = JsonConvert.DeserializeObject<List<WebDavSource>>(dbJson) ?? new List<WebDavSource>();
                        return;
                    }
                }
                if (File.Exists(_filePath))
                {
                    string fileJson = File.ReadAllText(_filePath, Encoding.UTF8);
                    _sources = JsonConvert.DeserializeObject<List<WebDavSource>>(fileJson) ?? new List<WebDavSource>();
                    if (_sources.Count > 0 && LocalDbService.DbExists)
                        LocalDbService.SaveBusinessData(DbKey, JsonConvert.SerializeObject(_sources));
                    return;
                }
            }
            catch { }
            _sources = new List<WebDavSource>();
        }
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
            string json = JsonConvert.SerializeObject(_sources, Formatting.Indented);
            if (LocalDbService.DbExists)
            {
                try { LocalDbService.SaveBusinessData(DbKey, json); return; }
                catch { }
            }
            File.WriteAllText(_filePath, json, Encoding.UTF8);
        }
        catch { }
    }

    public List<WebDavSource> GetAll()
    {
        lock (_lock)
            return new List<WebDavSource>(_sources);
    }

    public WebDavSource? Find(string id)
    {
        lock (_lock)
            return _sources.Find(s => s.Id == id);
    }

    public void Add(WebDavSource source)
    {
        lock (_lock)
        {
            _sources.Add(source);
            SaveNoLock();
        }
    }

    public void Update(WebDavSource source)
    {
        lock (_lock)
        {
            int idx = _sources.FindIndex(s => s.Id == source.Id);
            if (idx >= 0)
                _sources[idx] = source;
            SaveNoLock();
        }
    }

    public void Delete(string id)
    {
        lock (_lock)
        {
            _sources.RemoveAll(s => s.Id == id);
            SaveNoLock();
        }
    }

    // ===== 加解密：经 ISecretProtector 接缝 =====
    // Windows 原实现用 DPAPI(ProtectedData)——平台专有。分层解耦下改为委托 Core 的
    // Composition.SecretProtector：具体实现由各平台注册(Windows=DPAPI，macOS=Keychain，
    // Phase 3)。语义不变：空输入/失败返回空串。

    public static string Encrypt(string plain) => Composition.SecretProtector.Encrypt(plain);

    public static string Decrypt(string encryptedBase64) => Composition.SecretProtector.Decrypt(encryptedBase64);

}
