import AppKit
import SwiftUI
import Combine
import SideDeskCore
import SideDeskServices

/// 黄色桌面便签悬浮窗服务（对应 C# `Services.StickyDesktopService`，issue #300）：把某条便签以黄色便签样式
/// 常驻屏幕（钉选时置顶），可直接在窗内编辑，改动同步回便签数据；以 `note.Id` 为键幂等——已开只刷新回调与
/// 内容并激活，不重复建窗，故宿主每次重绘都可无脑对所有钉选便签重放 `open`。
///
/// 与 C# 的差异（有意收窄，依赖未移植子系统）：富文本 Markdown 编辑器已移植（`StickyRichEditor`：所见即所得 +
/// 工具条五按钮 + 窗内搜索 + 顶栏工具/搜索按钮）；但图片落盘子系统（`NoteImageService`）未移植，插入图片直接引用
/// 本地文件路径；搜索期间自动展开折叠块、边缘磁吸对齐（`.Snap` 分片）、侧栏焦点选中圈/高亮事件（#480/#490）均未接。
@MainActor
enum StickyDesktopService {

    private static var registry: [String: StickyNoteWindowController] = [:]
    private static var cascade = 0

    static func isOpen(_ noteId: String) -> Bool { registry[noteId] != nil }

    static func activate(_ noteId: String) { registry[noteId]?.activate() }

    /// 打开（或刷新）某便签的桌面悬浮窗。`persist` = 内容/几何变化后的落盘回调；`unpinned` = 用户点 ✕ 关窗回调。
    static func open(_ note: StickyNote, persist: @escaping () -> Void, unpinned: @escaping () -> Void, activate: Bool = false) {
        if let existing = registry[note.Id] {
            existing.refresh(note: note, persist: persist, unpinned: unpinned)
            if activate { existing.activate() }
            return
        }
        let controller = StickyNoteWindowController(note: note, persist: persist, unpinned: unpinned, cascadeIndex: cascade)
        cascade += 1
        registry[note.Id] = controller
        controller.present(activate: activate)
    }

    /// 静默关闭（宿主主动取消钉选/删除便签时用；不回调 `unpinned`，状态由宿主自己维护）。
    static func close(_ noteId: String) {
        guard let c = registry.removeValue(forKey: noteId) else { return }
        c.closeSilently()
    }

    /// 应用退出兜底：静默关掉全部（不记 DeskClosed，钉选项下次启动仍恢复）。
    static func closeAll() {
        let all = Array(registry.values)
        registry.removeAll()
        for c in all { c.closeSilently() }
    }

    fileprivate static func drop(_ controller: StickyNoteWindowController, noteId: String) {
        if registry[noteId] === controller { registry.removeValue(forKey: noteId) }
    }
}

/// 单张黄色便签悬浮窗。无边框（`StickyNotePanel`，重写 `canBecomeKey` 让正文可编辑）：无原生标题栏
/// 安全带，顶栏图钉/关闭按钮完整可见；拖动走背景，缩放走 `.resizable`（边缘无可见手柄，与 C# 自绘手柄收窄）。
@MainActor
final class StickyNoteWindowController: NSWindowController, NSWindowDelegate, ObservableObject {

    // 黄色便签配色（对应 C# 主题资源 BrushStickyNoteBG / Border / Text，浅深主题同值）。
    static let bgColor = Color(red: 255/255, green: 249/255, blue: 196/255)      // #FFF9C4
    static let borderColor = Color(red: 224/255, green: 200/255, blue: 98/255)     // #E0C862
    static let textColor = Color(red: 74/255, green: 59/255, blue: 0)              // #4A3B00
    static let textNSColor = NSColor(srgbRed: 74/255, green: 59/255, blue: 0, alpha: 1)

    private(set) var note: StickyNote
    private var persist: () -> Void
    private var unpinned: () -> Void

    /// 富文本编辑器模型（Markdown ⇄ 所见即所得）；正文编辑的真源，改动经 `onChange` 回写 `text`。
    let editor: StickyNoteEditorModel

    /// 正文（Markdown，与 `note.Content` 双向同步）；顶栏标题随其首行实时更新。
    @Published var text: String {
        didSet {
            guard text != oldValue else { return }
            note.Content = text
            note.UpdatedAt = Date()
            title = Self.makeTitle(text)
            schedulePersist()
        }
    }
    @Published var title: String
    @Published var pinned: Bool

    private var saveTimer: Timer?
    private var userClosed = false
    private var silent = false

    init(note: StickyNote, persist: @escaping () -> Void, unpinned: @escaping () -> Void, cascadeIndex: Int) {
        self.note = note
        self.persist = persist
        self.unpinned = unpinned
        self.text = note.Content
        self.title = Self.makeTitle(note.Content)
        self.pinned = note.Pinned
        self.editor = StickyNoteEditorModel(
            noteId: note.Id,
            markdown: note.Content,
            palette: NoteBridge.Palette(color: Self.textNSColor, size: 14, monoColor: Self.textNSColor)
        )

        let screen = NSScreen.main ?? NSScreen.screens.first
        let wa = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let work = StickyNoteGeometry.WorkArea(minX: wa.minX, minY: wa.minY, maxX: wa.maxX, maxY: wa.maxY)
        let geo = StickyNoteGeometry.resolve(note, workArea: work, cascadeIndex: cascadeIndex)

        let window = StickyNotePanel(
            contentRect: NSRect(x: geo.left, y: geo.top, width: geo.w, height: geo.h),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        // 无边框：无原生标题栏/安全带，顶栏（图钉/关闭）完整可见；拖动走背景（正文/按钮仍各自接管事件）。
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 120, height: 90)
        window.level = note.Pinned ? .floating : .normal

        super.init(window: window)
        window.delegate = self
        editor.onChange = { [weak self] markdown in
            MainActor.assumeIsolated { self?.text = markdown }
        }
        window.contentView = NSHostingView(rootView: StickyNoteView(controller: self, editor: editor))

        // 记住初始几何（还原时可能已定过位）
        note.PinLeft = geo.left; note.PinTop = geo.top
        note.PinWidth = geo.w; note.PinHeight = geo.h
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func makeTitle(_ content: String) -> String {
        let line = NotePreviewText.FirstLine(content)
        return line.isEmpty ? Lang.t("common.stickyNotes") : line
    }

    func present(activate: Bool) {
        guard let window else { return }
        window.orderFront(nil)
        if activate { self.activate() }
    }

    func activate() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 已开窗口被再次 `open`：换绑回调、同步他处改动的内容（不脏标记、不重建窗口）。
    func refresh(note: StickyNote, persist: @escaping () -> Void, unpinned: @escaping () -> Void) {
        self.note = note
        self.persist = persist
        self.unpinned = unpinned
        if note.Content != text {
            text = note.Content                 // 走 didSet 更新标题/落盘
            editor.externalUpdate(note.Content) // 重载富文本（内容一致时内部跳过）
        }
        pinned = note.Pinned
        window?.level = note.Pinned ? .floating : .normal
    }

    func togglePin() {
        pinned.toggle()
        note.Pinned = pinned
        window?.level = pinned ? .floating : .normal
        persist()
    }

    func requestClose() {
        userClosed = true
        window?.close()
    }

    func closeSilently() {
        silent = true
        window?.close()
    }

    // MARK: - 防抖落盘（对应 C# ScheduleSave，600ms）

    private func schedulePersist() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.persist() }
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) { recordGeometry() }
    func windowDidResize(_ notification: Notification) { recordGeometry() }

    private func recordGeometry() {
        guard let frame = window?.frame else { return }
        note.PinLeft = frame.minX; note.PinTop = frame.minY
        note.PinWidth = frame.width; note.PinHeight = frame.height
        schedulePersist()
    }

    func windowWillClose(_ notification: Notification) {
        saveTimer?.invalidate()
        saveTimer = nil
        StickyDesktopService.drop(self, noteId: note.Id)
        // 仅用户主动点 ✕ 才通知宿主记 DeskClosed（抑制开机恢复，#486）；静默关闭（取消钉选/删除/退出）不记。
        if userClosed && !silent { unpinned() }
    }
}

/// 黄色便签窗内容：顶栏（实时标题 + 搜索/工具/图钉/关闭）+ 可切换的工具条/搜索条 + 富文本编辑区。
private struct StickyNoteView: View {

    @ObservedObject var controller: StickyNoteWindowController
    @ObservedObject var editor: StickyNoteEditorModel

    private var fg: Color { StickyNoteWindowController.textColor }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if editor.toolbarVisible { toolbar }
            if editor.searchVisible { searchBar }
            StickyRichNoteView(model: editor)
        }
        .background(StickyNoteWindowController.bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(StickyNoteWindowController.borderColor, lineWidth: 1)
        )
    }

    // MARK: 顶栏（对应 C# 右侧从右到左 ✕/图钉/工具/搜索 → 此处左到右 标题…搜索/工具/图钉/关闭）

    private var topBar: some View {
        HStack(spacing: 6) {
            Text(controller.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(fg)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            topButton("magnifyingglass", Lang.t("common.search"), active: editor.searchVisible) {
                editor.searchVisible.toggle()
            }
            topButton("slider.horizontal.3", Lang.t("common.tools"), active: editor.toolbarVisible) {
                editor.toolbarVisible.toggle()
            }
            Button {
                controller.togglePin()
            } label: {
                Image(systemName: controller.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(fg)
                    .opacity(controller.pinned ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .help(Lang.t(controller.pinned ? "common.unpin" : "common.pin"))

            topButton("xmark", Lang.t("common.close"), active: false, semibold: true) {
                controller.requestClose()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)   // 顶栏拖拽/按钮区（无边框，完整可见）
    }

    private func topButton(_ symbol: String, _ help: String, active: Bool, semibold: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: semibold ? .semibold : .regular))
                .foregroundStyle(fg)
                .opacity(active ? 1 : 0.65)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 工具条（粗体 / 图片 / 折叠块 / 待办 / 链接）

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolButton("bold", Lang.t("common.bold")) { editor.toggleBold() }
            toolButton("photo", Lang.t("common.image")) { editor.insertImage() }
            toolButton("chevron.right", Lang.t("common.collapseBlock")) { editor.makeCollapseBlock() }
            toolButton("checklist", Lang.t("common.todoItem")) { editor.insertTodo() }
            toolButton("link", Lang.t("common.link")) { editor.insertLink() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func toolButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(fg)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 搜索条（输入 + 上一个/下一个 + 命中计数）

    private var searchBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(fg.opacity(0.6))
            TextField(Lang.t("common.search"), text: $editor.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(fg)
                .frame(minWidth: 40)
                .onSubmit { editor.findNext() }
            Text(editor.matchLabel)
                .font(.system(size: 11))
                .foregroundStyle(fg.opacity(0.7))
                .fixedSize()
            toolButton("chevron.up", Lang.t("common.findPrevious")) { editor.findPrev() }
            toolButton("chevron.down", Lang.t("common.findNext")) { editor.findNext() }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }
}

/// 无边框便签窗：默认 borderless 无法成为 key（正文没法输入），重写让其可获焦。
final class StickyNotePanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
