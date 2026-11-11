using System.Collections.Generic;

namespace SideDesk.Services;

/// <summary>
/// 按键边沿过滤器：全局按键捕获（Win 的 WM_KEYDOWN / mac 的 CGEventTap keyDown）含系统自动重复
/// （按住 ~30Hz），只有 **up→down 跳变**才算一次真实按压——同键切换热键（如 Ctrl+B 语音启停）
/// 若无此过滤，按住会以 ~0.5s 周期反复触发启停形成「抖动」。纯逻辑，可单测；移植自 Windows 同名类。
/// </summary>
internal sealed class KeyTransitionFilter
{
    private readonly HashSet<uint> _down = new();

    /// <summary>按下事件：仅当该键此前不在按下集合（up→down 跳变）返回 true；自动重复返回 false。</summary>
    public bool OnKeyDown(uint vk) => _down.Add(vk);

    /// <summary>抬起事件：移除按下标记（遗漏抬起会导致该键永久判重复，捕获重装时 Reset 兜底）。</summary>
    public void OnKeyUp(uint vk) => _down.Remove(vk);

    /// <summary>清空状态（捕获重装/失焦兜底）。</summary>
    public void Reset() => _down.Clear();
}
