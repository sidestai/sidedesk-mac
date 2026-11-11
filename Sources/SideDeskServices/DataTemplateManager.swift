import Foundation
import SideDeskCore

/// 数据模板管理器：内置模板（随包只读资源 Bundle.module/data-templates/*.json）
/// + 用户自建模板（AppPaths.dataDir/user-templates.json，可写、升级不丢）
/// （对应 C# Models.DataTemplateManager）。
public final class DataTemplateManager {

    private static var userDataDir: String { AppPaths.dataDir }

    private static var userTemplatesFile: String {
        (userDataDir as NSString).appendingPathComponent("user-templates.json")
    }

    /// 用户自建模板文件路径（供删除逻辑与云同步引用，避免各处硬编码）
    public static var userTemplatesFilePath: String { userTemplatesFile }

    /// 内置模板删除黑名单：内置文件随包恢复，删除记录持久化到用户目录
    private static var deletedBuiltinsFile: String {
        (userDataDir as NSString).appendingPathComponent("deleted-builtins.json")
    }

    public var Templates: [DataTemplate] = []

    public init() {}

    private static func loadDeletedIds() -> [String] {
        guard FileManager.default.fileExists(atPath: deletedBuiltinsFile),
              let data = try? Data(contentsOf: URL(fileURLWithPath: deletedBuiltinsFile)),
              let ids = try? SideDeskJSON.decoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    private static func writeDeletedIds(_ ids: [String]) {
        do {
            try FileManager.default.createDirectory(atPath: userDataDir, withIntermediateDirectories: true)
            let data = try SideDeskJSON.encoder().encode(ids)
            try data.write(to: URL(fileURLWithPath: deletedBuiltinsFile), options: .atomic)
        } catch { /* 忽略 */ }
    }

    /// 记录删除（对内置模板生效；用户模板直接改 user-templates.json，同时入黑名单无害）
    public static func markDeleted(_ templateId: String) {
        var ids = loadDeletedIds()
        guard !ids.contains(templateId) else { return }
        ids.append(templateId)
        writeDeletedIds(ids)
    }

    /// 本 target 的随包资源（解析口径见 `ResourceBundles`）
    private static var bundledTemplates: Bundle {
        ResourceBundles.bundle(named: "SidestMac_SideDeskServices", fallback: Bundle.module)
    }

    /// 加载模板：内置（随包 `data-templates/*.json`，只读）+ 用户自建（可写），再过滤已删除内置项
    public static func load() -> DataTemplateManager {
        let manager = DataTemplateManager()

        // 1) 内置模板：遍历随包资源里的 *.json
        if let urls = bundledTemplates.urls(forResourcesWithExtension: "json", subdirectory: "data-templates") {
            for url in urls {
                do {
                    let data = try Data(contentsOf: url)
                    let templates = try SideDeskJSON.decoder().decode([DataTemplate].self, from: data)
                    manager.Templates.append(contentsOf: templates)
                } catch {
                    RuntimeLog.debug("[DataTemplate] failed to load template file \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        // 2) 用户自建模板
        manager.Templates.append(contentsOf: loadUserTemplates())

        // 3) 过滤已删除的内置模板
        let deleted = loadDeletedIds()
        if !deleted.isEmpty {
            manager.Templates.removeAll { deleted.contains($0.Id) }
        }

        return manager
    }

    /// 仅加载用户自建模板（user-templates.json），不含内置模板
    public static func loadUserTemplates() -> [DataTemplate] {
        guard FileManager.default.fileExists(atPath: userTemplatesFile),
              let data = try? Data(contentsOf: URL(fileURLWithPath: userTemplatesFile)),
              let list = try? SideDeskJSON.decoder().decode([DataTemplate].self, from: data) else { return [] }
        return list
    }

    /// 保存用户自建模板到 user-templates.json（重新保存视为恢复：从删除黑名单移除）
    public func saveUserTemplate(_ template: DataTemplate) {
        // 从黑名单移除（若存在）
        var deleted = Self.loadDeletedIds()
        if let idx = deleted.firstIndex(of: template.Id) {
            deleted.remove(at: idx)
            Self.writeDeletedIds(deleted)
        }

        var userTemplates = Self.loadUserTemplates()
        if let idx = userTemplates.firstIndex(where: { $0.Id == template.Id }) {
            userTemplates[idx] = template
        } else {
            userTemplates.append(template)
        }

        do {
            try FileManager.default.createDirectory(atPath: Self.userDataDir, withIntermediateDirectories: true)
            let data = try SideDeskJSON.encoder().encode(userTemplates)
            try data.write(to: URL(fileURLWithPath: Self.userTemplatesFile), options: .atomic)
        } catch { /* 忽略 */ }

        // 刷新内存模板列表
        if let idx = Templates.firstIndex(where: { $0.Id == template.Id }) {
            Templates[idx] = template
        } else {
            Templates.append(template)
        }
    }
}
