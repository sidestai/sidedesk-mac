using System;
using SideDesk.Composition;

namespace SideDesk.Services;

/// <summary>
/// 全局热键编排（**平台无关**）：消费 <see cref="IGlobalKeyTap"/> 的原始按键流，做边沿防抖
/// （<see cref="KeyTransitionFilter"/>）+ 组合匹配，产出语音启停/取消与窗口切换事件。
///
/// 移植自 Windows 的 <c>GlobalHotkeyService</c>——把「捕获」下沉到接缝（Win=WH_KEYBOARD_LL 钩子 /
/// mac=CGEventTap），本类只保留两平台一致的判定逻辑。键码已由接缝归一到 Windows VK 空间，
/// 故 <see cref="TryMatchHotkey"/> / <see cref="TryWindowSwitchIndex"/> 与 Windows 版逐字一致。
///
/// 三类热键：
///  1) 语音启动组合（默认 Ctrl+B）；
///  2) 语音停止组合（默认同 Ctrl+B → 同键切换：先停后启，由订阅方按录音态决定行为）；
///  3) 窗口切换 Ctrl+1~9（默认关闭，命中吞键避免传给前台应用）；
///  另有：录音态按无修饰 ESC 取消语音会话（仅录音态吞 ESC）。
///
/// 修饰键匹配认 Ctrl/Alt/Shift/Cmd（Cmd 在 Windows 侧恒 false，故 "Ctrl+B" 两平台都只认物理
/// Control）——组合字符串里没写的修饰键必须处于「未按下」态才算命中（避免 Ctrl+Alt+B 误命中 Ctrl+B）。
/// 事件统一经 <see cref="ServiceSeam.UiPost"/> 投递到 UI 线程（无 UI 宿主时同步直调）。
///
/// 线程：<see cref="OnKeyEvent"/> 在捕获线程调用——零 I/O、快速返回；触发的业务动作一律
/// UiPost 出去，回调本身只读设置快照 + 计量。
/// </summary>
public sealed class GlobalHotkeyService
{
    private readonly KeyTransitionFilter _keyEdge = new();
    private IGlobalKeyTap? _tap;

    /// <summary>生产构造：按键捕获接缝经 <see cref="AppContainer"/> 惰性解析（组合根注册后生效）。</summary>
    public GlobalHotkeyService() { }

    /// <summary>测试构造：注入假捕获接缝即可驱动真实判定逻辑（无需平台权限）。</summary>
    internal GlobalHotkeyService(IGlobalKeyTap tap)
    {
        _tap = tap;
        _tap.Handler = OnKeyEvent;
    }

    /// <summary>惰性取捕获接缝并挂上处理器（生产路径；注册晚于本服务构造时也能接上）。</summary>
    private IGlobalKeyTap? Tap
    {
        get
        {
            if (_tap == null && AppContainer.TryResolve<IGlobalKeyTap>(out var t) && t != null)
            {
                _tap = t;
                _tap.Handler = OnKeyEvent;
            }
            return _tap;
        }
    }

    /// <summary>捕获是否已安装并运行。</summary>
    public bool IsRunning => Tap?.IsRunning ?? false;

    /// <summary>
    /// 录音态判定接缝：捕获回调据此决定 ESC 是否作为「取消语音」吞掉。实现必须线程安全、零 I/O
    /// （读 Interlocked 计量即可，禁止跨线程访问 UI 对象）。null = 无语音会话（ESC 原样放行）。
    /// </summary>
    public Func<bool>? VoiceRecordingProvider { get; set; }

    /// <summary>语音启动热键命中（已按设置过滤，命中即吞键）。</summary>
    public event Action? VoiceStartRequested;

    /// <summary>语音停止热键命中。</summary>
    public event Action? VoiceStopRequested;

    /// <summary>聆听中按 ESC 请求取消语音会话（仅录音态命中，命中即吞 ESC）。</summary>
    public event Action? VoiceCancelRequested;

    /// <summary>Ctrl+1~9 请求切换到第 <c>index</c>（0 基）个窗口标签（命中即吞键）。</summary>
    public event Action<int>? WindowSwitchRequested;

    /// <summary>安装全局按键捕获（幂等）。无接缝或未授权返回 false。</summary>
    public bool Start()
    {
        var tap = Tap;
        if (tap == null) return false;
        _keyEdge.Reset(); // 重装清边沿状态（防陈旧按住标记）
        return tap.Start();
    }

    /// <summary>卸载捕获（幂等）。</summary>
    public void Stop() => Tap?.Stop();

    /// <summary>按当前设置的各热键开关刷新捕获启停（任一功能开启即安装）。</summary>
    public void RefreshState()
    {
        if (Tap == null) return;
        try
        {
            var s = Snapshot();
            if (s.EnableWindowSwitchHotkey || s.EnableVoiceInputHotkey) Start();
            else Stop();
        }
        catch (Exception ex)
        {
            Framework.RuntimeLog.Debug($"[GlobalHotkey] failed to refresh enabled state: {ex.Message}");
        }
    }

    /// <summary>设置快照（解耦 UI 宿主）：从 <see cref="ServiceSeam.Settings"/> 一次读出，避免回调中途被改。</summary>
    private sealed record HotkeySettingsSnapshot(
        bool EnableVoiceInputHotkey, string VoiceStartHotkey, string VoiceStopHotkey, bool EnableWindowSwitchHotkey);

    private static HotkeySettingsSnapshot Snapshot()
    {
        var s = ServiceSeam.Settings;
        return new HotkeySettingsSnapshot(
            s.EnableVoiceInputHotkey, s.VoiceStartHotkey, s.VoiceStopHotkey, s.EnableWindowSwitchHotkey);
    }

    /// <summary>捕获线程回调：返回 true = 吞掉该键（不传前台应用）。仅按下可吞；抬起只维护边沿状态。</summary>
    private bool OnKeyEvent(GlobalKeyEvent e)
    {
        if (!e.IsDown)
        {
            _keyEdge.OnKeyUp(e.KeyCode);
            return false;
        }

        bool firstDown = _keyEdge.OnKeyDown(e.KeyCode);
        var settings = Snapshot();

        // ESC 取消优先于语音启停——录音态下 ESC 是「取消」而非普通按键。
        if (TryHandleVoiceCancelEscape(e, firstDown)) return true;
        if (TryHandleVoiceHotkey(settings, e, firstDown)) return true;
        if (TryHandleWindowSwitch(settings, e, firstDown)) return true;
        return false;
    }

    /// <summary>
    /// ESC 取消语音：仅当有语音会话正在录音、且是无修饰键的单独 ESC 首按时命中，投递取消并吞键；
    /// 非录音态返回 false 放行（ESC 在其它应用/窗口行为不受影响）。
    /// </summary>
    private bool TryHandleVoiceCancelEscape(GlobalKeyEvent e, bool firstDown)
    {
        if (e.KeyCode != 0x1B || !firstDown || e.Ctrl || e.Alt || e.Shift) return false;
        if (!(VoiceRecordingProvider?.Invoke() ?? false)) return false;
        Fire(() => VoiceCancelRequested?.Invoke());
        return true;
    }

    /// <summary>
    /// 语音启停热键：停止组合更具体，优先匹配；修饰键必须完全一致。启停组合相同时视为切换键：
    /// 先通知停止再通知启动。命中即整体吞键（含按住期间重复），仅首按触发事件。
    /// </summary>
    private bool TryHandleVoiceHotkey(HotkeySettingsSnapshot s, GlobalKeyEvent e, bool firstDown)
    {
        if (!s.EnableVoiceInputHotkey) return false;

        bool sameCombo = string.Equals(s.VoiceStartHotkey, s.VoiceStopHotkey, StringComparison.OrdinalIgnoreCase);
        bool stopHit = TryMatchHotkey(s.VoiceStopHotkey, e);
        bool startHit = (stopHit && sameCombo) || TryMatchHotkey(s.VoiceStartHotkey, e);
        if (!stopHit && !startHit) return false;

        if (firstDown)
        {
            if (stopHit) Fire(() => VoiceStopRequested?.Invoke());
            if (startHit) Fire(() => VoiceStartRequested?.Invoke());
        }
        return true;
    }

    /// <summary>窗口切换 Ctrl+1~9：需 Ctrl 按下且主键落在 1~9（主键盘或小键盘）；命中吞键，仅首按切窗。</summary>
    private bool TryHandleWindowSwitch(HotkeySettingsSnapshot s, GlobalKeyEvent e, bool firstDown)
    {
        if (!s.EnableWindowSwitchHotkey || !e.Ctrl) return false;
        if (!TryWindowSwitchIndex(e.KeyCode, out int index)) return false;
        if (firstDown)
        {
            int idx = index;
            Fire(() => WindowSwitchRequested?.Invoke(idx));
        }
        return true;
    }

    /// <summary>事件投递到 UI 线程（无 UI 宿主时 <see cref="ServiceSeam.UiPost"/> 同步直调）。</summary>
    private static void Fire(Action action) => ServiceSeam.UiPost(action);

    /// <summary>
    /// 窗口切换热键的键位映射单一实现：主键盘 1~9（0x31-0x39）与小键盘 1~9（0x61-0x69）→ 0 基下标。
    /// </summary>
    public static bool TryWindowSwitchIndex(uint vkCode, out int index)
    {
        if (vkCode >= 0x31 && vkCode <= 0x39) { index = (int)(vkCode - 0x31); return true; }
        if (vkCode >= 0x61 && vkCode <= 0x69) { index = (int)(vkCode - 0x61); return true; }
        index = -1;
        return false;
    }

    /// <summary>
    /// 匹配形如 "Ctrl+Alt+B" / "Cmd+B" 的热键字符串：修饰键状态必须与组合完全一致
    /// （组合里没写的修饰键须处于未按下态），主键虚拟键码一致。主键支持字母 A~Z、数字 0~9、F1~F12。
    /// Cmd/Win 作为一等修饰键参与严格匹配——Windows 侧 <see cref="GlobalKeyEvent.Cmd"/> 恒 false，
    /// 故 "Ctrl+B" 在两平台都只认物理 Control（不会误吞 Cmd+B），mac 亦可直接配 "Cmd+B"。
    /// </summary>
    private static bool TryMatchHotkey(string? combo, GlobalKeyEvent e)
    {
        if (string.IsNullOrWhiteSpace(combo)) return false;
        bool needCtrl = false, needAlt = false, needShift = false, needCmd = false;
        string? main = null;

        foreach (string part in combo.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            string p = part.Trim().ToLowerInvariant();
            switch (p)
            {
                case "ctrl": case "control": needCtrl = true; break;
                case "alt": case "option": needAlt = true; break;
                case "shift": needShift = true; break;
                case "cmd": case "command": case "meta": case "win": needCmd = true; break;
                default: main = part.Trim(); break;
            }
        }

        if (main == null) return false;
        if (needCtrl != e.Ctrl || needAlt != e.Alt || needShift != e.Shift || needCmd != e.Cmd) return false;

        uint targetVk;
        if (main.Length == 1)
        {
            char c = char.ToUpperInvariant(main[0]);
            if (c >= 'A' && c <= 'Z') targetVk = (uint)c;
            else if (c >= '0' && c <= '9') targetVk = (uint)c;
            else return false;
        }
        else if (main.StartsWith("F", StringComparison.OrdinalIgnoreCase)
                 && int.TryParse(main.AsSpan(1), out int fn) && fn >= 1 && fn <= 12)
        {
            targetVk = 0x70u + (uint)(fn - 1); // F1~F12
        }
        else return false;

        return e.KeyCode == targetVk;
    }
}
