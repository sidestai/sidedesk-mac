using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;

namespace SideDesk.Framework
{
    /// <summary>
    /// 多语言服务（Core 移植版）：以语义键查对应语言词典。
    ///
    /// 与 Windows 版 (SideDesk/Framework/Lang.cs) 的差异——仅剥离 WPF 专有部分，
    /// 词典加载 / fallback 链 / 缺键告警 / culture 设置逻辑保持一致：
    ///  - 去掉 `using System.Windows` / `System.Windows.Markup`；
    ///  - 去掉 XAML 标记扩展 `TExtension` 与 `Register/RefreshRegistrations/_registrations`
    ///    （AppKit 侧无 DependencyProperty，切换语言由 UI 层自行订阅 <see cref="Changed"/> 重绘）；
    ///  - `ApplyCulture` 去掉遍历 Application.Current.Windows 设置 XmlLanguage 的分支。
    ///
    /// 键约定 / fallback：当前语言词典 → en 词典（懒加载缓存）→ 键本身；
    /// 中文旧键经 langs/_legacy.json 归一化。词典：{BaseDirectory}/langs/{代码}.json。
    /// </summary>
    public static class Lang
    {
        public const string Auto = "auto";
        public const string ZhCN = "zh-CN";
        public const string En = "en";

        /// <summary>当前生效语言代码（zh-CN / en / zh-TW / ja / ko / de / es / fr / it / pl / ru / pt-BR / tr）</summary>
        public static string Current { get; private set; } = ResolveSystemLanguage();

        /// <summary>语言切换事件（UI 线程外触发时订阅方自行调度）</summary>
        public static event Action? Changed;

        // 外部 JSON 词典：程序目录 langs/{语言代码}.json（改翻译无需重新编译）。
        // 启动时保持为空，仅在 Init/Apply 时加载（修复旧版静态初始化 + Init 的双重加载）。
        private static Dictionary<string, string> _jsonMap = new();

        // 旧键映射表：langs/_legacy.json（中文原文 → 语义键），启动时加载一次，用于 T() 入口归一化。
        private static readonly Dictionary<string, string> _legacyMap = LoadJsonMap("_legacy");

        // en 兜底词典：非 en 语言首次 miss 时才解析，之后缓存复用；当前语言为 en 时不加载（主词典即 en）。
        private static Dictionary<string, string>? _enMap;
        private static Dictionary<string, string> EnMap => _enMap ??= LoadJsonMap(En);

        // 缺键告警集合（去重）。T() 可能被后台线程调用，故用线程安全的 ConcurrentDictionary。
        private static readonly ConcurrentDictionary<string, byte> _missingKeys = new();

        private static Dictionary<string, string> LoadJsonMap(string lang)
        {
            try
            {
                string path = System.IO.Path.Combine(AppContext.BaseDirectory, "langs", lang + ".json");
                if (System.IO.File.Exists(path))
                {
                    var dict = Newtonsoft.Json.JsonConvert.DeserializeObject<Dictionary<string, string>>(
                        System.IO.File.ReadAllText(path, System.Text.Encoding.UTF8));
                    if (dict != null) return dict;
                }
            }
            catch (Exception ex)
            {
                // 词典文件缺失或损坏时回落为空词典（最终回落键本身）
                Framework.RuntimeLog.Debug($"[Lang] failed to load dictionary {lang}.json: {ex.Message}");
            }
            return new Dictionary<string, string>();
        }

        /// <summary>启动时按已保存偏好初始化（不触发事件）</summary>
        public static void Init(string preference)
        {
            Current = Resolve(preference);
            _jsonMap = LoadJsonMap(Current);
            _enMap = null; // 重新加载时清空 en 兜底缓存，支持运行中修改翻译
            ApplyCulture();
        }

        /// <summary>切换语言：刷新线程文化并触发事件（AppKit 侧订阅 Changed 重绘）</summary>
        public static void Apply(string preference)
        {
            string next = Resolve(preference);
            if (next == Current)
            {
                // 同语言重载路径：仅重载词典，不更新线程文化、不触发 Changed 事件。
                _jsonMap = LoadJsonMap(next); // 同语言下重新加载词典，支持运行中修改翻译
                _enMap = null;
                return;
            }
            Current = next;
            _jsonMap = LoadJsonMap(next);
            _enMap = null;
            ApplyCulture();
            Changed?.Invoke();
        }

        /// <summary>
        /// 翻译：入口将中文旧键经 _legacy.json 归一化为语义键；
        /// fallback 链：当前语言词典 → en 词典（懒加载）→ 键本身。
        /// 最终回落键本身且非 en 时记录缺键。
        /// </summary>
        public static string T(string key)
        {
            if (string.IsNullOrEmpty(key)) return key;
            // 入口归一化：中文旧键 → 语义新键（语义键不命中则原样使用，新旧键同轨）
            if (_legacyMap.TryGetValue(key, out var normalized)) key = normalized;
            if (_jsonMap.TryGetValue(key, out var jsonValue)) return jsonValue;
            // en 兜底：当前语言为 en 时主词典即兜底，不重复加载
            if (Current != En && EnMap.TryGetValue(key, out var enValue)) return enValue;
            if (Current != En && _missingKeys.TryAdd(key, 0))
            {
                Framework.RuntimeLog.Debug("[Lang] missing: " + key);
            }
            return key;
        }

        /// <summary>将本次运行中缺失的键追加写入 {LocalApplicationData}/SideDesk/Logs/lang-missing.log（退出路径调用）</summary>
        public static void DumpMissingKeys()
        {
            try
            {
                if (_missingKeys.Count == 0) return;
                string dir = System.IO.Path.Combine(AppPaths.DataDir, "Logs");
                System.IO.Directory.CreateDirectory(dir);
                string path = System.IO.Path.Combine(dir, "lang-missing.log");
                // 防止日志无限增长：超过 1MB 时先清空再写（简单轮转）
                var fi = new System.IO.FileInfo(path);
                if (fi.Exists && fi.Length > 1024 * 1024)
                {
                    System.IO.File.WriteAllText(path, string.Empty, System.Text.Encoding.UTF8);
                }
                var lines = new List<string>
                {
                    $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] lang={Current} missing={_missingKeys.Count}"
                };
                // Keys 快照遍历（ConcurrentDictionary 枚举是线程安全的）
                lines.AddRange(_missingKeys.Keys.OrderBy(k => k, StringComparer.Ordinal));
                System.IO.File.AppendAllLines(path, lines, System.Text.Encoding.UTF8);
            }
            catch { /* 缺键日志写入失败不阻断退出 */ }
        }

        /// <summary>
        /// 翻译并格式化（占位符 {0}{1}...）。
        /// args 声明为 object?[]（与 string.Format 一致）。
        /// </summary>
        public static string TF(string key, params object?[] args)
        {
            try { return string.Format(T(key), args); }
            catch { return T(key); }
        }

        // 已提供词典的语言代码（对应 langs/{代码}.json）
        private static readonly string[] Supported = { ZhCN, En, "zh-TW", "ja", "ko", "de", "es", "fr", "it", "pl", "ru", "pt-BR", "tr" };

        /// <summary>已提供词典的语言代码（外部校验用）。</summary>
        public static IReadOnlyList<string> SupportedLanguages => Supported;

        private static string Resolve(string preference)
        {
            if (string.IsNullOrEmpty(preference) || preference == Auto) return ResolveSystemLanguage();
            return Array.IndexOf(Supported, preference) >= 0 ? preference : ResolveSystemLanguage();
        }

        /// <summary>系统语言判定：映射到已提供词典的语言，无词典的回落英文</summary>
        private static string ResolveSystemLanguage()
        {
            try
            {
                string culture = CultureInfo.CurrentUICulture.Name;
                if (culture.StartsWith("zh", StringComparison.OrdinalIgnoreCase))
                {
                    // 繁体系：zh-TW / zh-HK / zh-MO / zh-Hant
                    return (culture.Contains('-') && (culture.EndsWith("TW", StringComparison.OrdinalIgnoreCase)
                            || culture.EndsWith("HK", StringComparison.OrdinalIgnoreCase)
                            || culture.EndsWith("MO", StringComparison.OrdinalIgnoreCase)))
                           || culture.IndexOf("Hant", StringComparison.OrdinalIgnoreCase) >= 0
                        ? "zh-TW" : ZhCN;
                }
                string primary = culture.Split('-')[0].ToLowerInvariant();
                return primary switch
                {
                    "de" => "de",
                    "es" => "es",
                    "fr" => "fr",
                    "it" => "it",
                    "ja" => "ja",
                    "ko" => "ko",
                    "pl" => "pl",
                    "ru" => "ru",
                    "pt" => "pt-BR",
                    "tr" => "tr",
                    _ => En
                };
            }
            catch { return ZhCN; }
        }

        private static void ApplyCulture()
        {
            try
            {
                string cultureName = Current switch
                {
                    ZhCN => "zh-CN",
                    "zh-TW" => "zh-TW",
                    "pt-BR" => "pt-BR",
                    En => "en-US",
                    _ => Current
                };
                var culture = new CultureInfo(cultureName);
                Thread.CurrentThread.CurrentCulture = culture;
                Thread.CurrentThread.CurrentUICulture = culture;
                CultureInfo.DefaultThreadCurrentCulture = culture;
                CultureInfo.DefaultThreadCurrentUICulture = culture;
            }
            catch { /* 文化设置失败不阻断 */ }
        }
    }
}
