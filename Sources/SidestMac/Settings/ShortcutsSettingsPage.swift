import SwiftUI
import SideDeskCore
import SideDeskServices

/// 设置 → 快捷键的状态（对应 C# `ShortcutsSettingsViewModel` 的窗口切换部分）。
///
/// 已落地：「Ctrl + 数字 切换窗口」总开关（写 `EnableWindowSwitchHotkey` → 落盘 → 即时注册/注销全局热键）。
/// 未落地（不给死控件）：语音输入快捷键（启停键录制 / 识别引擎 / 出字位置 / 回改上限）依赖语音子系统（T6）。
@MainActor
final class ShortcutsSettingsModel: ObservableObject {

    @Published private(set) var windowSwitchOn: Bool

    init() {
        windowSwitchOn = Seam.settings.EnableWindowSwitchHotkey
    }

    /// 对应 C# `WindowSwitchHotkeyOn` setter：写设置 → 落盘 → `RefreshHotkeyState`（这里经宿主回调重装热键）。
    func setWindowSwitch(_ value: Bool) {
        windowSwitchOn = value
        guard Seam.settings.EnableWindowSwitchHotkey != value else { return }
        Seam.settings.EnableWindowSwitchHotkey = value
        Seam.settings.Save()
        SettingsLauncher.windowSwitchHotkeyChanged()
    }
}

/// 快捷键页（对应 C# `Views/ShortcutsSettingsPage.xaml`）。
struct ShortcutsSettingsPage: View {

    @StateObject private var model = ShortcutsSettingsModel()

    var body: some View {
        let palette = ThemeManager.palette
        return VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(titleKey: "common.hotkeys",
                               hintKey: "settings.globalHotkeyConfiguration")

            SettingsCard {
                SettingsToggleRow(
                    titleKey: "settings.ctrlNumberToSwitch",
                    hintKey: "settings.windowTabHotkeyHint",
                    isOn: Binding(
                        get: { model.windowSwitchOn },
                        set: { model.setWindowSwitch($0) }
                    )
                )
                // 拦截提示（对应 C# `settings.hotkeyInterceptNote`）：开启会全局吞掉 Ctrl+数字
                Text(Lang.t("settings.hotkeyInterceptNote"))
                    .font(.system(size: ThemeManager.fontSize(11)))
                    .foregroundStyle(palette.textMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .background(palette.bg.color)
    }
}

#Preview {
    ShortcutsSettingsPage()
        .frame(width: 500, height: 500)
}
