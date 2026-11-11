import Foundation

/// 程序注册条目。对应 C# `Models.ProgramEntry`。
public final class ProgramEntry: Codable {
    public var Id: String = newGuidId()
    public var Name: String = ""
    public var ExePath: String = ""
    public init() {}
}

/// 浏览器配置。对应 C# `Models.BrowserConfig`。
public final class BrowserConfig: Codable {
    public var Id: String = newGuidId()
    public var Name: String = ""
    public var ExePath: String = ""
    public var Profiles: [UserDataProfile] = []
    public init() {}
}

/// 浏览器 UserData 配置。对应 C# `Models.UserDataProfile`。
public final class UserDataProfile: Codable {
    public var Id: String = newGuidId()
    public var Name: String = ""
    public var Directory: String = ""
    public init() {}
}

/// 程序注册表管理器（program-registry.json）。对应 C# `Models.ProgramRegistryManager`。
public final class ProgramRegistryManager: Codable {
    public var Programs: [ProgramEntry] = []
    public var Browsers: [BrowserConfig] = []
    /// 默认 Profile 基础目录（所有浏览器通用）；自动新建 profile 时在此目录下建子目录。
    public var DefaultProfileBaseDir: String = ""

    public init() {}

    private static var filePath: String {
        (AppPaths.dataDir as NSString).appendingPathComponent("program-registry.json")
    }

    public func Save() {
        do {
            try FileManager.default.createDirectory(atPath: AppPaths.dataDir, withIntermediateDirectories: true)
            let data = try SideDeskJSON.encoder().encode(self)
            try data.write(to: URL(fileURLWithPath: ProgramRegistryManager.filePath), options: .atomic)
        } catch {
            RuntimeLog.debug("[ProgramRegistry] save failed: \(error.localizedDescription)")
        }
    }

    public static func Load() -> ProgramRegistryManager {
        let path = filePath
        if FileManager.default.fileExists(atPath: path) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                return try SideDeskJSON.decoder().decode(ProgramRegistryManager.self, from: data)
            } catch {
                RuntimeLog.debug("[ProgramRegistry] load failed: \(error.localizedDescription)")
            }
        }
        return ProgramRegistryManager()
    }

    /// 根据 Id 获取浏览器配置。
    public func GetBrowserById(_ id: String?) -> BrowserConfig? {
        guard let id, !id.isEmpty else { return nil }
        return Browsers.first { $0.Id == id }
    }

    /// 根据浏览器 Id 和 Profile Id 获取 UserData 配置。
    public func GetProfileById(_ browserId: String?, _ profileId: String?) -> UserDataProfile? {
        guard let browserId, !browserId.isEmpty, let profileId, !profileId.isEmpty else { return nil }
        return GetBrowserById(browserId)?.Profiles.first { $0.Id == profileId }
    }
}
