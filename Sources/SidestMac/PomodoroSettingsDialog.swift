import AppKit
import SwiftUI
import SideDeskCore

/// 番茄钟设置对话框（对应 C# `NativeModePanel.Pomodoro.ShowPomodoroSettingsDialog`）：
/// 各阶段时长（分钟）+ 长休息间隔 + 「阶段结束后自动开始下一阶段」。确定即写回并落库（经 `BarCardsModel.applyPomodoroSettings`）。
///
/// 与 C# 的有意收窄（依赖未移植子系统，避免死控件）：「结束时闪烁窗口 / 弹出提示窗口」两个勾选与「每日活跃记录」说明未接——
/// Swift 侧 `advancePhase` 不做闪烁/弹窗，也无 `DailyActivityService`，故不呈现这两个存而不用的选项。
@MainActor
final class PomodoroSettingsWindowController: NSWindowController, NSWindowDelegate {

    private static var live: [PomodoroSettingsWindowController] = []

    private var onSave: ((Int, Int, Int, Int, Bool) -> Void)?

    convenience init(settings: PomodoroSettings, onSave: @escaping (_ work: Int, _ shortBreak: Int, _ longBreak: Int, _ interval: Int, _ autoStartNext: Bool) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Lang.t("nativePanel.pomodoroSettings")
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        self.onSave = onSave
        window.delegate = self
        window.contentView = NSHostingView(rootView: PomodoroSettingsForm(
            settings: settings,
            onSave: { [weak self] w, s, l, i, a in self?.commitSave(w, s, l, i, a) },
            onCancel: { [weak self] in self?.close() }
        ))
    }

    private func commitSave(_ w: Int, _ s: Int, _ l: Int, _ i: Int, _ a: Bool) {
        onSave?(w, s, l, i, a)
        close()
    }

    func present() {
        Self.live.append(self)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.live.removeAll { $0 === self }
    }
}

enum PomodoroSettingsDialog {
    @MainActor static func present(settings: PomodoroSettings,
                                   onSave: @escaping (_ work: Int, _ shortBreak: Int, _ longBreak: Int, _ interval: Int, _ autoStartNext: Bool) -> Void) {
        PomodoroSettingsWindowController(settings: settings, onSave: onSave).present()
    }
}

private struct PomodoroSettingsForm: View {

    let onSave: (Int, Int, Int, Int, Bool) -> Void
    let onCancel: () -> Void

    @State private var work: String
    @State private var shortBreak: String
    @State private var longBreak: String
    @State private var interval: String
    @State private var autoStartNext: Bool

    init(settings: PomodoroSettings,
         onSave: @escaping (Int, Int, Int, Int, Bool) -> Void,
         onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        _work = State(initialValue: "\(settings.WorkMinutes)")
        _shortBreak = State(initialValue: "\(settings.ShortBreakMinutes)")
        _longBreak = State(initialValue: "\(settings.LongBreakMinutes)")
        _interval = State(initialValue: "\(settings.LongBreakInterval)")
        _autoStartNext = State(initialValue: settings.AutoStartNext)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            numberField(Lang.t("nativePanel.pomodoroMinutes"), $work)
            numberField(Lang.t("nativePanel.shortBreakMinutes"), $shortBreak)
            numberField(Lang.t("nativePanel.longBreakMinutes"), $longBreak)
            numberField(Lang.t("nativePanel.longBreakInterval"), $interval)

            VStack(alignment: .leading, spacing: 6) {
                Text(Lang.t("common.behavior")).font(.system(size: 12))
                Toggle(Lang.t("nativePanel.autoStartNextPhase"), isOn: $autoStartNext)
                    .font(.system(size: 12))
            }

            HStack {
                Spacer()
                Button(Lang.t("common.cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(Lang.t("common.ok")) { confirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func numberField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12))
            TextField("", text: text)
                .dialogFieldStyle()
        }
    }

    /// 解析口径对应 C#：非法或 <1 回落默认值（25 / 5 / 15 / 4）。
    private func parse(_ s: String, fallback: Int) -> Int {
        guard let v = Int(s.trimmingCharacters(in: .whitespaces)), v >= 1 else { return fallback }
        return v
    }

    private func confirm() {
        onSave(parse(work, fallback: 25),
               parse(shortBreak, fallback: 5),
               parse(longBreak, fallback: 15),
               parse(interval, fallback: 4),
               autoStartNext)
    }
}
