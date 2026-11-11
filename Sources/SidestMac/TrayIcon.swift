import AppKit
import SideDeskCore

/// 系统托盘（对应 C# `App.InitNotifyIcon` 的 `NotifyIcon` + `ContextMenuStrip`）。
///
/// mac 对应物是 `NSStatusItem`。两处平台差异不搬：
/// - C# 的"双击托盘图标激活主窗口"在 mac 没有对应交互（点图标即弹菜单，菜单就是入口）；
/// - C# 菜单里的"软件渲染模式"开关是 WPF 的 GPU 回退（`AppSettings.ForceSoftwareRendering`），
///   macOS 渲染管线无此概念，该键在 Swift 侧也不存在。
@MainActor
final class TrayIcon: NSObject {

    private var statusItem: NSStatusItem?

    /// 安装托盘图标（对应 C# `NotifyIcon{ Visible = true }`）。C# 整段包在 try 里，
    /// mac 侧唯一会失败的环节是状态栏按钮取不到，用可选绑定就地跳过即可。
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.menuBarIcon()
            button.toolTip = Lang.t("common.sideDeskScreen")
        } else {
            // 状态栏被占满时 button 取不到（对应 C# 的 catch-log：只记录，不阻断启动）
            RuntimeLog.debug("[NotifyIcon] status item button unavailable")
        }
        item.menu = buildMenu()
        statusItem = item

        // 语言切换后重挂菜单与提示（对应 C# 里 Lang.Changed 会让菜单项失效重建）
        Lang.subscribeChanged { [weak self] in
            DispatchQueue.main.async { self?.refreshTexts() }
        }
    }

    /// 收回图标（对应 C# OnExit 的 `_notifyIcon?.Dispose()`）：退出清理链路要跨约 3 秒
    /// （轮询服务要回收看板拉起的浏览器进程），不显式收回的话这段时间图标一直挂在状态栏上。
    func uninstall() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    // MARK: - 菜单

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem(Lang.t("common.settings"), #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(makeItem(Lang.t("nativePanel.exitSideDeskScreen"), #selector(exitApp)))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func refreshTexts() {
        statusItem?.button?.toolTip = Lang.t("common.sideDeskScreen")
        statusItem?.menu = buildMenu()
    }

    @objc private func openSettings() {
        SettingsLauncher.show()
    }

    /// 退出：走 AppKit 的终止链路，清理工作集中在 `AppDelegate.applicationWillTerminate`。
    /// （C# 的 `CloseAll()` 把保存/关窗/Shutdown 串在一步里，mac 侧由同一入口承担。）
    @objc private func exitApp() {
        NSApplication.shared.terminate(nil)
    }

    /// 图标：C# 取 exe 关联图标（`Icon.ExtractAssociatedIcon`），mac 取 bundle 应用图标，
    /// 缩到状态栏标准高度 18pt。
    private static func menuBarIcon() -> NSImage {
        let target = NSRect(x: 0, y: 0, width: 18, height: 18)
        let icon = NSImage(size: target.size)
        icon.lockFocus()
        NSApp.applicationIconImage.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1.0)
        icon.unlockFocus()
        return icon
    }
}
