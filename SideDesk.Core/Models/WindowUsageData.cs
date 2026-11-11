using System;
using System.Collections.Generic;

namespace SideDesk.Models;

/// <summary>
/// 单条窗口日志记录
/// </summary>
public class WindowRecord
{
    public DateTime Timestamp { get; set; }
    public string ClassName { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string ProcessName { get; set; } = string.Empty;
    public string ExePath { get; set; } = string.Empty;
    public string Url { get; set; } = string.Empty;
    public TimeSpan Duration { get; set; }
}

/// <summary>
/// 按进程名汇总的使用时长
/// </summary>
public class AppUsageItem
{
    public string ProcessName { get; set; } = string.Empty;
    public string ExePath { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public TimeSpan TotalDuration { get; set; }
    /// <summary>子项（浏览器按域名、微信按标题等），无子项时为空列表</summary>
    public List<AppUsageSubItem> SubItems { get; set; } = new List<AppUsageSubItem>();
}

/// <summary>
/// 应用子项（域名/标题维度的使用时长）
/// </summary>
public class AppUsageSubItem
{
    public string Name { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public TimeSpan TotalDuration { get; set; }
}
