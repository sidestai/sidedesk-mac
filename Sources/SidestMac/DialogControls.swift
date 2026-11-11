import SwiftUI
import SideDeskCore

/// 对话框输入框统一描边：`BrushInputBG` 底 + `BrushBorder` 1px 描边 + 圆角（对应 C# 弹窗里
/// `GlobalTextBoxStyle` 的可见边框）。默认 `.plain` 的 SwiftUI `TextField` 在深色弹窗底上无边框、
/// 未聚焦时完全看不出输入区，故各对话框表单统一套这层样式。
extension View {
    func dialogFieldStyle() -> some View {
        modifier(DialogFieldModifier())
    }
}

private struct DialogFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        let palette = ThemeManager.palette
        let radius = ThemeManager.radius(6)
        return content
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: radius).fill(palette.inputBG.color))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(palette.border.color, lineWidth: 1))
    }
}
