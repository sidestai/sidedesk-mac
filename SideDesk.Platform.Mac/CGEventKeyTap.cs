using System;
using System.Runtime.InteropServices;
using SideDesk.Services;

namespace SideDesk.Platform.Mac;

/// <summary>
/// <see cref="IGlobalKeyTap"/> 的 macOS 实现：Quartz **CGEventTap**（会话级活动事件搭），
/// 与 Windows 的 WH_KEYBOARD_LL 低级钩子语义一一对应——看到每个按键的按下/抬起，
/// Handler 返回 true 即从事件流中摘除该键（吞掉），否则原样放行。
///
/// 要点：
///  - 活动搭（<c>kCGEventTapOptionDefault</c>）能改/吞事件，但**要求辅助功能(AX)授权**；
///    未授权时 <c>CGEventTapCreate</c> 返回 NULL，<see cref="Start"/> 回落 false（上层提示开权限）。
///  - 键码经 <see cref="MapKeycode"/> 从 mac 虚拟键码归一到 Windows VK 空间，复用跨平台匹配逻辑。
///  - 修饰键直接取自事件的 <c>CGEventGetFlags</c>（随事件下发的实时态，比 Windows 的
///    GetAsyncKeyState 更可靠）。
///  - 事件搭回调须极快；系统因超时/用户输入禁用搭时会收到 <c>kCGEventTapDisabledBy*</c>，
///    回调内自动 <c>CGEventTapEnable(true)</c> 重启用（否则热键会静默失效）。
///  - 事件搭源挂到主 run loop 的三个具体 mode（default/event-tracking/modal-panel），
///    使拖拽窗口、模态面板期间按键仍能被捕获（common modes 无法按值重建，见 AX 移植经验）。
///
/// 线程：回调在事件搭源所属 run loop 线程（此处为主线程）触发。委托实例存字段保活，
/// 经 <see cref="Marshal.GetFunctionPointerForDelegate(object)"/> 取原生函数指针传入。
/// </summary>
public sealed class CGEventKeyTap : IGlobalKeyTap
{
    private nint _tap;          // CFMachPortRef（本类持有，Stop 时 CFRelease）
    private nint _source;       // CFRunLoopSourceRef（本类持有）
    private nint _runLoop;      // 添加源时用的 run loop（= 主 run loop）
    private bool _running;

    // 保活原生回调委托：CGEventTapCreate 会在调用返回后长期持有该函数指针，
    // 委托被 GC 会导致回调跳到已释放的 thunk → 崩溃。
    private Native.CGEventTapCallback? _callback;

    public bool IsRunning => _running;

    public Func<GlobalKeyEvent, bool>? Handler { get; set; }

    public bool Start()
    {
        if (_running) return true;

        // 活动事件搭需要辅助功能/输入监控授权；未授权直接失败（避免建出只能观察、吞不掉键的残搭）。
        if (!Native.AXIsProcessTrusted()) return false;

        try
        {
            _callback = Callback;
            nint fnPtr = Marshal.GetFunctionPointerForDelegate(_callback);

            // 只关心 keyDown / keyUp；修饰键态从每个键事件的 flags 读，无需单独订阅 flagsChanged。
            ulong mask = (1UL << (int)Native.EventType.KeyDown) | (1UL << (int)Native.EventType.KeyUp);

            _tap = Native.CGEventTapCreate(
                Native.TapLocation.Session, Native.TapPlacement.HeadInsert, Native.TapOption.Default,
                mask, fnPtr, nint.Zero);
            if (_tap == nint.Zero) { _callback = null; return false; }

            _source = Native.CFMachPortCreateRunLoopSource(nint.Zero, _tap, 0);
            if (_source == nint.Zero) { Native.CFRelease(_tap); _tap = nint.Zero; _callback = null; return false; }

            _runLoop = Native.CFRunLoopGetMain();
            Native.CFRunLoopAddSource(_runLoop, _source, Native.ModeDefault);
            Native.CFRunLoopAddSource(_runLoop, _source, Native.ModeEventTracking);
            Native.CFRunLoopAddSource(_runLoop, _source, Native.ModeModalPanel);

            Native.CGEventTapEnable(_tap, true);
            _running = true;
            return true;
        }
        catch
        {
            Stop();
            return false;
        }
    }

    public void Stop()
    {
        if (!_running && _tap == nint.Zero) return;
        try
        {
            if (_tap != nint.Zero) Native.CGEventTapEnable(_tap, false);
            if (_runLoop != nint.Zero && _source != nint.Zero)
            {
                Native.CFRunLoopRemoveSource(_runLoop, _source, Native.ModeDefault);
                Native.CFRunLoopRemoveSource(_runLoop, _source, Native.ModeEventTracking);
                Native.CFRunLoopRemoveSource(_runLoop, _source, Native.ModeModalPanel);
            }
        }
        catch { }

        if (_source != nint.Zero) { Native.CFRelease(_source); _source = nint.Zero; }
        if (_tap != nint.Zero) { Native.CFRelease(_tap); _tap = nint.Zero; }
        _runLoop = nint.Zero;
        _callback = null;
        _running = false;
    }

    /// <summary>原生事件搭回调。返回 nint.Zero=吞掉事件；返回原事件引用=放行（不拥有该引用，勿释放）。</summary>
    private nint Callback(nint proxy, uint type, nint cgEvent, nint refcon)
    {
        try
        {
            // 系统因超时/用户输入禁用搭：重启用并放行，否则热键静默失效。
            if (type == Native.EventTypeDisabledByTimeout || type == Native.EventTypeDisabledByUserInput)
            {
                if (_tap != nint.Zero) Native.CGEventTapEnable(_tap, true);
                return cgEvent;
            }

            if (type == (uint)Native.EventType.KeyDown || type == (uint)Native.EventType.KeyUp)
            {
                ushort macKeycode = (ushort)Native.CGEventGetIntegerValueField(cgEvent, Native.FieldKeycode);
                ulong flags = Native.CGEventGetFlags(cgEvent);
                var evt = new GlobalKeyEvent
                {
                    KeyCode = MapKeycode(macKeycode),
                    IsDown = type == (uint)Native.EventType.KeyDown,
                    Ctrl = (flags & Native.FlagControl) != 0,
                    Alt = (flags & Native.FlagAlternate) != 0,
                    Shift = (flags & Native.FlagShift) != 0,
                    Cmd = (flags & Native.FlagCommand) != 0,
                };

                var h = Handler;
                if (h != null)
                {
                    bool swallow = false;
                    try { swallow = h(evt); } catch { swallow = false; }
                    if (swallow) return nint.Zero;
                }
            }
        }
        catch { }
        return cgEvent;
    }

    /// <summary>
    /// mac 虚拟键码（Carbon <c>Events.h</c> 的 <c>kVK_*</c>）→ Windows 虚拟键码（VK_*）。
    /// 覆盖热键匹配所需全集：A-Z、主键盘/小键盘 0-9、F1-F12、ESC，外加常用编辑/导航键。
    /// 未列出的键返回 0（匹配逻辑忽略）。
    /// </summary>
    public static uint MapKeycode(ushort k) => k switch
    {
        // 字母（mac 键码无序，逐一对应）
        0x00 => 0x41, // A
        0x0B => 0x42, // B
        0x08 => 0x43, // C
        0x02 => 0x44, // D
        0x0E => 0x45, // E
        0x03 => 0x46, // F
        0x05 => 0x47, // G
        0x04 => 0x48, // H
        0x22 => 0x49, // I
        0x26 => 0x4A, // J
        0x28 => 0x4B, // K
        0x25 => 0x4C, // L
        0x2E => 0x4D, // M
        0x2D => 0x4E, // N
        0x1F => 0x4F, // O
        0x23 => 0x50, // P
        0x0C => 0x51, // Q
        0x0F => 0x52, // R
        0x01 => 0x53, // S
        0x11 => 0x54, // T
        0x20 => 0x55, // U
        0x09 => 0x56, // V
        0x0D => 0x57, // W
        0x07 => 0x58, // X
        0x10 => 0x59, // Y
        0x06 => 0x5A, // Z

        // 主键盘数字 → VK '0'-'9' (0x30-0x39)
        0x1D => 0x30, // 0
        0x12 => 0x31, // 1
        0x13 => 0x32, // 2
        0x14 => 0x33, // 3
        0x15 => 0x34, // 4
        0x17 => 0x35, // 5
        0x16 => 0x36, // 6
        0x1A => 0x37, // 7
        0x1C => 0x38, // 8
        0x19 => 0x39, // 9

        // 小键盘数字 → VK_NUMPAD0-9 (0x60-0x69)
        0x52 => 0x60,
        0x53 => 0x61,
        0x54 => 0x62,
        0x55 => 0x63,
        0x56 => 0x64,
        0x57 => 0x65,
        0x58 => 0x66,
        0x59 => 0x67,
        0x5B => 0x68,
        0x5C => 0x69,

        // 功能键 F1-F12 → VK_F1-F12 (0x70-0x7B)（mac 键码高度无序）
        0x7A => 0x70, // F1
        0x78 => 0x71, // F2
        0x63 => 0x72, // F3
        0x76 => 0x73, // F4
        0x60 => 0x74, // F5
        0x61 => 0x75, // F6
        0x62 => 0x76, // F7
        0x64 => 0x77, // F8
        0x65 => 0x78, // F9
        0x6D => 0x79, // F10
        0x67 => 0x7A, // F11
        0x6F => 0x7B, // F12

        // 常用编辑/导航键
        0x35 => 0x1B, // ESC
        0x24 => 0x0D, // Return
        0x30 => 0x09, // Tab
        0x31 => 0x20, // Space
        0x33 => 0x08, // Delete(退格) → VK_BACK
        0x75 => 0x2E, // ForwardDelete → VK_DELETE
        0x73 => 0x24, // Home
        0x77 => 0x23, // End
        0x74 => 0x21, // PageUp → VK_PRIOR
        0x79 => 0x22, // PageDown → VK_NEXT
        0x7B => 0x25, // Left
        0x7E => 0x26, // Up
        0x7C => 0x27, // Right
        0x7D => 0x28, // Down

        _ => 0u,
    };

    /// <summary>CoreGraphics / CoreFoundation / ApplicationServices 的 P/Invoke 与常量。</summary>
    private static class Native
    {
        private const string CG = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics";
        private const string CF = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
        private const string AS = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices";

        // ---- CGEventTap 常量 ----
        public enum TapLocation : uint { Hid = 0, Session = 1, AnnotatedSession = 2 }
        public enum TapPlacement : uint { HeadInsert = 0, TailAppend = 1 }
        public enum TapOption : uint { Default = 0, ListenOnly = 1 }
        public enum EventType : uint { KeyDown = 10, KeyUp = 11, FlagsChanged = 12 }

        // 系统禁用事件搭的两种「类型」（CGEventType 的哨兵值）
        public const uint EventTypeDisabledByTimeout = 0xFFFFFFFE;
        public const uint EventTypeDisabledByUserInput = 0xFFFFFFFF;

        public const uint FieldKeycode = 9; // kCGKeyboardEventKeycode

        // CGEventFlags 掩码
        public const ulong FlagShift = 0x00020000;
        public const ulong FlagControl = 0x00040000;
        public const ulong FlagAlternate = 0x00080000; // Option
        public const ulong FlagCommand = 0x00100000;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate nint CGEventTapCallback(nint proxy, uint type, nint cgEvent, nint refcon);

        [DllImport(CG)]
        public static extern nint CGEventTapCreate(TapLocation tap, TapPlacement place, TapOption options,
            ulong eventsOfInterest, nint callback, nint userInfo);

        [DllImport(CG)] public static extern void CGEventTapEnable(nint tap, bool enable);
        [DllImport(CG)] public static extern uint CGEventGetType(nint cgEvent);
        [DllImport(CG)] public static extern ulong CGEventGetIntegerValueField(nint cgEvent, uint field);
        [DllImport(CG)] public static extern ulong CGEventGetFlags(nint cgEvent);

        [DllImport(CF)] public static extern nint CFMachPortCreateRunLoopSource(nint allocator, nint tap, nint order);
        [DllImport(CF)] public static extern nint CFRunLoopGetMain();
        [DllImport(CF)] public static extern void CFRunLoopAddSource(nint rl, nint source, nint mode);
        [DllImport(CF)] public static extern void CFRunLoopRemoveSource(nint rl, nint source, nint mode);
        [DllImport(CF)] public static extern void CFRelease(nint cf);
        [DllImport(CF)] private static extern nint CFStringCreateWithCString(nint alloc, string cStr, uint enc);

        [DllImport(AS)] public static extern bool AXIsProcessTrusted();

        // run loop mode：按 CFString **值** 比较，故可用字面量自建（common modes 不行——见类注释）。
        private const uint KcfStringEncodingUtf8 = 0x08000100;
        public static readonly nint ModeDefault = CFStringCreateWithCString(nint.Zero, "kCFRunLoopDefaultMode", KcfStringEncodingUtf8);
        public static readonly nint ModeEventTracking = CFStringCreateWithCString(nint.Zero, "NSEventTrackingRunLoopMode", KcfStringEncodingUtf8);
        public static readonly nint ModeModalPanel = CFStringCreateWithCString(nint.Zero, "NSModalPanelRunLoopMode", KcfStringEncodingUtf8);
    }
}
