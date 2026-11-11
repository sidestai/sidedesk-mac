import Foundation
import SideDeskCore

/// 数字员工全局管理器：所有员工统一存储，卡片中通过 Id 引用（对应 C# DigitalEmployeeManager）。
/// 主存储：SQLite（local_app_state KV，键 "digital_employees"）；无值时从旧 digital-employees.json 一次性迁入。
public final class DigitalEmployeeManager: Codable {
    private static let dbKey = "digital_employees"

    private static var filePath: String {
        (AppPaths.dataDir as NSString).appendingPathComponent("digital-employees.json")
    }

    public var Employees: [DigitalEmployee] = []

    public init() {}

    public static func load() -> DigitalEmployeeManager {
        do {
            if LocalDbService.dbExists {
                if let dbJson = LocalDbService.loadBusinessData(dbKey), !dbJson.isEmpty,
                   let data = dbJson.data(using: .utf8),
                   let mgr = try? SideDeskJSON.decoder().decode(DigitalEmployeeManager.self, from: data) {
                    return mgr
                }
                // KV 无值：尝试从旧 JSON 文件一次性迁入
                if let mgr = readFromFile() {
                    if !mgr.Employees.isEmpty,
                       let data = try? SideDeskJSON.encoder().encode(mgr),
                       let s = String(data: data, encoding: .utf8) {
                        LocalDbService.saveBusinessData(dbKey, s)
                    }
                    return mgr
                }
                return DigitalEmployeeManager()
            }
            if let mgr = readFromFile() { return mgr }
        }
        return DigitalEmployeeManager()
    }

    public func save() {
        guard let data = try? SideDeskJSON.encoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return }
        if LocalDbService.dbExists {
            LocalDbService.saveBusinessData(Self.dbKey, json)
            return
        }
        // db 不可用/未建立：退回旧 JSON 存储
        do {
            try FileManager.default.createDirectory(atPath: AppPaths.dataDir, withIntermediateDirectories: true)
            try json.write(toFile: Self.filePath, atomically: true, encoding: .utf8)
        } catch { /* 忽略 */ }
    }

    private static func readFromFile() -> DigitalEmployeeManager? {
        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return nil }
        return try? SideDeskJSON.decoder().decode(DigitalEmployeeManager.self, from: data)
    }

    public func getById(_ id: String) -> DigitalEmployee? {
        Employees.first { $0.Id == id }
    }

    @discardableResult
    public func add(name: String? = nil) -> DigitalEmployee {
        var emp = DigitalEmployee()
        emp.Name = name ?? Lang.t("digitalEmployee.newEmployee")
        Employees.append(emp)
        save()
        return emp
    }

    public func remove(_ id: String) {
        Employees.removeAll { $0.Id == id }
        save()
    }

    /// 首次使用时填充几个示例员工
    public func ensureDefault() {
        guard Employees.isEmpty else { return }
        Employees.append(makeSample("小智", "🤖", "AI 助理", "智能中台", "负责日常问答与信息检索。", "问答、检索、总结"))
        Employees.append(makeSample("文心", "✍️", "文案专员", "内容组", "负责文案撰写与润色。", "写作、润色、翻译"))
        Employees.append(makeSample("数据侠", "📊", "数据分析", "数据组", "负责数据统计与可视化。", "统计、报表、分析"))
        save()
    }

    private func makeSample(_ name: String, _ emoji: String, _ role: String, _ dept: String, _ desc: String, _ skills: String) -> DigitalEmployee {
        var e = DigitalEmployee()
        e.Name = name; e.Emoji = emoji; e.Role = role; e.Department = dept; e.Description = desc; e.Skills = skills
        return e
    }
}
