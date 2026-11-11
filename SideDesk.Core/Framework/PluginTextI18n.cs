using System;
using System.Collections.Generic;

namespace SideDesk.Framework
{
    /// <summary>
    /// 插件文本 i18n 解析：按宿主当前语言（<see cref="Lang.Current"/>）从一个
    /// {语言代码 → 文本} 字典里挑最合适的值——精确匹配 → 区域前缀匹配 → 回落。
    ///
    /// 移植说明：Windows 侧原为 Services/Plugins/PluginMarketCatalog.cs 内的
    /// `internal static class PluginTextI18n`。该逻辑本身完全框架无关（只依赖
    /// Lang.Current + Dictionary），且被 Core 的 ModuleManifest 直接使用，故按分层
    /// 解耦原则上提到 Core 并改 public（跨程序集可见）。行为与 Windows 版一致。
    /// </summary>
    public static class PluginTextI18n
    {
        public static string Resolve(Dictionary<string, string>? map, string fallback)
        {
            if (map == null || map.Count == 0) return fallback;
            var lang = Lang.Current;
            if (map.TryGetValue(lang, out var exact) && !string.IsNullOrWhiteSpace(exact)) return exact;
            foreach (var kv in map)
            {
                if (!string.IsNullOrWhiteSpace(kv.Key)
                    && lang.StartsWith(kv.Key, StringComparison.OrdinalIgnoreCase)
                    && !string.IsNullOrWhiteSpace(kv.Value))
                    return kv.Value;
            }
            return fallback;
        }
    }
}
