import AppKit
import SwiftUI
import SideDeskCore

/// 打卡管理弹窗（对应 C# `NativeModePanel.CheckIn.ShowCheckInPickerDialog`）：
/// 常用预设一键添加 + 自定义（打开编辑弹窗）+ 现有项列表（编辑 / 删除）。所有改动经 `BarCardsModel` 实时落库，
/// 卡片与本弹窗列表同步刷新（弹窗观察 model）。
///
/// 与 C# 的有意收窄（依赖未移植子系统，避免死控件）：打卡时镜像写入「每日活跃」（`DailyActivityService`）未接——
/// Swift 侧 `BarCardsModel.checkIn` 只做当日计数自增，无每日活跃服务，故此处也不呈现相关说明。
@MainActor
final class CheckInPickerWindowController: NSWindowController, NSWindowDelegate {

    private static var live: [CheckInPickerWindowController] = []

    convenience init(panel: PanelItem, model: BarCardsModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Lang.t("nativePanel.addCheckIn")
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: CheckInPickerForm(
            panel: panel,
            model: model,
            onClose: { [weak self] in self?.close() }
        ))
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

enum CheckInPickerDialog {
    @MainActor static func present(panel: PanelItem, model: BarCardsModel) {
        CheckInPickerWindowController(panel: panel, model: model).present()
    }
}

/// 打卡预设 / 调色板 / 快捷 emoji（对应 C# `CheckInPresets` / `CheckInPalette` / `CheckInEmojiChoices`）。
enum CheckInCatalog {
    static let presets: [(icon: String, key: String)] = [
        ("💧", "nativePanel.presetDrinkWater"),
        ("🧍", "nativePanel.presetStandUp"),
        ("👀", "nativePanel.presetEyeRest"),
        ("💊", "nativePanel.presetMedicine"),
        ("🌬", "nativePanel.presetBreath"),
        ("🚶", "nativePanel.presetWalk"),
    ]
    static let palette = [
        "#3498DB", "#2ECC71", "#E67E22", "#9B59B6", "#1ABC9C", "#E74C3C", "#F39C12", "#16A085",
    ]
    /// 编辑弹窗色板额外追加的中性色（对应 C# `CheckInPalette.Concat(...)`）。
    static let pickerColors = palette + ["#FFFFFF", "#CCCCCC", "#666666", "#333333", "#34495E", "#1A1A2E"]
    static let emojiChoices = [
        "💧", "☕", "🍎", "💊", "🏃", "🚶", "🧘", "👀",
        "🌬", "💪", "✍", "📖", "🎯", "⏰", "🍵", "🥗",
    ]

    /// 新建项默认色：按已有数量循环取用（对应 C# `CheckInPalette[count % len]`）。
    static func defaultColor(forCount count: Int) -> String {
        palette[count % palette.count]
    }
}

private struct CheckInPickerForm: View {

    let panel: PanelItem
    @ObservedObject var model: BarCardsModel
    let onClose: () -> Void

    var body: some View {
        let palette = ThemeManager.palette
        VStack(alignment: .leading, spacing: 12) {
            Text(Lang.t("nativePanel.checkInPresets"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.textMain.color)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(CheckInCatalog.presets, id: \.key) { preset in
                    presetChip(preset)
                }
            }

            Button(Lang.t("nativePanel.customCheckIn")) { openEditor(nil) }

            Text(Lang.t("common.checkIn"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.textMain.color)
                .padding(.top, 2)

            existingList

            HStack {
                Spacer()
                Button(Lang.t("common.ok")) { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    /// 预设 chip：emoji + 文字，点一下即按调色板默认色新增（对应 C# 的 chip.MouseLeftButtonUp）。
    private func presetChip(_ preset: (icon: String, key: String)) -> some View {
        let tp = ThemeManager.palette
        return Button {
            model.addCheckIn(panel,
                             text: Lang.t(preset.key),
                             icon: preset.icon,
                             color: CheckInCatalog.defaultColor(forCount: panel.CheckInItems?.count ?? 0))
        } label: {
            HStack(spacing: 4) {
                Text(preset.icon).font(.system(size: 14))
                Text(Lang.t(preset.key)).font(.system(size: 12))
                    .foregroundStyle(tp.textMain.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 14).fill(tp.inputBG.color))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tp.border.color, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 现有打卡项列表：序号 + 色块 + 图标 + 文字 + 编辑 / 删除（对应 C# `RenderList`）。
    @ViewBuilder private var existingList: some View {
        let items = panel.CheckInItems ?? []
        let tp = ThemeManager.palette
        if items.isEmpty {
            Text(Lang.t("nativePanel.checkInPresets"))
                .font(.system(size: 11))
                .foregroundStyle(tp.textMuted.color)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, ci in
                    HStack(spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(size: 12))
                            .foregroundStyle(tp.textMuted.color)
                            .frame(width: 20, alignment: .leading)
                        Circle()
                            .fill(ThemeColor.parse(ci.Color)?.color ?? tp.accent.color)
                            .frame(width: 14, height: 14)
                        if !ci.Icon.isEmpty {
                            Text(ci.Icon).font(.system(size: 14))
                        }
                        Text(ci.Text)
                            .font(.system(size: 12))
                            .foregroundStyle(tp.textMain.color)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button { openEditor(ci) } label: {
                            Image(systemName: "pencil").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help(Lang.t("common.edit"))
                        Button { model.removeCheckIn(panel, ci) } label: {
                            Image(systemName: "xmark").font(.system(size: 11))
                                .foregroundStyle(tp.textMuted.color)
                        }
                        .buttonStyle(.plain)
                        .help(Lang.t("common.delete"))
                    }
                }
            }
        }
    }

    private func openEditor(_ existing: CheckInItem?) {
        CheckInEditorDialog.present(panel: panel, model: model, existing: existing)
    }
}

// MARK: - 单个打卡项编辑弹窗

/// 打卡项编辑弹窗（对应 C# `ShowCheckInEditor`）：文字 / 图标（含快捷 emoji）/ 颜色（色板 + hex）。
/// `existing == nil` 新建并追加，否则原地修改；点确定才写回。文字为空不提交，显示 `nativePanel.pleaseEnterCheckInContent`。
@MainActor
final class CheckInEditorWindowController: NSWindowController, NSWindowDelegate {

    private static var live: [CheckInEditorWindowController] = []

    convenience init(panel: PanelItem, model: BarCardsModel, existing: CheckInItem?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = existing == nil ? Lang.t("nativePanel.customCheckIn") : Lang.t("common.edit")
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: CheckInEditorForm(
            panel: panel,
            model: model,
            existing: existing,
            onClose: { [weak self] in self?.close() }
        ))
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

enum CheckInEditorDialog {
    @MainActor static func present(panel: PanelItem, model: BarCardsModel, existing: CheckInItem?) {
        CheckInEditorWindowController(panel: panel, model: model, existing: existing).present()
    }
}

private struct CheckInEditorForm: View {

    let panel: PanelItem
    let model: BarCardsModel
    let existing: CheckInItem?
    let onClose: () -> Void

    @State private var text: String
    @State private var icon: String
    @State private var colorHex: String
    @State private var showError = false

    init(panel: PanelItem, model: BarCardsModel, existing: CheckInItem?, onClose: @escaping () -> Void) {
        self.panel = panel
        self.model = model
        self.existing = existing
        self.onClose = onClose
        _text = State(initialValue: existing?.Text ?? "")
        _icon = State(initialValue: existing?.Icon ?? "")
        _colorHex = State(initialValue: existing?.Color
                          ?? CheckInCatalog.defaultColor(forCount: panel.CheckInItems?.count ?? 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldRow(Lang.t("nativePanel.checkInContent")) {
                TextField("", text: $text)
                    .dialogFieldStyle()
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldRow(Lang.t("common.iconLabel")) {
                    HStack(spacing: 8) {
                        TextField("", text: $icon)
                            .dialogFieldStyle()
                        Text(icon).font(.system(size: 18)).frame(width: 26)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 4)], alignment: .leading, spacing: 4) {
                    ForEach(CheckInCatalog.emojiChoices, id: \.self) { em in
                        Button { icon = em } label: {
                            Text(em).font(.system(size: 15))
                                .frame(width: 28, height: 28)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(ThemeManager.palette.border.color, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 76)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldRow(Lang.t("common.color")) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(ThemeColor.parse(colorHex)?.color ?? ThemeManager.palette.accent.color)
                            .frame(width: 28, height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(ThemeManager.palette.border.color, lineWidth: 1))
                        TextField("#RRGGBB", text: $colorHex)
                            .dialogFieldStyle()
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 26), spacing: 4)], alignment: .leading, spacing: 4) {
                    ForEach(CheckInCatalog.pickerColors, id: \.self) { c in
                        Button { colorHex = c } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(ThemeColor.parse(c)?.color ?? Color.clear)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 76)
            }

            if showError {
                Text(Lang.t("nativePanel.pleaseEnterCheckInContent"))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(Lang.t("common.cancel")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(Lang.t("common.ok")) { confirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder private func fieldRow<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.system(size: 12)).frame(width: 68, alignment: .leading)
            content()
        }
    }

    private func confirm() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { showError = true; return }
        showError = false
        let ic = icon.trimmingCharacters(in: .whitespaces)
        let color = colorHex.trimmingCharacters(in: .whitespaces)
        if let existing {
            model.updateCheckIn(existing, text: t, icon: ic, color: color)
        } else {
            model.addCheckIn(panel, text: t, icon: ic, color: color)
        }
        onClose()
    }
}
