using System;

namespace SideDesk.Services;

/// <summary>
/// 一次全局按键的原始快照。键码已归一到 **Windows 虚拟键码空间**（A-Z=0x41..0x5A、
/// 主键盘 0-9=0x30..0x39、小键盘 0-9=0x60..0x69、F1-F12=0x70..0x7B、ESC=0x1B、
/// 方向键/Home/End 等亦按 VK 取值），使两平台复用同一套组合匹配逻辑
/// （Windows 侧 <c>GlobalHotkeyService.TryMatchHotkey</c> / <c>TryWindowSwitchIndex</c>）。
/// 无法映射到 VK 空间的键，<see cref="KeyCode"/> 为 0（匹配逻辑天然忽略）。
/// </summary>
public readonly struct GlobalKeyEvent
{
    /// <summary>归一化虚拟键码（Windows VK 空间）；未知键为 0。</summary>
    public uint KeyCode { get; init; }

    /// <summary>true=按下，false=抬起。</summary>
    public bool IsDown { get; init; }

    /// <summary>Control（mac 物理 Control 键）。</summary>
    public bool Ctrl { get; init; }

    /// <summary>Alt（mac 上为 Option）。</summary>
    public bool Alt { get; init; }

    public bool Shift { get; init; }

    /// <summary>Command（mac 独有；Windows 侧恒为 false）。上层可据此把「Ctrl 系」组合重映射到 Cmd。</summary>
    public bool Cmd { get; init; }
}

/// <summary>
/// 全局按键捕获接缝。平台实现：Windows=WH_KEYBOARD_LL 低级键盘钩子；macOS=CGEventTap（Quartz 事件搭）。
/// <para>
/// 契约：安装后每个按键的按下/抬起都会回调 <see cref="Handler"/>；Handler 返回 <c>true</c> 表示
/// **吞掉**该键（不再传递给前台应用），返回 <c>false</c> 放行。这对应 Windows 钩子回调返回 1（吞）
/// 或 CallNextHookEx（放行）的语义。
/// </para>
/// <para>
/// 线程/性能纪律：Handler 在捕获线程调用，必须线程安全、零 I/O、快速返回——慢回调会被系统
/// 摘钩（Windows）或禁用事件搭（mac 触发 <c>kCGEventTapDisabledByTimeout</c>，实现应自动重启用）。
/// 跨线程访问 UI 需自行调度回主线程。
/// </para>
/// </summary>
public interface IGlobalKeyTap
{
    /// <summary>事件搭/钩子是否已安装并启用。</summary>
    bool IsRunning { get; }

    /// <summary>按键事件处理器（捕获线程调用）。返回 true=吞掉该键。null=只观察不吞。</summary>
    Func<GlobalKeyEvent, bool>? Handler { get; set; }

    /// <summary>
    /// 安装全局按键捕获（幂等）。需要平台权限（mac=辅助功能/输入监控 AX）；
    /// 未授权或创建失败返回 false，调用方据此提示用户开权限。
    /// </summary>
    bool Start();

    /// <summary>卸载捕获（幂等）。</summary>
    void Stop();
}
