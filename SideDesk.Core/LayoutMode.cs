namespace SideDesk;

/// <summary>
/// 侧栏停靠布局（提取自 Windows AppBarWindow.cs 的同名顶层枚举）。
/// 纯枚举、无平台依赖 —— Settings/AppSettings 持久化会引用它，故置于 Core。
/// </summary>
public enum LayoutMode
{
    // 顺序不可重排：旧版 settings.json 以整数序列化枚举（Left=0/Right=1/Both=2），
    // 新增的 None 必须追加在末尾，否则会使旧配置的 Left 被误读为 None。
    Left,
    Right,
    Both,
    None
}
