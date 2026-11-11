import AppKit
import SwiftUI
import SideDeskCore
import SideDeskServices

/// 设置 → 微屏窗口（对应 C# `WindowsSettingsPage`：页头 + 显隐说明 + 窗口行列表）。
///
/// C# 行列为 序号|名称|类型|卡片|显示|⋯；mac 侧省略「类型」列（本端窗口恒为 Native，
/// 团队/云端窗口依赖未移植的登录与后端链路，常量列属于死 UI）。⋯ 行菜单同理只落地
/// 已接线的「改名 / 删除」（C# 的「编辑」开卡片结构编辑器、「分享」走云端，均未移植）。
/// 顶部「导入 / 我的分享」按钮同样依赖分享链路，按「不出死控件」原则不搬。
struct WindowsSettingsPage: View {

    @StateObject private var model = WindowsSettingsModel()
    @StateObject private var langChange = LangChangeObserver()
    @StateObject private var themeChange = ThemeChangeObserver()

    var body: some View {
        let palette = ThemeManager.palette
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader(titleKey: "common.screenWindow",
                               hintKey: "screenTime.screenVisibilityHint")
            SettingsCard(spacing: 4) {
                headerRow
                ForEach(model.rows) { row in
                    windowRow(row)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.bg.color)
        .onAppear { model.reload() }
    }

    // MARK: - 行

    /// 表头（对应 C# `WindowListHeaderTemplate`：序号/名称/卡片/显示/操作）。
    private var headerRow: some View {
        let palette = ThemeManager.palette
        return HStack(spacing: 8) {
            Text(Lang.t("common.indexNumber")).frame(width: 36, alignment: .leading)
            Text(Lang.t("common.name")).frame(maxWidth: .infinity, alignment: .leading)
            Text(Lang.t("common.module")).frame(width: 40, alignment: .center)
            Text(Lang.t("common.show")).frame(width: 44, alignment: .center)
            Text(Lang.t("common.actions")).frame(width: 36, alignment: .center)
        }
        .font(.system(size: ThemeManager.fontSize(11)))
        .foregroundStyle(palette.textMuted.color)
        .padding(.bottom, 4)
    }

    /// 窗口行（对应 C# `WindowRowTemplate`）：序号 | 名称 | 卡片数 | 显示开关 | ⋯。
    private func windowRow(_ row: WindowsSettingsModel.Row) -> some View {
        let palette = ThemeManager.palette
        return HStack(spacing: 8) {
            Text("\(row.index + 1)")
                .frame(width: 36, alignment: .leading)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(row.cardCount)")
                .frame(width: 40, alignment: .center)
            Toggle("", isOn: Binding(
                get: { row.showInTabs },
                set: { model.setShow(row, $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .frame(width: 44, alignment: .center)
            Menu {
                Button(Lang.t("common.rename")) { model.promptRename(row) }
                Button(Lang.t("common.delete"), role: .destructive) { model.delete(row) }
                    .disabled(!model.canDelete)
            } label: {
                Text("⋯")
                    .font(.system(size: ThemeManager.fontSize(14), weight: .bold))
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .frame(width: 36, alignment: .center)
            .help(Lang.t("common.actions"))
        }
        .font(.system(size: ThemeManager.fontSize(13)))
        .foregroundStyle(palette.textMain.color)
        .padding(.vertical, 6)
    }
}

/// 微屏窗口页模型：行数据取左侧 dock 的窗口顺序（与顶部标签、Ctrl+数字同序）。
@MainActor
final class WindowsSettingsModel: ObservableObject {

    struct Row: Identifiable {
        let id: String
        let index: Int
        let name: String
        let cardCount: Int
        let showInTabs: Bool
    }

    @Published private(set) var rows: [Row] = []

    /// 容器未注册时为 nil（与 `BarCardsModel` 同口径），此时列表为空、操作全部忽略。
    private let manager: WindowConfigManager? = AppContainer.shared.resolve(WindowConfigManager.self)

    var canDelete: Bool { rows.count > 1 }

    func reload() {
        guard let manager else { rows = []; return }
        rows = manager.LeftDock.WindowIds.enumerated().compactMap { index, id in
            guard let win = manager.GetById(id) else { return nil }
            return Row(id: id, index: index, name: win.Name,
                       cardCount: win.Panels.count, showInTabs: win.ShowInTabs)
        }
    }

    /// 「显示」开关（对应 C# `WindowRowViewModel.ShowInTabs` → `IWindowsSeam.SetShowInTabs`）：
    /// 落盘后广播两侧栏重建标签（勾选的微屏才出现在顶部标签栏）。
    func setShow(_ row: Row, _ on: Bool) {
        guard let manager, let win = manager.GetById(row.id) else { return }
        win.ShowInTabs = on
        manager.Save()
        reload()
        BarCardsModel.onBarChanged?()
    }

    /// ⋯ → 改名：NSAlert 输入框（与侧栏标签右键改名同口径），空名忽略。
    func promptRename(_ row: Row) {
        guard let manager else { return }
        let alert = NSAlert()
        alert.messageText = Lang.t("window.editWindow")
        alert.addButton(withTitle: Lang.t("common.confirm"))
        alert.addButton(withTitle: Lang.t("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = row.name
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.RenameWindow(row.id, field.stringValue)
        reload()
        BarCardsModel.onBarChanged?()
    }

    /// ⋯ → 删除（对应 C# `DeleteWindowAsync`：连同 dock 成员关系一起移除）。
    func delete(_ row: Row) {
        guard let manager, canDelete else { return }
        manager.Remove(row.id)
        reload()
        BarCardsModel.onBarChanged?()
    }
}
