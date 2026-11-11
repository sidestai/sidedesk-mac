import Foundation

/// 运行时日志（Release 可用）：应用主日志通道。对应 Windows C# 的 `Framework.RuntimeLog`。
///
/// - 所有级别始终双写 `print`（stdout，调试器/终端可见）；文件写入按 `minLevel` 门控
///   ——默认 Info，Debug 级不落盘（线上安静）。需要时经 Settings.LogLevel 或环境变量
///   SIDESK_LOG_LEVEL 打开。
/// - 日志文件：`{AppPaths.dataDir}/Logs/app.log`，超过 8MB 滚动为 app.1.log（保留一份）。
/// - 崩溃走 `crash(_:_:extra:)`：单独写 crash.log 并滚动保留最近 5 份。
/// - 行格式：`[yyyy-MM-dd HH:mm:ss.SSS] [LEVEL] [category] message`（机器可解析）。
public enum RuntimeLog {

    /// 日志级别（数值越大越严重）。
    public enum Level: Int, Comparable {
        case debug = 0, info = 1, warn = 2, error = 3
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
        var label: String {
            switch self {
            case .debug: return "DEBUG"
            case .info:  return "INFO"
            case .warn:  return "WARN"
            case .error: return "ERROR"
            }
        }
    }

    /// 当前文件写入门槛；默认 Info。
    public static var minLevel: Level = .info

    private static let maxFileSize: UInt64 = 8 * 1024 * 1024
    private static let crashMaxFileSize: UInt64 = 1 * 1024 * 1024
    private static let crashKeepCount = 5
    private static let lock = NSLock()

    /// 日志目录覆盖（测试缝隙 + `--test-mode` 的隔离目录；nil=真实路径）。
    public static var dirOverride: String?

    private static var dir: String {
        dirOverride ?? (AppPaths.dataDir as NSString).appendingPathComponent("Logs")
    }
    private static var filePath: String { (dir as NSString).appendingPathComponent("app.log") }
    private static var crashPath: String { (dir as NSString).appendingPathComponent("crash.log") }

    /// app.log 完整路径。
    public static var currentFilePath: String { filePath }

    /// 日志目录（含 `dirOverride`／test-mode 隔离目录；设置页「打开日志目录」用）。
    public static var currentLogDir: String { dir }

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 每次启动清空上一轮遗留的调试日志（对应 C# `App.InitLoggingCleanup` 的 `ClearDebugLogsOnStartup`）。
    ///
    /// 日志一律固定名、不按天分文件，重开即清，只留本次运行的记录。例外（各有自己的淘汰通道）：
    /// - `windowlog_*`：使用时长功能按天累积的历史数据源，保留；
    /// - `crash*`：崩溃证据持久保留，滚动淘汰由 `crash` 负责；
    /// - `app.log` / `app.*.log`：保留上一轮便于对照崩溃前后的运行日志，滚动由 `rollIfNeeded` 负责。
    /// 单个文件删除失败不影响其余（清理是尽力而为，不阻断启动）。
    public static func clearDebugLogsOnStartup() {
        // 与 C# 一致：测试模式不做破坏性文件操作
        guard !RuntimeMode.isTestMode else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names {
            // 前缀判定不分大小写（与 C# OrdinalIgnoreCase 一致）
            let key = name.lowercased()
            if key.hasPrefix("windowlog_") || key.hasPrefix("crash") || key.hasPrefix("app.") { continue }
            let path = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    /// 按 Settings 字符串设置级别；优先级：SIDESK_LOG_LEVEL 环境变量 > 开发模式(Debug) > Settings。
    public static func applyConfig(_ settingsLevel: String?) {
        minLevel = parseLevel(settingsLevel)
        if let env = ProcessInfo.processInfo.environment["SIDESK_LOG_LEVEL"],
           !env.trimmingCharacters(in: .whitespaces).isEmpty {
            minLevel = parseLevel(env)
        } else if RuntimeMode.isDev {
            minLevel = .debug
        }
    }

    static func parseLevel(_ s: String?) -> Level {
        switch s?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "debug":            return .debug
        case "warn", "warning":  return .warn
        case "error":            return .error
        default:                 return .info
        }
    }

    public static func debug(_ message: String) { write(.debug, "", message) }
    public static func debug(_ category: String, _ message: String) { write(.debug, category, message) }
    public static func info(_ message: String) { write(.info, "", message) }
    public static func info(_ category: String, _ message: String) { write(.info, category, message) }
    public static func warn(_ message: String) { write(.warn, "", message) }
    public static func warn(_ category: String, _ message: String) { write(.warn, category, message) }
    public static func error(_ message: String) { write(.error, "", message) }
    public static func error(_ category: String, _ message: String) { write(.error, category, message) }

    /// 崩溃记录：写 crash.log（独立滚动保留 5 份）。
    public static func crash(_ source: String, _ error: Error, extra: String? = nil) {
        var line = "[\(tsFormatter.string(from: Date()))] [CRASH] \(source)\n错误: \(error)"
        if let extra { line += "\n内部异常:\n\(extra)" }
        print(line)
        appendLine(line, to: crashPath, keep: crashKeepCount, maxBytes: crashMaxFileSize)
    }

    private static func write(_ level: Level, _ category: String, _ message: String) {
        let body = category.isEmpty ? message : "[\(category)] \(message)"
        let line = "[\(tsFormatter.string(from: Date()))] [\(level.label)] \(body)"
        print(line)
        guard level >= minLevel else { return }
        appendLine(line, to: filePath, keep: 1, maxBytes: maxFileSize)
    }

    private static func appendLine(_ line: String, to path: String, keep: Int, maxBytes: UInt64) {
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            rollIfNeeded(path: path, ext: ".log", keep: keep, maxBytes: maxBytes)
            let data = Data((line + "\n").utf8)
            if FileManager.default.fileExists(atPath: path),
               let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try data.write(to: URL(fileURLWithPath: path))
            }
        } catch { /* 日志失败不能引发新异常 */ }
    }

    /// 大小滚动：path 超 maxBytes 时滚动为 path.1.ext … path.{keep-1}.ext，最旧删除。
    static func rollIfNeeded(path: String, ext: String, keep: Int, maxBytes: UInt64) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64, size > maxBytes else { return }
        let baseNoExt = String(path.dropLast(ext.count))
        if keep <= 1 {
            let dst = "\(baseNoExt).1\(ext)"
            if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: dst) }
            try? fm.moveItem(atPath: path, toPath: dst)
            return
        }
        var i = keep - 1
        while i >= 1 {
            let src = "\(baseNoExt).\(i)\(ext)"
            if i == keep - 1 {
                if fm.fileExists(atPath: src) { try? fm.removeItem(atPath: src) }
            } else {
                let dst = "\(baseNoExt).\(i + 1)\(ext)"
                if fm.fileExists(atPath: src) { try? fm.moveItem(atPath: src, toPath: dst) }
            }
            i -= 1
        }
        try? fm.moveItem(atPath: path, toPath: "\(baseNoExt).1\(ext)")
    }
}
