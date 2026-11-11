import Foundation
import SideDeskCore

/// 行级变更追踪器的静态映射部分（对应 C# `RowChangeTracker.GetRowType/IsRowSyncable`）。
///
/// C# 的实例 API（MarkModified/TakeChanges 等）已无调用方——行推送实际走快照差分
/// （见 CloudSyncService+Rows），故只移植两个静态函数。
public enum RowChangeTracker {

    /// PanelType → 行类型映射（服务端协议字符串）。对应 C# `GetRowType`。
    public static func getRowType(_ type: PanelType) -> String {
        switch type {
        case .StickyNotes: return "sticky_note"
        case .Notes: return "desk_note"
        case .TodoList: return "todo"
        case .Timer: return "timer"
        case .Countdown: return "countdown"
        case .SignalLight: return "signal_light"
        case .Clipboard: return "clipboard"
        case .FileArea: return "file_area"
        case .Pomodoro: return "pomodoro"
        case .DataDashboard: return "dashboard"
        case .DigitalEmployee: return "digital_employee"
        case .Friend: return "friend_user"
        case .QuickGroup: return "shortcut"
        case .CheckIn: return "check_in"
        default: return "unknown"
        }
    }

    /// 判断模块类型是否支持行级同步。对应 C# `IsRowSyncable`。
    public static func isRowSyncable(_ type: PanelType) -> Bool {
        getRowType(type) != "unknown"
    }
}

extension PanelType {
    /// 服务端协议名 = 枚举 case 名（Swift case 名与 C# 逐一对应，String(describing:) 即 C# ToString()）。
    public var serverName: String { String(describing: self) }

    /// 从服务端类型名解析（大小写不敏感，对应 C# `Enum.TryParse(ignoreCase: true)`；
    /// 未知类型回落 StickyNotes，与 C# BuildPanelFromServerItem 的兜底一致）。
    public static func from(serverName: String) -> PanelType {
        let lower = serverName.lowercased()
        return allCases.first { $0.serverName.lowercased() == lower } ?? .StickyNotes
    }
}