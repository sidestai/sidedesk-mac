import AppKit
import SwiftUI
import SideDeskCore

/// 同步加密密码对话框（对应 C# `SyncPasswordDialog`）：首次开启加密同步时设置独立同步密码。
/// 密码明文直接显示（C# 注释：用户可即时核对，无需二次确认输入）；空密码弹提示且不关窗。
/// 同步返回密码（取消/关窗返回 nil），与 C# `ShowDialog() == true ? Password : null` 同口径。
@MainActor
enum SyncPasswordDialog {

    static func requestPassword() -> String? {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 232),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Lang.t("settings.setEncryptedSyncKey")
        window.isReleasedWhenClosed = false
        window.center()

        var result: String?
        let delegate = CloseDelegate()
        window.delegate = delegate
        window.contentView = NSHostingView(rootView: SyncPasswordForm(
            onOk: { password in
                result = password
                window.orderOut(nil)
                NSApp.stopModal()
            },
            onCancel: {
                window.orderOut(nil)
                NSApp.stopModal()
            }
        ))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        return result
    }

    /// 点窗口关闭按钮等价取消（C# 的 IsCancel 语义）。
    private final class CloseDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            NSApp.stopModal()
        }
    }
}

private struct SyncPasswordForm: View {

    let onOk: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""

    var body: some View {
        let palette = ThemeManager.palette
        VStack(alignment: .leading, spacing: 10) {
            Text(Lang.t("misc.pleaseEnterYourAccount"))
                .font(.system(size: ThemeManager.fontSize(12)))
                .foregroundStyle(palette.textMain.color.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(Lang.t("common.passwordLabel"))
                    .font(.system(size: ThemeManager.fontSize(13)))
                    .foregroundStyle(palette.textMain.color)
                    .frame(width: 70, alignment: .leading)
                TextField("", text: $password)
                    .dialogFieldStyle()
                    .onSubmit { confirm() }
            }

            HStack {
                Spacer()
                Button(Lang.t("common.ok")) { confirm() }
                    .keyboardShortcut(.defaultAction)
                Button(Lang.t("common.cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 4)
        }
        .padding(15)
        .frame(width: 380, height: 232, alignment: .topLeading)
        .background(palette.dialogBG.color)
    }

    private func confirm() {
        // 与 C# 一致：只校验非纯空白，通过后原样传出（派生密钥用精确文本，不 trim）
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let alert = NSAlert()
            alert.messageText = Lang.t("misc.pleaseEnterThePassword")
            alert.addButton(withTitle: Lang.t("common.ok"))
            alert.runModal()
            return
        }
        onOk(password)
    }
}