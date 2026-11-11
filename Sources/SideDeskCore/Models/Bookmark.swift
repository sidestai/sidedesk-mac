import Foundation

/// 书签（App 模式网址收藏）。对应 C# `Models.Bookmark`。
/// 注：C# 的 `[JsonIgnore] IntPtr WindowHandle` 运行时句柄未在 Core 保留（UI 层按 Id 侧表跟踪）。
public final class Bookmark: Codable {
    public var Id: String
    public var Name: String = ""
    public var Url: String = ""
    public var UseAppMode: Bool = false
    public var BackgroundColor: String
    public var CreatedAt: Date

    public init() {
        Id = newGuidId()
        CreatedAt = Date()
        BackgroundColor = "#3498DB"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, newGuidId())
        Name = c.or(.Name, "")
        Url = c.or(.Url, "")
        UseAppMode = c.or(.UseAppMode, false)
        BackgroundColor = c.or(.BackgroundColor, "#3498DB")
        CreatedAt = c.or(.CreatedAt, Date())
    }
}

/// 书签持久化管理器（bookmarks.json）。对应 C# `Models.BookmarkManager`。
public enum BookmarkManager {
    private static let lock = NSLock()
    private static var cache: [Bookmark]?

    private static var filePath: String {
        (AppPaths.dataDir as NSString).appendingPathComponent("bookmarks.json")
    }

    private static func loadLocked() -> [Bookmark] {
        if let cache { return cache }
        var result: [Bookmark] = []
        let path = filePath
        if FileManager.default.fileExists(atPath: path) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                result = try SideDeskJSON.decoder().decode([Bookmark].self, from: data)
            } catch {
                RuntimeLog.debug("[Bookmark] load failed: \(error.localizedDescription)")
                result = []
            }
        }
        cache = result
        return result
    }

    private static func saveLocked(_ list: [Bookmark]) {
        do {
            try FileManager.default.createDirectory(atPath: AppPaths.dataDir, withIntermediateDirectories: true)
            let data = try SideDeskJSON.encoder().encode(list)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch { /* 忽略保存错误 */ }
    }

    public static func GetAll() -> [Bookmark] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    public static func Add(_ bookmark: Bookmark) {
        lock.lock(); defer { lock.unlock() }
        var list = loadLocked()
        list.append(bookmark)
        cache = list
        saveLocked(list)
    }

    public static func Remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        var list = loadLocked()
        list.removeAll { $0.Id == id }
        cache = list
        saveLocked(list)
    }

    public static func Update(_ bookmark: Bookmark) {
        lock.lock(); defer { lock.unlock() }
        var list = loadLocked()
        if let idx = list.firstIndex(where: { $0.Id == bookmark.Id }) {
            list[idx] = bookmark
            cache = list
            saveLocked(list)
        }
    }
}
