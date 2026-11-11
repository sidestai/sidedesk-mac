import AppKit
import SwiftUI
import SideDeskCore

/// 添加/编辑待办对话框（对应 C# `Views.TodoDialog`）：标题 / 详细内容 / 可选「设置任务时间」（日期时间 + 提前提醒）。
/// 与 C# 同口径：未勾选时间 → `DueTime=nil`、`RemindBeforeMinutes=-1`；勾选 → 落 DueTime + 提醒分钟数、`Reminded=false`。
/// 提醒下拉默认「提前 10 分钟」（索引 2）。标题为空时不提交，显示 `todo.enterTitlePlaceholder`。
@MainActor
final class AddTodoWindowController: NSWindowController, NSWindowDelegate {

    /// 存活控制器：窗口关闭即移除，避免非模态对话框被提前释放。
    private static var live: [AddTodoWindowController] = []

    private var onSave: ((TodoItem) -> Void)?

    convenience init(existing: TodoItem?, onSave: @escaping (TodoItem) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = existing == nil ? Lang.t("todo.addTodo") : Lang.t("todo.editTodo")
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        self.onSave = onSave
        window.delegate = self
        window.contentView = NSHostingView(rootView: AddTodoForm(
            existing: existing,
            onSave: { [weak self] item in self?.commitSave(item) },
            onCancel: { [weak self] in self?.close() }
        ))
    }

    private func commitSave(_ item: TodoItem) {
        onSave?(item)
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

/// 对话框入口（宿主侧调用；每次新建一个非模态窗口）。
enum AddTodoDialog {
    @MainActor static func present(existing: TodoItem? = nil, onSave: @escaping (TodoItem) -> Void) {
        AddTodoWindowController(existing: existing, onSave: onSave).present()
    }
}

private struct AddTodoForm: View {

    /// 提醒选项对应的提前分钟数（索引与下拉一致，对应 C# `RemindMinutes`）。
    private static let remindMinutes = [0, 5, 10, 15, 30, 60]
    private static let remindKeys = [
        "todo.remindOnTime", "todo.remindEarly5Min", "todo.remindEarly10Min",
        "todo.remindEarly15Min", "todo.remindEarly30Min", "todo.remindEarly60Min",
    ]

    let existing: TodoItem?
    let onSave: (TodoItem) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var details: String
    @State private var enableTime: Bool
    @State private var due: Date
    @State private var remindIndex: Int
    @State private var showError = false

    init(existing: TodoItem?, onSave: @escaping (TodoItem) -> Void, onCancel: @escaping () -> Void) {
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: existing?.Text ?? "")
        _details = State(initialValue: existing?.Description ?? "")
        if let dueTime = existing?.DueTime {
            _enableTime = State(initialValue: true)
            _due = State(initialValue: dueTime)
            let idx = Self.remindMinutes.firstIndex(of: existing?.RemindBeforeMinutes ?? -1)
            _remindIndex = State(initialValue: idx ?? 2)
        } else {
            _enableTime = State(initialValue: false)
            _due = State(initialValue: Date().addingTimeInterval(3600))   // 默认一小时后
            _remindIndex = State(initialValue: 2)                        // 默认提前 10 分钟
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Lang.t("common.title")).font(.system(size: 12))
                TextField("", text: $title)
                    .dialogFieldStyle()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(Lang.t("todo.details")).font(.system(size: 12))
                TextField("", text: $details, axis: .vertical)
                    .lineLimit(2...4)
                    .dialogFieldStyle()
            }

            Toggle(Lang.t("todo.setTaskTime"), isOn: $enableTime)
                .font(.system(size: 12))

            if enableTime {
                DatePicker(Lang.t("common.date"), selection: $due, displayedComponents: [.date, .hourAndMinute])
                    .font(.system(size: 12))
                Picker(Lang.t("common.reminder"), selection: $remindIndex) {
                    ForEach(Array(Self.remindKeys.enumerated()), id: \.offset) { index, key in
                        Text(Lang.t(key)).tag(index)
                    }
                }
                .font(.system(size: 12))
            }

            if showError {
                Text(Lang.t("todo.enterTitlePlaceholder"))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
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
        .frame(width: 360)
    }

    private func confirm() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { showError = true; return }
        showError = false

        let item = existing ?? TodoItem()
        item.Text = t
        item.Description = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if enableTime {
            item.DueTime = due
            item.RemindBeforeMinutes = Self.remindMinutes[max(0, min(remindIndex, Self.remindMinutes.count - 1))]
            item.Reminded = false
        } else {
            item.DueTime = nil
            item.RemindBeforeMinutes = -1
        }
        onSave(item)
    }
}
