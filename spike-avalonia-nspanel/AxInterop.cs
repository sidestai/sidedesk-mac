using System;
using System.Runtime.InteropServices;
using Foundation;

namespace SpikeNspanel;

/// <summary>
/// Minimal Accessibility (HIServices) + CoreFoundation P/Invoke surface, ported from the proven
/// spike-ax (B1) and extended with AXObserver. Coordinates are top-left origin. All calls run on
/// the AppKit main run loop (the AXObserver source is added to the main run loop's common modes).
/// </summary>
internal static class AxInterop
{
    private const string HS = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices";
    private const string AS = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices";
    private const string CF = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";

    private const int kValueCGPoint = 1;
    private const int kValueCGSize = 2;
    private const uint kCFStringEncodingUTF8 = 0x08000100;

    [StructLayout(LayoutKind.Sequential)] struct CGP { public double x, y; }
    [StructLayout(LayoutKind.Sequential)] struct CGS { public double w, h; }

    // Managed signature of the AXObserver callback; kept alive by a static delegate in the manager.
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate void AXObserverCallback(nint axObserver, nint axUIElement, nint notificationName, nint refcon);

    [DllImport(CF)] static extern nint CFStringCreateWithCString(nint alloc, string cStr, uint enc);
    [DllImport(CF, EntryPoint = "CFArrayGetCount")] static extern nint ArrayGetCount(nint array);
    [DllImport(CF, EntryPoint = "CFArrayGetValueAtIndex")] static extern nint ArrayGetValue(nint array, nint idx);
    [DllImport(CF, EntryPoint = "CFBooleanGetValue")] static extern byte BooleanGetValue(nint cfBool);
    [DllImport(CF)] static extern nint CFRunLoopGetMain();
    [DllImport(CF)] static extern void CFRunLoopAddSource(nint rl, nint source, nint mode);
    [DllImport(CF)] static extern void CFRunLoopRemoveSource(nint rl, nint source, nint mode);

    [DllImport(HS)] static extern nint AXUIElementCreateApplication(int pid);
    [DllImport(HS)] static extern int AXUIElementCopyAttributeValue(nint e, nint attr, out nint value);
    [DllImport(HS)] static extern int AXUIElementSetAttributeValue(nint e, nint attr, nint value);
    [DllImport(HS)] static extern bool AXValueGetValue(nint value, int type, out CGP p);
    [DllImport(HS)] static extern bool AXValueGetValue(nint value, int type, out CGS s);
    [DllImport(HS)] static extern nint AXValueCreate(int type, ref CGP p);
    [DllImport(HS)] static extern nint AXValueCreate(int type, ref CGS s);
    [DllImport(HS)] static extern int AXObserverCreate(int pid, nint callback, out nint observer);
    [DllImport(HS)] static extern int AXObserverAddNotification(nint observer, nint element, nint notification, nint refcon);
    [DllImport(HS)] static extern nint AXObserverGetRunLoopSource(nint observer);

    [DllImport(AS)] static extern bool AXIsProcessTrusted();
    [DllImport(HS)] static extern bool AXIsProcessTrustedWithOptions(nint options);
    [DllImport(CF)] static extern nint CFDictionaryCreate(nint alloc, nint[] keys, nint[] values, nint count, nint keyCB, nint valueCB);

    // A source added under these mode strings fires whenever the main runloop runs in any of them.
    // Regular modes compare by CFString VALUE, so hand-made strings work here — unlike the special
    // kCFRunLoopCommonModes sentinel, which is compared by object identity and cannot be recreated.
    // Tracking mode is included so window drags (not just double-click zoom) get caught live.
    private static readonly nint ModeDefault = Str("kCFRunLoopDefaultMode");
    private static readonly nint ModeTracking = Str("NSEventTrackingRunLoopMode");
    private static readonly nint ModeModalPanel = Str("NSModalPanelRunLoopMode");
    private static readonly nint[] ObserverModes = { ModeDefault, ModeTracking, ModeModalPanel };

    public static nint Str(string s) => CFStringCreateWithCString(0, s, kCFStringEncodingUTF8);
    public static readonly nint Windows = Str("AXWindows");
    public static readonly nint Position = Str("AXPosition");
    public static readonly nint Size = Str("AXSize");
    public static readonly nint FullScreen = Str("AXFullScreen");

    // Notification string values (verified against the SDK): AXWindowMoved / AXWindowResized /
    // AXWindowCreated — window-scoped variants that bubble to the application element.
    public static readonly nint NotifyWindowMoved = Str("AXWindowMoved");
    public static readonly nint NotifyWindowResized = Str("AXWindowResized");
    public static readonly nint NotifyWindowCreated = Str("AXWindowCreated");
    public static readonly nint NotifyFocusedWindow = Str("AXFocusedWindowChanged");

    public static bool IsTrusted() => AXIsProcessTrusted();

    // Ask the system to prompt for Accessibility (non-blocking; just shows the dialog / adds to list).
    public static void PromptTrust()
    {
        nint promptKey = Str("AXTrustedCheckOptionPrompt");
        // kCFBooleanTrue is not dlsym-able from the shared cache; NSNumber is toll-free bridged to it.
        nint cfTrue = NSNumber.FromBoolean(true).Handle;
        nint opts = CFDictionaryCreate(0, new[] { promptKey }, new[] { cfTrue }, 1, 0, 0);
        AXIsProcessTrustedWithOptions(opts);
    }

    public static nint CreateApp(int pid) => AXUIElementCreateApplication(pid);

    public static nint EnumerateWindows(nint axApp)
    {
        if (AXUIElementCopyAttributeValue(axApp, Windows, out nint v) != 0) return 0;
        return v; // caller treats as CFArray of AXUIElement, indexed via WindowAt
    }

    public static int WindowCount(nint windows) => (int)ArrayGetCount(windows);

    public static nint WindowAt(nint windows, int i) => ArrayGetValue(windows, i);

    public static bool IsFullscreen(nint window)
    {
        if (AXUIElementCopyAttributeValue(window, FullScreen, out nint v) != 0 || v == 0) return false;
        return BooleanGetValue(v) != 0;
    }

    public static bool ReadPos(nint window, out double x, out double y)
    {
        x = y = 0;
        if (AXUIElementCopyAttributeValue(window, Position, out nint v) != 0 || v == 0) return false;
        if (!AXValueGetValue(v, kValueCGPoint, out CGP p)) return false;
        x = p.x; y = p.y; return true;
    }

    public static bool ReadSize(nint window, out double w, out double h)
    {
        w = h = 0;
        if (AXUIElementCopyAttributeValue(window, Size, out nint v) != 0 || v == 0) return false;
        if (!AXValueGetValue(v, kValueCGSize, out CGS s)) return false;
        w = s.w; h = s.h; return true;
    }

    public static void SetPos(nint window, double x, double y)
    {
        CGP p = new CGP { x = x, y = y };
        AXUIElementSetAttributeValue(window, Position, AXValueCreate(kValueCGPoint, ref p));
    }

    public static void SetSize(nint window, double w, double h)
    {
        CGS s = new CGS { w = w, h = h };
        AXUIElementSetAttributeValue(window, Size, AXValueCreate(kValueCGSize, ref s));
    }

    public static nint ObserverCreate(int pid, AXObserverCallback callback)
    {
        if (AXObserverCreate(pid, Marshal.GetFunctionPointerForDelegate(callback), out nint obs) != 0) return 0;
        return obs;
    }

    public static int ObserverAdd(nint observer, nint axApp, nint notification, nint refcon)
    {
        if (notification == 0) return -999; // const unresolved -> skip silently
        return AXObserverAddNotification(observer, axApp, notification, refcon);
    }

    public static void ObserverAttachToMainLoop(nint observer)
    {
        nint rl = CFRunLoopGetMain();
        nint src = AXObserverGetRunLoopSource(observer);
        foreach (nint mode in ObserverModes) CFRunLoopAddSource(rl, src, mode);
    }

    public static void ObserverDetachFromMainLoop(nint observer)
    {
        nint rl = CFRunLoopGetMain();
        nint src = AXObserverGetRunLoopSource(observer);
        foreach (nint mode in ObserverModes) CFRunLoopRemoveSource(rl, src, mode);
    }
}
