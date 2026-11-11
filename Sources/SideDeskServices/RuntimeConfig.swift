import Foundation
import SideDeskCore

/// 运行时配置层：服务端口等运行参数从代码硬编码抽到集中配置。对应 C# `Framework/RuntimeConfig.cs`。
///
/// 读取优先级：环境变量 `SIDESK_<KEY>`（`.` → `_`，如 `SIDESK_WS_PORT`）
/// > `runtime-config.json`（数据目录或可执行文件旁，取先存在者）> 代码默认值。
///
/// 与 C# 的差异：C# 的模板写在 exe 旁，macOS 上那等于往 `.app` 包内写文件（破坏代码签名密封），
/// 故模板写在读取顺序里的第一个可写位置——数据目录。
public enum RuntimeConfig {

    private static let fileName = "runtime-config.json"

    /// WebSocket 扩展桥默认端口
    public static let webSocketPortDefault = 19191

    /// 测试缝隙：覆盖配置文件目录（nil = 默认查找顺序）
    nonisolated(unsafe) public static var dirOverride: String?

    /// 当前全量默认键值（写模板用）：新增配置项在此登记——单一事实源。对应 C# `AllDefaults`。
    /// C# 另有 `mcp.port`/`bus.port`：MCP 服务与命令总线在 Swift 侧尚未移植，落地时在此补登记
    /// （模板只写有消费者的键，免得自文档化变成误导）。
    static func allDefaults() -> [(key: String, value: Any)] {
        [("ws.port", webSocketPortDefault)]
    }

    /// 模板落点：`dirOverride` 优先（test-mode 下写进隔离目录，不污染产品目录），否则数据目录。
    static var templatePath: String { (dirOverride ?? AppPaths.dataDir) + "/" + fileName }

    /// 缺文件时写一份默认模板（自文档化，用户可直接改）；已存在不覆盖——用户改动优先。
    /// 对应 C# `RuntimeConfig.WriteTemplateIfMissing`，须在 `dirOverride` 布置之后调用。
    /// 写失败（无权限等）静默：配置继续走代码默认，不阻断启动。
    public static func writeTemplateIfMissing() {
        let path = templatePath
        guard !FileManager.default.fileExists(atPath: path) else { return }
        var dict: [String: Any] = [:]
        for item in allDefaults() { dict[item.key] = item.value }
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static let lock = NSLock()
    private static var cache: [String: Any]?

    /// 读整数配置：环境变量 > 文件 > 默认值
    public static func getInt(_ key: String, _ defaultValue: Int) -> Int {
        if let s = envValue(key), let v = Int(s.trimmingCharacters(in: .whitespaces)) { return v }
        if let v = Load()[key] as? Int { return v }
        if let n = Load()[key] as? NSNumber { return n.intValue }
        return defaultValue
    }

    /// 读字符串配置（同优先级）
    public static func getString(_ key: String, _ defaultValue: String) -> String {
        if let s = envValue(key), !s.isEmpty { return s }
        if let s = Load()[key] as? String, !s.isEmpty { return s }
        return defaultValue
    }

    /// 复位缓存（配置落盘后或测试隔离用）
    public static func reset() {
        lock.lock()
        cache = nil
        lock.unlock()
    }

    private static func envValue(_ key: String) -> String? {
        ProcessInfo.processInfo.environment["SIDESK_" + key.replacingOccurrences(of: ".", with: "_").uppercased()]
    }

    private static func Load() -> [String: Any] {
        if let cache { return cache }
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        var dict: [String: Any] = [:]
        for path in candidatePaths() {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            dict = obj
            break
        }
        cache = dict
        return dict
    }

    private static func candidatePaths() -> [String] {
        let name = fileName
        if let dir = dirOverride { return [dir + "/" + name] }
        var paths = [AppPaths.dataDir + "/" + name]
        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent().path
        if !exe.isEmpty { paths.append(exe + "/" + name) }
        return paths
    }
}
