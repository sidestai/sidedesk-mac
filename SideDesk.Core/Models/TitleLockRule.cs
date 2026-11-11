namespace SideDesk.Models;

/// <summary>
/// 标题匹配模式（当 MatchPattern 非空时生效）。
/// </summary>
public enum TitleMatchMode
{
    Equals = 0,
    Contains = 1
}

/// <summary>
/// 单条标题锁定规则：进程名 + 锁定前标题 + 进程目录 + 锁定后文字。
/// 可选：MatchPattern + MatchMode 用于更灵活的启动自动恢复匹配。
/// </summary>
public class TitleLockRule
{
    public string ProcessName { get; set; } = string.Empty;
    public string OriginalTitle { get; set; } = string.Empty;
    public string ExecutableDir { get; set; } = string.Empty;
    public string LockText { get; set; } = string.Empty;
    // 可选的模糊匹配字符串。非空时优先用于 RestoreLocksFromRules 和主动匹配；为 null 表示走精确匹配。
    public string? MatchPattern { get; set; }
    public TitleMatchMode MatchMode { get; set; } = TitleMatchMode.Contains;
    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }
}
