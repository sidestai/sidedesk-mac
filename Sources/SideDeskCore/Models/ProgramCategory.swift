import Foundation

/// 程序使用分类：进程名 → 类别映射。对应 C# `Models.ProgramCategory`。
public final class ProgramCategory: Codable {
    public var ProcessName: String = ""
    public var Category: String = ""
    public init() {}
}
