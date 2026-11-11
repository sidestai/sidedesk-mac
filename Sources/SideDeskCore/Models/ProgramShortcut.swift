import Foundation

/// 程序快捷方式。对应 C# `Models.ProgramShortcut`。
public final class ProgramShortcut: Codable {
    public var Id: String
    public var Name: String = ""
    public var Command: String = ""
    public var Arguments: String = ""
    public var BackgroundColor: String
    public var CreatedAt: Date

    public init() {
        Id = newGuidId()
        CreatedAt = Date()
        BackgroundColor = "#9B59B6"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, newGuidId())
        Name = c.or(.Name, "")
        Command = c.or(.Command, "")
        Arguments = c.or(.Arguments, "")
        BackgroundColor = c.or(.BackgroundColor, "#9B59B6")
        CreatedAt = c.or(.CreatedAt, Date())
    }
}

/// 程序快捷方式持久化管理器（programs.json）。对应 C# `Models.ProgramShortcutManager`。
public enum ProgramShortcutManager {
    private static let lock = NSLock()
    private static var cache: [ProgramShortcut]?

    private static var filePath: String {
        (AppPaths.dataDir as NSString).appendingPathComponent("programs.json")
    }

    private static func loadLocked() -> [ProgramShortcut] {
        if let cache { return cache }
        var result: [ProgramShortcut] = []
        let path = filePath
        if FileManager.default.fileExists(atPath: path) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                result = try SideDeskJSON.decoder().decode([ProgramShortcut].self, from: data)
            } catch {
                result = []
            }
        }
        cache = result
        return result
    }

    private static func saveLocked(_ list: [ProgramShortcut]) {
        do {
            try FileManager.default.createDirectory(atPath: AppPaths.dataDir, withIntermediateDirectories: true)
            let data = try SideDeskJSON.encoder().encode(list)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch { /* 忽略保存错误 */ }
    }

    public static func GetAll() -> [ProgramShortcut] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    public static func Add(_ shortcut: ProgramShortcut) {
        lock.lock(); defer { lock.unlock() }
        var list = loadLocked()
        list.append(shortcut)
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
}
