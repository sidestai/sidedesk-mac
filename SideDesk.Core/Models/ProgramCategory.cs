namespace SideDesk.Models;

/// <summary>
/// 程序使用分类：进程名 → 类别映射
/// </summary>
public class ProgramCategory
{
    public string ProcessName { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
}
