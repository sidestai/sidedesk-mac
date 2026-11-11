import Foundation
import ServiceManagement
import SideDeskCore

/// 开机自启服务。对应 C# `Services.AutoStartService`。
///
/// 平台映射：Windows 写 `HKCU\...\Run` 注册表值（需带引号的 exe 路径）；
/// macOS 13+ 用 `SMAppService.mainApp` 登记登录项——按 bundle id 记账，所以 C# 那套
/// 「比对当前 exe 路径以修正漂移」不需要重写：路径变化由系统按 bundle 自行解析。
///
/// 语义保持与 C# 一致：每次启动都同步一次（`Apply(RunAtStartup)`），失败只记调试日志、
/// 绝不抛出——登录项写不成不该挡住启动。
public enum AutoStartService {

    /// 登录项状态（`SMAppService.Status` 的镜像，测试可注入假实现而不引系统枚举）
    public enum Status: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
    }

    /// 注册为登录项
    nonisolated(unsafe) public static var registerImpl: () throws -> Void = {
        try SMAppService.mainApp.register()
    }

    /// 取消注册
    nonisolated(unsafe) public static var unregisterImpl: () throws -> Void = {
        try SMAppService.mainApp.unregister()
    }

    /// 读当前状态
    nonisolated(unsafe) public static var statusImpl: () -> Status = {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .notRegistered
        }
    }

    /// 当前是否已注册开机自启。对应 C# `IsEnabled()`。
    public static func isEnabled() -> Bool { statusImpl() == .enabled }

    /// 按设置同步登录项状态：启用则登记，禁用则移除。对应 C# `Apply(bool)`。
    public static func apply(_ enabled: Bool) {
        do {
            if enabled {
                try registerImpl()
            } else {
                // C# 的 `DeleteValue(name, false)` 对不存在的值不报错，而 `unregister()` 会抛；
                // 先查状态再动手，免得每次默认关闭的启动都刷一条无意义日志。
                let status = statusImpl()
                if status != .notRegistered && status != .notFound { try unregisterImpl() }
            }
        } catch {
            RuntimeLog.debug("[AutoStart] failed to set auto-start: \(error.localizedDescription)")
        }
    }
}
