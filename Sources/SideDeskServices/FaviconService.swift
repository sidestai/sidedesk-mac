import Foundation
import SideDeskCore

/// 网站 favicon 查询/下载/缓存（对应 C# `Services.FaviconService`）：直连抓页面解析 `link[rel=icon]`，
/// 回退 `/favicon.ico`，下载到本地缓存并把「网址→本地图标路径」写进索引，避免重复拉取。
///
/// 与 C# 的差异（有意收窄，依赖未移植子系统）：CDP 浏览器兜底重抓、SVG 栅格化（#50）、
/// 程序图标提取风暴限流（`_extractThrottle`）均未接；本轮只走直连 HTTP + 负缓存 + 调用方去重。
public enum FaviconService {

    private static let lock = NSLock()
    /// 已加载索引对应的数据目录；`AppPaths.dataDir` 变了（测试隔离切换）就重载，避免用到旧目录的索引。
    private static var indexDir: String?
    private static var indexCache: [String: String] = [:]
    /// 抓取失败的网址→时刻，TTL 内不再重试（对应 C# `_fetchFailed` + `_fetchRetryInterval`）。
    private static var fetchFailed: [String: Date] = [:]
    private static let retryInterval: TimeInterval = 600   // 10 分钟

    private static var cacheDir: String { AppPaths.dataDir + "/favicons" }
    private static var indexFile: String { AppPaths.dataDir + "/favicon-cache.json" }

    /// 8s 超时 + 浏览器 UA（对应 C# `NormalUserAgent`：headless/默认 UA 会被部分站点边缘层 403）。
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        ]
        return URLSession(configuration: cfg)
    }()

    /// 测试缝隙：清空内存索引与负缓存（切换 `AppPaths` override 后调用）。
    public static func resetCacheForTests() {
        lock.lock(); defer { lock.unlock() }
        indexDir = nil
        indexCache.removeAll()
        fetchFailed.removeAll()
    }

    // MARK: - 键归一 / 路径判定

    /// 把网址归一化为源（scheme://host[:port]）作为缓存键（对应 C# `NormalizeKey`）。非 http(s) 返回 nil。
    public static func normalizeKey(_ url: String) -> String? {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = u.host, !host.isEmpty else { return nil }
        let port = u.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)"
    }

    /// 图标字符串是否为路径形式（含路径分隔符，或为实际存在的文件）。对应 C# `IsPathIcon`。
    public static func isPathIcon(_ s: String?) -> Bool {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return false }
        if s.contains("/") || s.contains("\\") { return true }
        return FileManager.default.fileExists(atPath: s)
    }

    // MARK: - 缓存命中

    /// 直接命中缓存并校验可解码：命中但内容不是图片（旧版把 HTML 错误页存成图标）则删除、返回 nil
    /// 让调用方走重抓自愈（对应 C# `GetValidCachedOrPurge`）。
    public static func validCachedOrPurge(_ url: String) -> String? {
        guard let key = normalizeKey(url) else { return nil }
        lock.lock()
        let idx = indexLocked()
        let cached = idx[key]
        lock.unlock()
        guard let cached, FileManager.default.fileExists(atPath: cached) else { return nil }
        if let bytes = try? Data(contentsOf: URL(fileURLWithPath: cached)),
           !bytes.isEmpty, guessExt(cached, Array(bytes)) != nil {
            return cached
        }
        // 坏文件：删缓存 + 移除索引，返回 nil 触发重抓
        try? FileManager.default.removeItem(atPath: cached)
        lock.lock()
        indexCache.removeValue(forKey: key)
        saveIndexLocked()
        lock.unlock()
        RuntimeLog.info("Favicon", "缓存自愈：删除不可解码的坏图标 \(cached)")
        return nil
    }

    /// 尝试直接命中缓存，返回本地 favicon 路径（未命中返回 nil）。对应 C# `TryGetCached`。
    public static func cachedPath(for url: String) -> String? {
        guard let key = normalizeKey(url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let p = indexLocked()[key], FileManager.default.fileExists(atPath: p) { return p }
        return nil
    }

    // MARK: - 异步抓取

    /// 获取网站 favicon（节流版，对应 C# `FetchFaviconThrottledAsync`）：命中缓存立即返回；
    /// TTL 内失败过则跳过；否则抓取。并发风暴由调用方（UI 层去重）+ 本函数负缓存共同抑制。
    public static func fetchFavicon(_ url: String) async -> String? {
        if let cached = validCachedOrPurge(url) { return cached }
        guard let key = normalizeKey(url) else { return nil }
        if suppressed(key) { return nil }

        let path = await fetchInner(url, key: key)
        record(key, path: path)
        return path
    }

    /// 负缓存命中（TTL 内已失败过）→ 抑制重复抓取风暴。同步封装，避免 async 上下文持锁。
    private static func suppressed(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let ts = fetchFailed[key], Date().timeIntervalSince(ts) < retryInterval { return true }
        return false
    }

    private static func record(_ key: String, path: String?) {
        lock.lock(); defer { lock.unlock() }
        if let p = path, !p.isEmpty { fetchFailed.removeValue(forKey: key) }
        else { fetchFailed[key] = Date() }
    }

    private static func fetchInner(_ url: String, key: String) async -> String? {
        // 候选：页面解析出的图标链接在前，/favicon.ico 兜底（对应 C# candidates）
        var candidates: [String] = []
        if let parsed = await resolvePageIcon(url) { candidates.append(parsed) }
        candidates.append(key.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/favicon.ico")

        for fav in candidates {
            guard let bytes = await download(fav), !bytes.isEmpty else { continue }
            guard let ext = guessExt(fav, bytes) else { continue }   // 内容非图片（HTML 错误/防爬页）→ 下一候选
            if ext == ".svg" { continue }                            // SVG 栅格化未移植，跳过
            if let saved = saveToCache(key: key, bytes: bytes, ext: ext) { return saved }
        }
        return nil
    }

    /// 抓页面 HTML 解析 `link[rel=icon]`（对应 C# `ResolvePageIconAsync` 的直连分支；CDP 兜底未接）。
    private static func resolvePageIcon(_ url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        guard let (data, _) = try? await session.data(from: u),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !html.isEmpty else { return nil }
        return parseFaviconLink(html, baseUrl: url)
    }

    private static func download(_ favUrl: String) async -> [UInt8]? {
        guard let u = URL(string: favUrl) else { return nil }
        guard let (data, resp) = try? await session.data(from: u) else { return nil }
        if let http = resp as? HTTPURLResponse, http.statusCode < 200 || http.statusCode >= 300 { return nil }
        return Array(data)
    }

    // MARK: - 解析 / 判定（纯函数，可单测）

    /// 解析页面 favicon 声明：收集全部 icon 类 link（含 apple-touch-icon），按 sizes 面积降序取最大
    /// （对应 C# `ParseFaviconLink`：首个 rel=icon 常是 16×16 低质帧，大图标放大模糊）。
    public static func parseFaviconLink(_ html: String, baseUrl: String) -> String? {
        guard let linkRe = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) else { return nil }
        let ns = html as NSString
        var best: (url: String, area: Int)?

        for m in linkRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let rel = firstGroup(#"rel\s*=\s*["']([^"']*)["']"#, in: tag)?.lowercased() else { continue }
            let relParts = rel.split(separator: " ").map(String.init)
            let isIcon = rel == "icon" || rel == "shortcut icon"
                || relParts.contains("icon") || relParts.contains("apple-touch-icon")
            guard isIcon else { continue }
            guard var href = firstGroup(#"href\s*=\s*["']([^"']+)["']"#, in: tag) else { continue }
            href = href.trimmingCharacters(in: .whitespaces)
            if href.isEmpty || href.lowercased().hasPrefix("data:") { continue }
            // 相对/协议相对路径 → 绝对
            let abs: String
            if let base = URL(string: baseUrl), let resolved = URL(string: href, relativeTo: base) {
                abs = resolved.absoluteString
            } else { continue }

            var area = 0
            if let sizes = firstGroup(#"sizes\s*=\s*["']([^"']*)["']"#, in: tag),
               let dm = try? NSRegularExpression(pattern: "(\\d+)\\s*[x×]\\s*(\\d+)", options: .caseInsensitive)
                        .firstMatch(in: sizes, range: NSRange(location: 0, length: (sizes as NSString).length)) {
                let w = Int((sizes as NSString).substring(with: dm.range(at: 1))) ?? 0
                let h = Int((sizes as NSString).substring(with: dm.range(at: 2))) ?? 0
                area = w * h
            }
            if best == nil || area > best!.area { best = (abs, area) }
        }
        return best?.url
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// 按文件魔数/扩展名推断图片格式；内容不是图片（200 返回的 HTML 错误/防爬页）返回 nil。
    /// 对应 C# `GuessExt`。
    public static func guessExt(_ url: String, _ bytes: [UInt8]) -> String? {
        if bytes.count >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50 { return ".png" }
        if bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 { return ".jpg" }
        if bytes.count >= 3 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 { return ".gif" }
        // ICO 魔数（00 00 01 00）：URL 以 .ico 结尾但内容不是 ICO 的（HTML 错误页常见）
        if bytes.count >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1 && bytes[3] == 0 { return ".ico" }
        // SVG：URL 以 .svg 结尾且内容含 <svg 标记（防反爬页顶 .svg 后缀误判）
        let path = url.split(separator: "?").first.map(String.init)?.lowercased() ?? ""
        if path.hasSuffix(".svg") {
            let head = String(bytes.prefix(512).map { Character(UnicodeScalar($0)) })
            if head.contains("<svg") { return ".svg" }
        }
        // 内容以 '<' 开头（跳过前导空白）= HTML/XML，不是图片 → nil 让调用方试下一候选
        for b in bytes {
            if b == 0x3C { return nil }
            if b != 0x20 && b != 0x09 && b != 0x0D && b != 0x0A { break }
        }
        if path.hasSuffix(".png") { return ".png" }
        if path.hasSuffix(".jpg") || path.hasSuffix(".jpeg") { return ".jpg" }
        if path.hasSuffix(".gif") { return ".gif" }
        if path.hasSuffix(".svg") { return ".svg" }
        return path.hasSuffix(".ico") ? ".ico" : nil
    }

    // MARK: - 落盘（调用方持锁或内部加锁）

    private static func saveToCache(key: String, bytes: [UInt8], ext: String) -> String? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            let localPath = cacheDir + "/" + safeFileName(key) + ext
            try Data(bytes).write(to: URL(fileURLWithPath: localPath))
            lock.lock()
            _ = indexLocked()
            indexCache[key] = localPath
            saveIndexLocked()
            lock.unlock()
            RuntimeLog.debug("Favicon", "cached \(key) -> \(localPath) (\(bytes.count)B)")
            return localPath
        } catch {
            RuntimeLog.debug("Favicon", "save failed \(key): \(error.localizedDescription)")
            return nil
        }
    }

    private static func safeFileName(_ key: String) -> String {
        key.replacingOccurrences(of: "://", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
    }

    /// 取内存索引（必要时从磁盘重载）。调用方须持锁。
    private static func indexLocked() -> [String: String] {
        if indexDir != AppPaths.dataDir {
            indexCache = loadIndexFromDisk()
            indexDir = AppPaths.dataDir
        }
        return indexCache
    }

    private static func loadIndexFromDisk() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexFile)),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    /// 持久化索引。调用方须持锁。
    private static func saveIndexLocked() {
        guard let data = try? JSONEncoder().encode(indexCache) else { return }
        try? FileManager.default.createDirectory(atPath: AppPaths.dataDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: indexFile))
    }
}
