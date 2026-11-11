import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SideDeskCore

/// 添加快捷项对话框（对应 C# `QuickGroupDialogs.ShowAddItemDialog`：program 走 Tab 式程序对话框、
/// url 走 `AddShortcutDialog`）。本轮收窄为「名称 / 图标 / 目标(路径|网址) / 按钮颜色」共用表单，
/// 程序目标带「选择程序」按钮（`NSOpenPanel` 选 .app）。
///
/// 与 C# 的差异（有意收窄，依赖未移植子系统，非遗漏）：命令行参数、浏览器/Profile 选择、批量模式、
/// 应用市场、已装应用/已注册程序列表、内置浏览器弹窗均未接。
@MainActor
final class AddQuickItemWindowController: NSWindowController, NSWindowDelegate {

    /// 存活控制器：窗口关闭即移除，避免非模态对话框被提前释放。
    private static var live: [AddQuickItemWindowController] = []

    private var onSave: ((QuickItem) -> Void)?

    convenience init(presetType: String, onSave: @escaping (QuickItem) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = presetType == "url" ? Lang.t("settings.addUrl") : Lang.t("settings.addProgram")
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        self.onSave = onSave
        window.delegate = self
        window.contentView = NSHostingView(rootView: AddQuickItemForm(
            presetType: presetType,
            onSave: { [weak self] item in self?.commitSave(item) },
            onCancel: { [weak self] in self?.close() }
        ))
    }

    private func commitSave(_ item: QuickItem) {
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

/// 对话框入口（宿主侧任一控件调用；每次新建一个非模态窗口）。
enum AddQuickItemDialog {
    @MainActor static func present(presetType: String, onSave: @escaping (QuickItem) -> Void) {
        AddQuickItemWindowController(presetType: presetType, onSave: onSave).present()
    }
}

/// 表单本体。字段口径对应 C# 程序对话框（名称/图标/路径）与 `AddShortcutDialog`（名称/网址/图标/按钮颜色）。
private struct AddQuickItemForm: View {

    let presetType: String
    let onSave: (QuickItem) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var icon = ""
    @State private var target = ""
    @State private var selectedColor: String? = nil
    @State private var showError = false

    /// C# `ShowAddItemDialog` 的 12 色预设（含红/紫，属用户可选数据，非产品主色）。
    private let presetColors = [
        "#3498DB", "#2ECC71", "#E74C3C", "#9B59B6",
        "#F39C12", "#1ABC9C", "#E67E22", "#34495E",
        "#2980B9", "#27AE60", "#C0392B", "#8E44AD",
    ]

    private var isURL: Bool { presetType == "url" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            fieldRow(Lang.t("common.nameLabel")) {
                TextField("", text: $name)
                    .dialogFieldStyle()
            }
            fieldRow(Lang.t("common.iconLabel")) {
                HStack(spacing: 8) {
                    TextField("", text: $icon)
                        .dialogFieldStyle()
                    iconPreview
                }
            }
            fieldRow(isURL ? Lang.t("shortcut.url") : Lang.t("common.path")) {
                HStack(spacing: 8) {
                    TextField(isURL ? "https://" : "/Applications/…", text: $target)
                        .dialogFieldStyle()
                    if !isURL {
                        Button(Lang.t("settings.selectProgram")) { browseForApp() }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(Lang.t("shortcut.buttonColorLabel")).font(.system(size: 12))
                colorSwatches
            }

            if showError {
                Text(Lang.t("nativePanel.pleaseFillInThe"))
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
        .frame(width: 420)
    }

    @ViewBuilder private func fieldRow<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.system(size: 12)).frame(width: 64, alignment: .leading)
            content()
        }
    }

    /// 图标预览（对应 C# `BuildIconPreview`）：路径且文件存在 → 取程序图标；否则按 emoji 文本渲染。
    @ViewBuilder private var iconPreview: some View {
        let t = icon.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, FileManager.default.fileExists(atPath: t) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: t))
                .resizable().frame(width: 20, height: 20)
        } else if !t.isEmpty {
            Text(t).font(.system(size: 16))
        } else {
            Image(systemName: isURL ? "link" : "app.dashed")
                .font(.system(size: 16)).foregroundStyle(.secondary)
        }
    }

    private var colorSwatches: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 8)], alignment: .leading, spacing: 8) {
            swatch(nil)
            ForEach(presetColors, id: \.self) { swatch($0) }
        }
    }

    private func swatch(_ color: String?) -> some View {
        let selected = selectedColor == color
        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(ThemeColor.parse(color)?.color ?? Color.clear)
                .frame(width: 28, height: 28)
            if color == nil {
                // 斜线标识「无颜色」（透明块在浅底上不可见，对应 C# transparentSwatch 的 Path）
                Path { p in
                    p.move(to: CGPoint(x: 6, y: 22))
                    p.addLine(to: CGPoint(x: 22, y: 6))
                }
                .stroke(Color.secondary, lineWidth: 2)
                .frame(width: 28, height: 28)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35),
                        lineWidth: selected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedColor = color }
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.title = Lang.t("settings.selectProgram")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application, .executable]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        target = url.path
        // 与 C# 一致：选完程序后，图标为空则带入其路径（渲染时提取程序图标），名称为空则取文件名
        if icon.trimmingCharacters(in: .whitespaces).isEmpty { icon = url.path }
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = url.deletingPathExtension().lastPathComponent
        }
    }

    private func confirm() {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { showError = true; return }
        showError = false

        let item = QuickItem()
        let n = name.trimmingCharacters(in: .whitespaces)
        // 名称留空时的兜底（对应 C# 的 `newShortcutItem` / 用 URL 或文件名兜底）
        let derived = isURL ? t : URL(fileURLWithPath: t).deletingPathExtension().lastPathComponent
        item.Name = n.isEmpty ? (derived.isEmpty ? Lang.t("nativePanel.newShortcutItem") : derived) : n
        let ic = icon.trimmingCharacters(in: .whitespaces)
        item.Icon = ic.isEmpty ? nil : ic
        item.`Type` = isURL ? "url" : "program"
        item.Target = t
        item.BackgroundColor = selectedColor   // nil = 透明（覆盖 QuickItem() 的默认蓝）
        onSave(item)
    }
}
