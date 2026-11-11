import AppKit
import SwiftUI
import SideDeskCore

/// 设置窗口宿主（对应 C# `SettingsWindow`：700×500 固定尺寸、居中、非模态单例）。
/// 复用同一个控制器实例，重复打开只把已有窗口提到前面（对应 C# `SettingsWindow.Open`）。
final class SettingsWindowController: NSWindowController {

    convenience init(page: SettingsPage) {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        // C# 的 Width/Height=700/500 是窗口尺寸（含标题栏），这里换算成同样外观尺寸的内容区；
        // ResizeMode="NoResize" 对应不带 .resizable 的 styleMask，内容超出走右侧滚动区。
        let contentRect = NSWindow.contentRect(
            forFrameRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: styleMask
        )
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = Lang.t("common.settings")
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView(initialPage: page))
        self.init(window: window)
    }

    /// accessory 应用（无 Dock 图标）里弹出普通窗口，需要显式激活。
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// 设置窗口入口（宿主侧任一控件调用；窗口只建一次，重复调用即前置）。
///
/// C# 的 `SettingsWindow.Open(page)` 支持深链到指定页；这里只在首次创建时取 `page`，
/// 窗口已开着时不切页——目前唯一的入口（侧栏 ⋯ 菜单、托盘菜单）都只要常规页。
enum SettingsLauncher {

    @MainActor private static var controller: SettingsWindowController?

    /// 侧栏几何相关设置变更（停靠位置 / 侧栏宽度）后的宿主回调：由 AppDelegate 挂接，
    /// 负责按新配置重排面板并按停靠模式显隐（对应 C# `GeneralSeam.ApplyPanelWidth` 尾步的
    /// `Host?.ApplyPanelWidths()`）。
    @MainActor static var onPanelGeometryChanged: (() -> Void)?

    /// 「Ctrl+数字切换窗口」开关变更后的宿主回调：由 AppDelegate 挂接，按新设置注册/注销全局热键
    /// （对应 C# `ShortcutsSeam.RefreshHotkeyState`）。
    @MainActor static var onWindowSwitchHotkeyChanged: (() -> Void)?

    @MainActor static func show(page: SettingsPage = .general) {
        if controller == nil { controller = SettingsWindowController(page: page) }
        controller?.present()
    }

    @MainActor static func panelGeometryChanged() {
        onPanelGeometryChanged?()
    }

    @MainActor static func windowSwitchHotkeyChanged() {
        onWindowSwitchHotkeyChanged?()
    }
}
