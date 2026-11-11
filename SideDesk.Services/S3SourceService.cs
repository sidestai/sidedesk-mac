using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json;
using SideDesk.Models;

namespace SideDesk.Services;

/// <summary>
/// S3 存储源管理服务（#339 Models 去 ActiveRecord）：原 S3SourceManager 静态门面改为实例服务。主存储 SQLite（local_app_state KV），密钥字段以 DPAPI 加密落库。Encrypt/Decrypt 为纯函数保持 static。
/// </summary>
public class S3SourceService
{

    private const string DbKey = "s3_sources";
    private readonly string _filePath;
    // 由静态构造函数中的 Load() 填充；此处给空列表兜底
    private List<S3Source> _sources = new List<S3Source>();
    private readonly object _lock = new object();

    public S3SourceService()
    {
        string folder = Framework.AppPaths.DataDir;
        if (!Directory.Exists(folder))
            Directory.CreateDirectory(folder);
        _filePath = Path.Combine(folder, "s3-sources.json");
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
                        _sources = JsonConvert.DeserializeObject<List<S3Source>>(dbJson) ?? new List<S3Source>();
                        return;
                    }
                }
                if (File.Exists(_filePath))
                {
                    string fileJson = File.ReadAllText(_filePath, Encoding.UTF8);
                    _sources = JsonConvert.DeserializeObject<List<S3Source>>(fileJson) ?? new List<S3Source>();
                    if (_sources.Count > 0 && LocalDbService.DbExists)
                        LocalDbService.SaveBusinessData(DbKey, JsonConvert.SerializeObject(_sources));
                    return;
                }
            }
            catch { }
            _sources = new List<S3Source>();
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

    public List<S3Source> GetAll()
    {
        lock (_lock)
            return new List<S3Source>(_sources);
    }

    public S3Source? Find(string id)
    {
        lock (_lock)
            return _sources.Find(s => s.Id == id);
    }

    public void Add(S3Source source)
    {
        lock (_lock)
        {
            _sources.Add(source);
            SaveNoLock();
        }
    }

    public void Update(S3Source source)
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
    // Windows 原实现用 DPAPI(ProtectedData，仅当前 Windows 用户可解密)——平台专有。
    // 分层解耦下改为委托 Core 的 Composition.SecretProtector：具体实现由各平台注册
    // (Windows=DPAPI，macOS=Keychain，Phase 3)。语义不变：空输入/失败返回空串。

    public static string Encrypt(string plain) => Composition.SecretProtector.Encrypt(plain);

    public static string Decrypt(string encryptedBase64) => Composition.SecretProtector.Decrypt(encryptedBase64);

}
