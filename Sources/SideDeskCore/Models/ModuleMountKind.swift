import Foundation

/// 模块挂载形态（module.json 的 mounts 字段）：安装期声明"这个模块以什么形态出现在宿主里"
/// （对应 C# ModuleMountKind）。形态之间不互斥（数组多选）。缺省 = 不挂任何 UI 面。
public enum ModuleMountKind: Equatable {
    /// 卡片：可添加到左侧卡片流（PanelType.ModuleUi；懒激活挂卡片首次渲染）
    case card
    /// 后台：无界面模块，宿主启动即拉起边车常驻
    case background
    /// 工具：工具页「第三方模块」区的工具面板
    case tool
    /// 悬浮：非卡片流的桌面悬浮窗
    case overlay
}

/// mounts 字段的字符串白名单与解析（宽松解析：未知值不参与挂载分发，不炸整份清单）。
public enum ModuleMounts {
    public static let card = "card"
    public static let background = "background"
    public static let tool = "tool"
    public static let overlay = "overlay"

    /// 解析单个形态字符串（未知/空 = nil）
    public static func parse(_ raw: String?) -> ModuleMountKind? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case card: return .card
        case background: return .background
        case tool: return .tool
        case overlay: return .overlay
        default: return nil
        }
    }

    /// 枚举 → 清单字符串
    public static func token(_ kind: ModuleMountKind) -> String {
        switch kind {
        case .card: return card
        case .background: return background
        case .tool: return tool
        case .overlay: return overlay
        }
    }

    /// 形态的本地化名（显式完整键，非拼接）
    public static func displayName(_ kind: ModuleMountKind) -> String {
        Lang.t({
            switch kind {
            case .card: return "moduleMounts.card"
            case .background: return "moduleMounts.background"
            case .tool: return "moduleMounts.tool"
            case .overlay: return "moduleMounts.overlay"
            }
        }())
    }
}
