using System;
using System.IO;
using System.Linq;
using Newtonsoft.Json.Linq;

namespace SideDesk.Framework;

/// <summary>
/// 调参数据层（#78）：读 resources/tuning.json，改文件即生效（FileSystemWatcher 热加载），
/// **无需编译、无需重启**。与边车（gateway/src/config/resources.ts）共用同一份数据文件——
/// 边车经 SD_RESOURCES_DIR 指向同一目录，两侧参数永远一致。
/// 仅承载参数与文案；逻辑仍留在代码里（见 issue #78 的边界说明）。
///
/// <para><b>section 与 key 都按点号路径解析</b>，拼接后从根查找，因此
/// <c>("voice.ns", "enabled")</c> 与 <c>("voice", "ns.enabled")</c> 取到的是同一个值。
/// 调用点两种写法都有，本类都支持。</para>
///
/// <para><b>但 JSON 必须是嵌套的</b>：取值走 <see cref="JToken.SelectToken(string, bool)"/>，
/// 所以 <c>"voice": { "ns": { "enabled": false } }</c> 能找到，
/// 而把 <c>"voice.ns"</c> 写成**顶层平铺的键**则找不到（点号在路径里是分隔符，不是名字的一部分）。
/// 这与本文件里 voice.* 的既有形状一致，不必改动数据。</para>
/// </summary>
public static class Tuning
{
    static Tuning() => StartWatching(); // 首次触达即开始热加载监视（幂等）

    private static readonly object _gate = new();
    private static JObject? _root;
    private static FileSystemWatcher? _watcher;
    private static string? _dir;

    /// <summary>资源目录：输出目录下 resources（安装态）→ 仓库 src/SideDesk/resources（开发态）。</summary>
    public static string ResourcesDir
    {
        get
        {
            if (_dir != null) return _dir;
            var candidates = new[]
            {
                Path.Combine(AppContext.BaseDirectory, "resources"),
                Path.Combine(FindRepoRoot(), "src", "SideDesk", "resources"),
            };
            foreach (var c in candidates)
                if (Directory.Exists(c)) { _dir = c; break; }
            _dir ??= candidates[1];
            return _dir;
        }
    }

    private static string FilePath => Path.Combine(ResourcesDir, "tuning.json");

    /// <summary>起始监视（幂等）：tuning.json 变动即清缓存，下次读取生效。</summary>
    public static void StartWatching()
    {
        lock (_gate)
        {
            if (_watcher != null) return;
            try
            {
                var dir = ResourcesDir;
                if (!Directory.Exists(dir)) return;
                _watcher = new FileSystemWatcher(dir, "tuning.json")
                {
                    NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size,
                    EnableRaisingEvents = true,
                };
                FileSystemEventHandler onChanged = (_, _) =>
                {
                    lock (_gate) { _root = null; }
                    RuntimeLog.Info("[Tuning] tuning.json changed, reloaded");
                };
                _watcher.Changed += onChanged;
                _watcher.Created += onChanged;
                _watcher.Renamed += (_, _) => onChanged(null!, null!);
            }
            catch (Exception ex)
            {
                RuntimeLog.Info("[Tuning] watcher start failed: " + ex.Message);
            }
        }
    }

    /// <summary>整份 tuning.json 的解析结果（缓存）。缺失/损坏/非对象 → 空对象，于是全部回退默认。</summary>
    private static JObject Root()
    {
        lock (_gate)
        {
            if (_root != null) return _root;
            try
            {
                _root = File.Exists(FilePath) ? JObject.Parse(File.ReadAllText(FilePath)) : new JObject();
            }
            catch (Exception ex)
            {
                RuntimeLog.Info("[Tuning] parse failed (fallback to defaults): " + ex.Message);
                _root = new JObject();
            }
            return _root;
        }
    }

    /// <summary>
    /// 把 <paramref name="section"/> + <paramref name="key"/> 解析成一个取值。
    /// 两者都按点号路径处理（拼接后从根找），所以两种调用约定都能命中同一处配置。
    /// <para>
    /// **这里以前是坏过的**：老实现是 <c>Root()[section][key]</c>，只认"顶层平铺的 section +
    /// 直接子键"，于是 <c>("voice.ns", "enabled")</c> 与 <c>("voice", "ns.enabled")</c> **都取不到** ——
    /// <c>voice</c> 段嵌套深了一层，两种写法各差一步。当时 27 处 <c>voice.*</c> 读的全是代码
    /// fallback，tuning.json 里的 voice 段是死配置（而那一版的值与 fallback 恰好逐一相同，
    /// 所以没人看出来）。现在两种写法都真能读到。
    /// </para>
    /// </summary>
    private static JToken? Resolve(string section, string key)
    {
        var path = string.IsNullOrEmpty(section) ? key : section + "." + key;
        try { return Root().SelectToken(path, errorWhenNoMatch: false); }
        catch { return null; }   // 路径语法非法（键名里带 [ ] 等）按"取不到"处理，不把异常抛给调用方
    }

    /// <summary>取数字（缺失/非法回退默认）。</summary>
    public static double Number(string section, string key, double fallback)
    {
        var t = Resolve(section, key);
        if (t != null && (t.Type == JTokenType.Float || t.Type == JTokenType.Integer))
            return t.ToObject<double>();
        return fallback;
    }

    /// <summary>取整数（缺失/非法回退默认）。</summary>
    public static int Int(string section, string key, int fallback) => (int)Number(section, key, fallback);

    /// <summary>
    /// 取布尔（缺失/非法回退默认）。**只接受 JSON 真布尔**——写成字符串 "true"/数字 1 都按缺失处理。
    /// 这么定是为了让"配错了"和"没配"表现一致（都回退默认），而不是让错值悄悄变成 true。
    /// </summary>
    public static bool Bool(string section, string key, bool fallback)
    {
        var t = Resolve(section, key);
        if (t != null && t.Type == JTokenType.Boolean) return t.ToObject<bool>();
        return fallback;
    }

    /// <summary>取字符串（缺失/非法回退默认）。</summary>
    public static string String(string section, string key, string fallback)
    {
        var t = Resolve(section, key);
        if (t != null && t.Type == JTokenType.String) return t.ToObject<string>() ?? fallback;
        return fallback;
    }

    /// <summary>
    /// 取字符串数组（缺失/非法/含非字符串项回退默认）。两侧共享的清单（如任务前缀）走这里——
    /// ADR-0013：宿主与边车同读 tuning.json 同一键，不再各写一份硬编码（散弹式修改点之一）。
    /// </summary>
    public static string[] Strings(string section, string key, string[] fallback)
    {
        if (Resolve(section, key) is JArray arr && arr.All(t => t.Type == JTokenType.String))
        {
            var values = arr.Select(t => (string?)t).Where(v => !string.IsNullOrEmpty(v)).Cast<string>().ToArray();
            if (values.Length > 0) return values;
        }
        return fallback;
    }

    /// <summary>取提示词（resources/prompts/{name}.md）：改文件即生效；缺失回退内置兜底。</summary>
    public static string Prompt(string name, string fallback)
    {
        try
        {
            var path = Path.Combine(ResourcesDir, "prompts", name + ".md");
            if (!File.Exists(path)) return fallback;
            var text = File.ReadAllText(path).Trim();
            return text.Length > 0 ? text : fallback;
        }
        catch
        {
            return fallback;
        }
    }

    /// <summary>测试用：清缓存并指定目录（null 恢复正常解析）。</summary>
    internal static void ResetForTest(string? dir = null)
    {
        lock (_gate)
        {
            _root = null;
            _watcher?.Dispose();
            _watcher = null;
            _dir = dir;
        }
    }

    private static string FindRepoRoot()
    {
        var d = AppContext.BaseDirectory;
        while (d != null && !File.Exists(Path.Combine(d, "SideDesk.slnx")))
            d = Directory.GetParent(d)?.FullName;
        return d ?? AppContext.BaseDirectory;
    }
}
