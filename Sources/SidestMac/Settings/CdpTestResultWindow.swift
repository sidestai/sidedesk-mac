import AppKit

/// CDP 连接自检结果窗（对应 C# `Views/CdpTestResultWindow`：520×400、只读换行文本、纵向滚动、
/// 等宽字体；标题与正文由调用方传入，窗口自身无逻辑）。
@MainActor
final class CdpTestResultWindowController: NSWindowController {

    private let textView = NSTextView()

    convenience init() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = scroll

        self.init(window: window)
        configureTextView(inside: scroll)
    }

    private func configureTextView(inside scroll: NSScrollView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: .greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                       height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
    }

    func show(title: String, text: String) {
        window?.title = title
        textView.string = text
        textView.scroll(NSPoint.zero)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// 结果窗单例入口：重复测试复用同一窗口，只换正文。
enum CdpTestResult {
    @MainActor private static var controller: CdpTestResultWindowController?

    @MainActor static func show(title: String, text: String) {
        if controller == nil { controller = CdpTestResultWindowController() }
        controller?.show(title: title, text: text)
    }
}
