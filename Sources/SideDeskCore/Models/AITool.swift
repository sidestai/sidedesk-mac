import Foundation

/// AI 工具快捷入口（对应 C# AITool）
public struct AITool: Codable {
    public var Id: String
    public var Name: String = ""
    public var Url: String = ""
    /// Emoji 图标字符（可选）
    public var Icon: String?
    public var BackgroundColor: String
    public var CreatedAt: Date

    public init() {
        Id = newGuidId()
        Name = ""
        Url = ""
        Icon = nil
        BackgroundColor = "#7C3AED"
        CreatedAt = Date()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, newGuidId())
        Name = c.or(.Name, "")
        Url = c.or(.Url, "")
        Icon = c.opt(.Icon)
        BackgroundColor = c.or(.BackgroundColor, "#7C3AED")
        CreatedAt = c.or(.CreatedAt, Date())
    }
}

/// AITool 持久化管理器（aitools.json，对应 C# AIToolManager）
public enum AIToolManager {
    private static let lock = NSLock()
    private static var cache: [AITool]?

    private static var filePath: String {
        (AppPaths.dataDir as NSString).appendingPathComponent("aitools.json")
    }

    private static func loadLocked() -> [AITool] {
        if let cache { return cache }
        var result: [AITool] = []
        let path = filePath
        if FileManager.default.fileExists(atPath: path) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                result = try SideDeskJSON.decoder().decode([AITool].self, from: data)
            } catch {
                RuntimeLog.debug("[AITool] load failed: \(error.localizedDescription)")
                result = []
            }
        }
        cache = result
        return result
    }

    private static func saveLocked(_ list: [AITool]) {
        do {
            try FileManager.default.createDirectory(atPath: AppPaths.dataDir, withIntermediateDirectories: true)
            let data = try SideDeskJSON.encoder().encode(list)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch { /* 忽略保存错误 */ }
    }

    public static func GetAll() -> [AITool] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    public static func Add(_ tool: AITool) {
        lock.lock(); defer { lock.unlock() }
        var list = loadLocked()
        list.append(tool)
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

    /// 测试接缝：清空内存缓存，强制下次从磁盘重载
    static func resetCache() {
        lock.lock(); defer { lock.unlock() }
        cache = nil
    }
}
