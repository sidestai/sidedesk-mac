import Foundation
import Darwin

/// 开发/生产运行模式（轻量双模式）。对应 Windows C# 的 `Framework.RuntimeMode`。
///
/// 判定短路顺序（进程内只算一次）：
///   1. 环境变量 SIDESK_DEV=1/true/yes → Dev（显式覆盖）
///   2. 调试器挂载 → Dev
///   3. 可执行文件位于构建输出目录（.build/ 或 bin/）→ Dev
///   4. 其余 → Prod
///
/// 门控：RuntimeLog 在 Dev 且未显式设 SIDESK_LOG_LEVEL 时强制 Debug 级（全量落盘）。
public enum RuntimeMode {

    /// 是否开发模式（首次访问时判定并缓存）。
    public static var isDev: Bool {
        if let cached = _isDev { return cached }
        let v = detect()
        _isDev = v
        return v
    }

    /// 测试模式（--test-mode）：数据目录隔离 + 跳过 GUI/钩子/自启等副作用。
    public static var isTestMode: Bool = false

    private static var _isDev: Bool?

    /// 重置模式缓存（测试缝隙）。
    public static func resetCache() { _isDev = nil }

    /// 模式名（"test" / "dev" / "prod"），供日志首行展示。
    public static var name: String { isTestMode ? "test" : (isDev ? "dev" : "prod") }

    private static func detect() -> Bool {
        detectCore(
            ProcessInfo.processInfo.environment["SIDESK_DEV"],
            isDebuggerAttached(),
            Bundle.main.bundlePath
        )
    }

    /// 纯函数判定（供单测直接验证优先级）：环境变量 > 调试器 > 构建目录启发式。
    static func detectCore(_ env: String?, _ debuggerAttached: Bool, _ baseDir: String) -> Bool {
        if let env {
            let trimmed = env.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return ["1", "true", "yes"].contains(trimmed.lowercased())
            }
        }
        if debuggerAttached { return true }
        if baseDir.contains("/.build/") || baseDir.contains("/bin/") { return true }
        return false
    }
}

/// 通过 sysctl KERN_PROC 检测当前进程是否被调试器 trace（P_TRACED 标志）。
func isDebuggerAttached() -> Bool {
    var info = kinfo_proc()
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var size = MemoryLayout<kinfo_proc>.stride
    let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    guard result == 0 else { return false }
    return (info.kp_proc.p_flag & P_TRACED) != 0
}
