using System;
using System.IO;

namespace SideDesk.Framework;

/// <summary>
/// 应用数据路径（跨平台集中点）。取代散落各处的
/// <c>Path.Combine(Environment.GetFolderPath(SpecialFolder.LocalApplicationData), "SideDesk")</c>。
///
/// 平台差异：Windows 用 <c>%LocalAppData%\SideDesk</c>；macOS 用惯用的
/// <c>~/Library/Application Support/SideDesk</c>（.NET 的 LocalApplicationData 在 mac
/// 会落到 <c>~/.local/share</c>，非用户/备份工具易发现的位置，故显式改道）。
///
/// Core 面向 net9.0（非 macos TFM），无法引用 Foundation，故用 <see cref="OperatingSystem.IsMacOS"/>
/// 运行时判定 + UserProfile($HOME) 拼出 mac 路径，保持编译期平台无关。
/// </summary>
public static class AppPaths
{
    /// <summary>测试缝隙：隔离数据目录到临时目录（RuntimeMode.IsTestMode 用；null=真实路径）。</summary>
    private static string? _override;

    private static readonly string DefaultDataDir = Path.Combine(DataRoot, "SideDesk");

    /// <summary>应用数据根目录（含 "SideDesk"）。所有落盘数据的统一父目录。</summary>
    public static string DataDir => _override ?? DefaultDataDir;

    /// <summary>覆盖数据根目录（测试隔离）；传 null 复位为真实路径。</summary>
    public static void Override(string? dir) => _override = dir;

    private static string DataRoot =>
        OperatingSystem.IsMacOS()
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Application Support")
            : Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
}
