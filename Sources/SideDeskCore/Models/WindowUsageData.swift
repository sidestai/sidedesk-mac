import Foundation

/// 单条窗口日志记录。对应 C# `Models.WindowRecord`（`TimeSpan Duration` → `TimeInterval` 秒）。
public final class WindowRecord: Codable {
    public var Timestamp: Date = Date()
    public var ClassName: String = ""
    public var Title: String = ""
    public var ProcessName: String = ""
    public var ExePath: String = ""
    public var Url: String = ""
    public var Duration: TimeInterval = 0
    public init() {}
}

/// 应用子项（域名/标题维度的使用时长）。对应 C# `Models.AppUsageSubItem`。
public final class AppUsageSubItem: Codable {
    public var Name: String = ""
    public var Category: String = ""
    public var TotalDuration: TimeInterval = 0
    public init() {}
}

/// 按进程名汇总的使用时长。对应 C# `Models.AppUsageItem`。
public final class AppUsageItem: Codable {
    public var ProcessName: String = ""
    public var ExePath: String = ""
    public var Category: String = ""
    public var TotalDuration: TimeInterval = 0
    /// 子项（浏览器按域名、微信按标题等），无子项时为空列表。
    public var SubItems: [AppUsageSubItem] = []
    public init() {}
}
