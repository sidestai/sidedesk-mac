/// 侧栏停靠布局。对应 Windows C# 的 `SideDesk.LayoutMode`（提取自 AppBarWindow.cs）。
///
/// 顺序不可重排：旧版 settings.json 以整数序列化枚举（Left=0 / Right=1 / Both=2），
/// 新增的 none 必须追加在末尾，否则会使旧配置的 left 被误读为 none。
public enum LayoutMode: Int, Codable {
    case left = 0
    case right = 1
    case both = 2
    case none = 3
}
