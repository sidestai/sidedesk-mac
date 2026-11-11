import Foundation

/// 多语言服务：以语义键查对应语言词典。对应 Windows C# 的 `Framework.Lang`。
///
/// 词典加载 / fallback 链 / 缺键告警逻辑与 Windows 一致；差异仅在无 XAML 标记扩展——
/// AppKit/SwiftUI 侧订阅 `subscribeChanged` 自行重绘（对应 C# 的 `Lang.Changed` 事件）。
///
/// 键约定 / fallback：当前语言词典 → en 词典（懒加载缓存）→ 键本身；
/// 中文旧键经 `langs/_legacy.json` 归一化。词典随包分发：Core 资源包里的 `langs/{代码}.json`。
public enum Lang {

    public static let auto = "auto"
    public static let zhCN = "zh-CN"
    public static let en = "en"

    /// 当前生效语言代码。
    public private(set) static var current: String = resolveSystemLanguage()

    private static let lock = NSLock()

    // 语言切换订阅者（UI 层重绘）。对应 C# `event Action? Changed`。
    private static var changedHandlers: [() -> Void] = []

    /// 订阅语言切换事件（对应 C# `Lang.Changed += handler`）。
    public static func subscribeChanged(_ handler: @escaping () -> Void) {
        lock.lock(); changedHandlers.append(handler); lock.unlock()
    }

    private static func fireChanged() {
        lock.lock(); let handlers = changedHandlers; lock.unlock()
        for h in handlers { h() }
    }

    // 外部 JSON 词典：程序包内 langs/{语言代码}.json（改翻译无需重编译）。
    // 启动时保持为空，仅在 initialize/apply 时加载。
    private static var jsonMap: [String: String] = [:]

    // 旧键映射表：langs/_legacy.json（中文原文 → 语义键），启动时加载一次。
    private static let legacyMap: [String: String] = loadJsonMap("_legacy")

    // en 兜底词典：非 en 语言首次 miss 时才解析，之后缓存复用。
    private static var enMapCache: [String: String]?
    private static var enMap: [String: String] {
        if let c = enMapCache { return c }
        let m = loadJsonMap(en)
        enMapCache = m
        return m
    }

    // 缺键告警集合（去重）。t() 可能被后台线程调用，故加锁。
    private static var missingKeys = Set<String>()

    static func loadJsonMap(_ lang: String) -> [String: String] {
        guard let url = ResourceBundles.core.url(forResource: lang, withExtension: "json", subdirectory: "langs") else {
            RuntimeLog.debug("[Lang] dictionary not found: \(lang).json")
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                return dict
            }
        } catch {
            RuntimeLog.debug("[Lang] failed to load dictionary \(lang).json: \(error.localizedDescription)")
        }
        return [:]
    }

    /// 启动时按已保存偏好初始化（不触发事件）。对应 C# `Lang.Init`。
    public static func initialize(_ preference: String) {
        current = resolve(preference)
        jsonMap = loadJsonMap(current)
        enMapCache = nil
    }

    /// 切换语言：刷新词典并触发事件（UI 层订阅重绘）。对应 C# `Lang.Apply`。
    public static func apply(_ preference: String) {
        let next = resolve(preference)
        if next == current {
            // 同语言重载路径：仅重载词典，不触发 Changed。
            jsonMap = loadJsonMap(next)
            enMapCache = nil
            return
        }
        current = next
        jsonMap = loadJsonMap(next)
        enMapCache = nil
        fireChanged()
    }

    /// 翻译：入口将中文旧键经 _legacy.json 归一化为语义键；
    /// fallback：当前语言词典 → en 词典（懒加载）→ 键本身。最终回落键本身且非 en 时记录缺键。
    public static func t(_ key: String) -> String {
        if key.isEmpty { return key }
        var k = key
        if let normalized = legacyMap[k] { k = normalized }
        if let v = jsonMap[k] { return v }
        if current != en, let ev = enMap[k] { return ev }
        if current != en {
            lock.lock(); let inserted = missingKeys.insert(k).inserted; lock.unlock()
            if inserted { RuntimeLog.debug("[Lang] missing: " + k) }
        }
        return k
    }

    /// 翻译并格式化（占位符 {0}{1}…）。对应 C# `Lang.TF`（string.Format）。
    public static func tf(_ key: String, _ args: CVarArg...) -> String {
        var result = t(key)
        for (i, a) in args.enumerated() {
            result = result.replacingOccurrences(of: "{\(i)}", with: String(describing: a))
        }
        return result
    }

    /// 将本次运行缺失的键追加写入 `{dataDir}/Logs/lang-missing.log`（退出路径调用）。
    public static func dumpMissingKeys() {
        lock.lock(); let keys = missingKeys; lock.unlock()
        guard !keys.isEmpty else { return }
        do {
            let dir = (AppPaths.dataDir as NSString).appendingPathComponent("Logs")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = (dir as NSString).appendingPathComponent("lang-missing.log")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64, size > 1024 * 1024 {
                try "".write(toFile: path, atomically: true, encoding: .utf8)
            }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            var lines = ["[\(f.string(from: Date()))] lang=\(current) missing=\(keys.count)"]
            lines.append(contentsOf: keys.sorted())
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            if FileManager.default.fileExists(atPath: path),
               let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try data.write(to: URL(fileURLWithPath: path))
            }
        } catch { /* 缺键日志写入失败不阻断退出 */ }
    }

    /// 已提供词典的语言代码。
    public static let supported: [String] =
        [zhCN, en, "zh-TW", "ja", "ko", "de", "es", "fr", "it", "pl", "ru", "pt-BR", "tr"]

    static func resolve(_ preference: String) -> String {
        if preference.isEmpty || preference == auto { return resolveSystemLanguage() }
        return supported.contains(preference) ? preference : resolveSystemLanguage()
    }

    /// 系统语言判定：映射到已提供词典的语言，无词典的回落英文。
    static func resolveSystemLanguage() -> String {
        let culture = Locale.preferredLanguages.first ?? Locale.current.identifier
        let lower = culture.lowercased()
        if lower.hasPrefix("zh") {
            let isTraditional =
                (lower.contains("-") && (lower.hasSuffix("tw") || lower.hasSuffix("hk") || lower.hasSuffix("mo")))
                || lower.contains("hant")
            return isTraditional ? "zh-TW" : zhCN
        }
        let primary = culture.split(separator: "-").first.map { $0.lowercased() } ?? ""
        switch primary {
        case "de": return "de"
        case "es": return "es"
        case "fr": return "fr"
        case "it": return "it"
        case "ja": return "ja"
        case "ko": return "ko"
        case "pl": return "pl"
        case "ru": return "ru"
        case "pt": return "pt-BR"
        case "tr": return "tr"
        default:   return en
        }
    }
}
