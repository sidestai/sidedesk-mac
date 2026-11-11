import Foundation
import SideDeskCore

/// 快捷分组管理服务（对应 C# `Services.QuickGroupService`，#335：静态门面改实例服务）。
///
/// 全部操作代理到 `WindowConfigManager` 内的快捷面板（`Type == .QuickGroup`）；
/// 内存变更由调用方（UI）触发 `Save()` 落库。
///
/// **推迟**：`MigrateLegacyOnce`（quickgroups.json / bookmarks/aitools/programs 遗留 JSON 迁移，
/// 仅 Windows 升级用户有意义，fresh Mac 无这些文件）。
public final class QuickGroupService {

    private weak var mgr: WindowConfigManager?

    /// WindowConfigManager 加载完成后注入全局配置管理器（每次 Load 重赋值）。
    public func Init(_ mgr: WindowConfigManager) { self.mgr = mgr }

    // MARK: - 面板枚举

    /// 按声明顺序枚举全部快捷面板（含嵌套子面板）。
    private func enumerateQuickPanels() -> [PanelItem] {
        guard let mgr else { return [] }
        var result: [PanelItem] = []
        func collect(_ panels: [PanelItem]) {
            for p in panels {
                if p.`Type` == .QuickGroup { result.append(p) }
                if let children = p.ChildPanels { collect(children) }
            }
        }
        for win in mgr.Windows { collect(win.Panels) }
        return result
    }

    private func findPanel(_ groupId: String) -> PanelItem? {
        enumerateQuickPanels().first { $0.Id == groupId }
    }

    // MARK: - 门面 API

    public func GetAll() -> [QuickGroup] {
        enumerateQuickPanels().map { QuickGroup($0) }
    }

    public func Save() { mgr?.Save() }

    /// 新增快捷面板：优先 targetWindow，缺省落第一个窗口。
    public func AddGroup(_ group: QuickGroup, targetWindow: WindowConfig? = nil) {
        guard let mgr, !mgr.Windows.isEmpty else { return }
        let win = targetWindow ?? mgr.Windows[0]
        win.Panels.append(group.Panel)
    }

    /// 按 Id 删除快捷面板（递归查找嵌套子面板）。
    public func RemoveGroup(_ groupId: String) {
        guard let mgr else { return }
        func removeFrom(_ panels: inout [PanelItem]) -> Bool {
            if let idx = panels.firstIndex(where: { $0.Id == groupId }) {
                panels.remove(at: idx); return true
            }
            for i in panels.indices {
                if var children = panels[i].ChildPanels, removeFrom(&children) {
                    panels[i].ChildPanels = children; return true
                }
            }
            return false
        }
        for win in mgr.Windows where !win.Panels.isEmpty {
            var panels = win.Panels
            if removeFrom(&panels) { win.Panels = panels; return }
        }
    }

    /// 获取可用快捷面板 Id：已有面板取第一个，否则新建一个。
    public func GetOrCreateDefaultGroup() -> String {
        let panels = enumerateQuickPanels()
        if let first = panels.first { return first.Id }
        let g = QuickGroup()
        g.Name = "快捷方式"
        g.Columns = 2
        AddGroup(g)
        return g.Id
    }

    public func AddItem(_ groupId: String, _ item: QuickItem) {
        guard let p = findPanel(groupId) else { return }
        if p.QuickItems == nil { p.QuickItems = [] }
        item.SortIndex = p.QuickItems!.count   // 追加末尾并赋末位序号（列表始终按 SortIndex 有序）
        p.QuickItems!.append(item)
    }

    public func RemoveItem(_ groupId: String, _ itemId: String) {
        findPanel(groupId)?.QuickItems?.removeAll { $0.Id == itemId }
    }

    /// 重排分组内所有项的 SortIndex 为 0..n-1（拖拽调序/跨组移动后调用）。
    public func ReindexItems(_ groupId: String) {
        guard let items = findPanel(groupId)?.QuickItems else { return }
        for i in items.indices { items[i].SortIndex = i }
    }

    /// 按 SortIndex 稳定排序（同序号按 CreatedAt 兜底，保证多端一致）。
    /// 旧数据无 SortIndex 时全为 0，退化为按创建时间排序。
    public static func SortByIndex(_ items: inout [QuickItem]?) {
        guard let arr = items, arr.count >= 2 else { return }
        items = arr.sorted { ($0.SortIndex, $0.CreatedAt) < ($1.SortIndex, $1.CreatedAt) }
    }

    /// 门面模式属性直接代理面板，无需额外回写（保留签名兼容调用点）。
    public func UpdateGroup(_ group: QuickGroup) {}

    /// 退出时调用：删除「来自添加窗口」且未勾选长期窗口的临时项。返回删除数量。
    public func RemoveTransientWindowItems() -> Int {
        var count = 0
        for p in enumerateQuickPanels() {
            guard var items = p.QuickItems else { continue }
            let before = items.count
            items.removeAll { $0.Source == "window" && !$0.IsLongTermWindow }
            if items.count != before {
                count += before - items.count
                p.QuickItems = items
            }
        }
        return count
    }
}
