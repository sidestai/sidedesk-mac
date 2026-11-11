import SwiftUI
import SideDeskCore

/// 设置页共用的三段式骨架（对应 C# 各 `*SettingsPage.xaml` 的重复结构：页头 + 卡片分区 + 行）。
/// 行的排布与 C# 一致：左侧标题 + 次级提示，右侧控件（C# 用 `DockPanel` + `Dock=Right`）。
///
/// 颜色与字号一律走主题令牌（C# 侧是 `DynamicResource BrushXXX` / `FontSizeXXX`），
/// 主题一切换整窗重绘——重绘由 `SettingsRootView` 持有的 `ThemeChangeObserver` 驱动。

/// 页头（对应 C# 每页顶部的标题 `TextBlock`：`FontSizeSubtitle` + Bold + `BrushTextMain`，
/// 见 `GeneralSettingsPage.xaml:173`）。
struct SettingsPageHeader: View {

    let titleKey: String
    var hintKey: String?

    var body: some View {
        let palette = ThemeManager.palette
        VStack(alignment: .leading, spacing: 6) {
            Text(Lang.t(titleKey))
                .font(.system(size: ThemeManager.fontSize(18), weight: .bold))
                .foregroundStyle(palette.textMain.color)
            if let hintKey {
                Text(Lang.t(hintKey))
                    .font(.system(size: ThemeManager.fontSize(11)))
                    .foregroundStyle(palette.textMuted.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 分区卡片（对应 C# `ToolCard` / 各页的分区 `Border`：
/// `BrushInputBG` 底 + `BrushBorder` 1px 描边 + `CornerRadiusLarge` + `Padding=16`）。
struct SettingsCard<Content: View>: View {

    var spacing: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        let palette = ThemeManager.palette
        let radius = ThemeManager.radius(8)
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: radius).fill(palette.inputBG.color))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(palette.border.color, lineWidth: 1))
    }
}

/// 分区小标题（对应 C# 的 `ToolTitle` / `ToolHint`：`FontSizeNormal` SemiBold `BrushTextMain`
/// + `FontSizeSmall` `BrushTextMuted`）。
struct SettingsSectionTitle: View {

    let titleKey: String
    var hintKey: String?

    var body: some View {
        let palette = ThemeManager.palette
        VStack(alignment: .leading, spacing: 2) {
            Text(Lang.t(titleKey))
                .font(.system(size: ThemeManager.fontSize(13), weight: .semibold))
                .foregroundStyle(palette.textMain.color)
            if let hintKey {
                Text(Lang.t(hintKey))
                    .font(.system(size: ThemeManager.fontSize(11)))
                    .foregroundStyle(palette.textMuted.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一行设置：左标题 + 提示，右控件（对应 C# 的 `RowTitle` / `RowHint`：
/// 标题 `FontSizeNormal` SemiBold `BrushTextMain`，提示 `FontSizeSmall` `BrushTextMuted`，
/// 提示的 `Margin="0,2,8,0"` 让它在多行时不贴到右侧控件）。
struct SettingsRow<Control: View>: View {

    let titleKey: String
    var hintKey: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        let palette = ThemeManager.palette
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Lang.t(titleKey))
                    .font(.system(size: ThemeManager.fontSize(13), weight: .semibold))
                    .foregroundStyle(palette.textMain.color)
                if let hintKey {
                    Text(Lang.t(hintKey))
                        .font(.system(size: ThemeManager.fontSize(11)))
                        .foregroundStyle(palette.textMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.trailing, 8)
                }
            }
            Spacer(minLength: 8)
            control()
        }
    }
}

/// 开关行（对应 C# 的 `RaycastSwitchStyle` CheckBox：只写设置并即时落盘）。
struct SettingsToggleRow: View {

    let titleKey: String
    var hintKey: String?
    let isOn: Binding<Bool>

    var body: some View {
        SettingsRow(titleKey: titleKey, hintKey: hintKey) {
            Toggle(isOn: isOn) { EmptyView() }
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(ThemeManager.palette.accent.color)
        }
    }
}
