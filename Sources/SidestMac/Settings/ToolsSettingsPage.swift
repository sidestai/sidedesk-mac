import AppKit
import SwiftUI
import SideDeskCore
import SideDeskServices

/// 设置 → 工具（对应 C# `ToolsSettingsPage` + `ToolsSettingsViewModel`）。
///
/// 已落地：开机自启、诊断日志级别、打开日志目录。
/// 未落地（对应子系统在 macOS 侧尚不存在，不给死控件）：
/// - 任务栏标题锁（`EnableTitleLock`）：macOS 无任务栏标题所有权，整行不可移植；
/// - MCP 服务器 / HTTP 服务器 + 端口（`EnableMcpServer` / `EnableHttpServer` / `HttpServerPort`）：两个服务未移植；
/// - 窗口使用时长统计（`ShowUsageStats`）：前台窗口记录器未移植；
/// - 键盘事件日志 / 网络请求日志（`KeyboardLogEnabled` / `HttpLogEnabled`）：对应日志器未移植；
/// - 模块工具与悬浮窗、诊断导出、WebSocket 客户端列表：依赖插件宿主与后端链路。
@MainActor
final class ToolsSettingsModel: ObservableObject {

    /// 日志级别选项（对应 C# `ToolsSettingsPage.xaml:235-239`：英文级别名，与 app.log 里的 [LEVEL] 一致）。
    static let logLevels = ["Debug", "Info", "Warn", "Error"]

    @Published private(set) var runAtStartup: Bool
    @Published private(set) var logLevel: String

    init() {
        runAtStartup = AppSettings.Instance.RunAtStartup
        logLevel = ToolsSettingsModel.normalize(Seam.settings.LogLevel)
    }

    /// 设置里的级别字符串归一到下拉的四个选项（与 Core 的 `RuntimeLog.parseLevel` 同口径；
    /// 那个方法是 Core 内部实现，UI 侧不跨模块调用，故此处按同一规则复刻）。
    private static func normalize(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "debug":           return "Debug"
        case "warn", "warning": return "Warn"
        case "error":           return "Error"
        default:                return "Info"
        }
    }

    /// 开机自启（对应 C# `AutoStartEnabled` setter：写 `Framework.AppSettings` → 落盘 → 即时生效）。
    /// 注意设置源是 `settings.json`（AppSettings），不是宿主主配置 `app-settings.json`——与 C# 同分工。
    func setRunAtStartup(_ value: Bool) {
        runAtStartup = value
        guard AppSettings.Instance.RunAtStartup != value else { return }
        AppSettings.Instance.RunAtStartup = value
        AppSettings.Instance.Save()
        // test-mode 不动用户真实登录项（与启动期同一门控）
        if !RuntimeMode.isTestMode {
            AutoStartService.apply(value)
        }
    }

    /// 日志级别（对应 C# `ApplyLogLevel`：落盘 + 即时应用）。
    /// C# 会把「实际生效级别」回显给用户（环境变量 `SIDESK_LOG_LEVEL` / 开发模式会压过设置值），
    /// 这里下拉只反映设置值本身，生效级别以 app.log 为准。
    func setLogLevel(_ value: String) {
        if Seam.settings.LogLevel != value {
            Seam.settings.LogLevel = value
            Seam.settings.Save()
        }
        RuntimeLog.applyConfig(value)
        logLevel = Self.normalize(Seam.settings.LogLevel)
    }

    /// 打开日志目录（对应 C# `OpenLogFolderCommand`）。
    func openLogFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: RuntimeLog.currentLogDir))
    }
}

/// 工具页。
struct ToolsSettingsPage: View {

    @StateObject private var model = ToolsSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(titleKey: "common.tools")

            SettingsCard {
                SettingsSectionTitle(titleKey: "settings.builtInUtilities")
                SettingsToggleRow(
                    titleKey: "settings.runAtStartup",
                    hintKey: "settings.automaticallyRunSidedeskAfter",
                    isOn: Binding(
                        get: { model.runAtStartup },
                        set: { model.setRunAtStartup($0) }
                    )
                )
            }

            SettingsCard {
                SettingsSectionTitle(titleKey: "settings.diagnostics", hintKey: "settings.diagnosticsHint")

                SettingsRow(titleKey: "settings.diagnosticsLogLevel",
                            hintKey: "settings.diagnosticsLogLevelHint") {
                    Picker(selection: Binding(
                        get: { model.logLevel },
                        set: { model.setLogLevel($0) }
                    ), label: EmptyView()) {
                        ForEach(ToolsSettingsModel.logLevels, id: \.self) { level in
                            Text(level).tag(level)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                HStack {
                    Spacer(minLength: 0)
                    Button(Lang.t("settings.diagnosticsOpenLog")) { model.openLogFolder() }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .background(ThemeManager.palette.bg.color)
    }
}

#Preview {
    ToolsSettingsPage()
        .frame(width: 500, height: 500)
}
