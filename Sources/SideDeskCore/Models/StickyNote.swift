import Foundation

/// 便签。对应 C# `Models.StickyNote`。真相源为 `PanelItem.StickyNotes`（随窗口配置存 local_item_row）。
public final class StickyNote: Codable {
    public var Id: String
    public var Content: String = ""
    public var CreatedAt: Date
    public var UpdatedAt: Date

    // === 钉选到桌面（issue #300）：选中后以黄色便签悬浮窗常驻屏幕 ===
    /// 是否钉选到桌面（显示为 topmost 黄色便签悬浮窗）。
    public var Pinned: Bool = false
    /// 悬浮窗左上角 X（屏幕坐标）；0 = 尚未定位。
    public var PinLeft: Double = 0
    /// 悬浮窗左上角 Y（屏幕坐标）；0 = 尚未定位。
    public var PinTop: Double = 0
    /// 悬浮窗宽；<=0 = 尚未调整过尺寸。
    public var PinWidth: Double = 0
    /// 悬浮窗高；<=0 = 尚未调整过尺寸。
    public var PinHeight: Double = 0
    /// 桌面悬浮窗是否被用户关闭（抑制 pin 的开机自动恢复，#486）。默认 false。
    public var DeskClosed: Bool = false

    public init() {
        Id = newGuidId()
        CreatedAt = Date()
        UpdatedAt = Date()
    }

    /// 预览文字：取清洗后的首个非空行，最多 30 字，无内容时返回 "(空)"。对应 C# `[JsonIgnore] Preview`。
    public var Preview: String {
        if Content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Lang.t("sticky.empty")
        }
        let firstLine = NotePreviewText.FirstLine(Content)
        if firstLine.isEmpty { return Lang.t("sticky.empty") }
        return firstLine.count > 30 ? String(firstLine.prefix(30)) + "…" : firstLine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, newGuidId())
        Content = c.or(.Content, "")
        CreatedAt = c.or(.CreatedAt, Date())
        UpdatedAt = c.or(.UpdatedAt, Date())
        Pinned = c.or(.Pinned, false)
        PinLeft = c.or(.PinLeft, 0)
        PinTop = c.or(.PinTop, 0)
        PinWidth = c.or(.PinWidth, 0)
        PinHeight = c.or(.PinHeight, 0)
        DeskClosed = c.or(.DeskClosed, false)
    }
}

/// 记事条目：与便签同构的 Markdown 笔记。对应 C# `Models.DeskNote`。
/// 真相源是 `PanelItem.DeskNotes`（随窗口配置存 local_item_row）；local_desk_note 表只是镜像写入（#443）。
public final class DeskNote: Codable {
    public var Id: String
    public var Content: String = ""
    public var CreatedAt: Date
    public var UpdatedAt: Date

    public init() {
        Id = newGuidId()
        CreatedAt = Date()
        UpdatedAt = Date()
    }

    /// 预览文字：取清洗后的首个非空行，最多 30 字，无内容时返回 "(空)"。
    public var Preview: String {
        if Content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Lang.t("sticky.empty")
        }
        let firstLine = NotePreviewText.FirstLine(Content)
        if firstLine.isEmpty { return Lang.t("sticky.empty") }
        return firstLine.count > 30 ? String(firstLine.prefix(30)) + "…" : firstLine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, newGuidId())
        Content = c.or(.Content, "")
        CreatedAt = c.or(.CreatedAt, Date())
        UpdatedAt = c.or(.UpdatedAt, Date())
    }
}
