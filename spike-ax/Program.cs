using System;
using System.Runtime.InteropServices;

// Spike B1: reposition another app's windows via Accessibility purely through
// P/Invoke (no AppKit bindings). Proves the C# port of the Swift WindowManager.
// Usage: dotnet run -- <targetPid>   (terminal must have Accessibility permission)

if (args.Length < 1 || !int.TryParse(args[0], out int pid))
{
    Console.Error.WriteLine("usage: spike-ax <pid> [forceonly]");
    return 2;
}
bool forceOnly = args.Length >= 2 && args[1] == "forceonly";

Console.WriteLine($"trusted = {Ax.IsTrusted()}");
Console.WriteLine($"target pid = {pid}");

nint app = Ax.CreateApp(pid);
nint windowsValue = 0;
int err = Ax.CopyAttribute(app, Ax.Windows, out windowsValue);
if (err != 0)
{
    Console.Error.WriteLine($"copy AXWindows failed err={err}");
    return 1;
}

int count = (int)Nf.ArrayGetCount(windowsValue);
Console.WriteLine($"windows = {count}");

for (int i = 0; i < count; i++)
{
    nint window = Nf.ArrayGetValue(windowsValue, i);

    // Skip native-fullscreen windows (they can't and shouldn't be inset).
    if (Ax.ReadBool(window, Ax.FullScreen))
    {
        Console.WriteLine($"  [{i}] fullscreen -> skip");
        continue;
    }

    if (!Ax.ReadPoint(window, Ax.Position, out CGPoint pos)) continue;
    if (!Ax.ReadSize(window, Ax.Size, out CGSize size)) continue;

    const double inset = 100;
    double screenW = 1920; // spike assumption: single main display width

    if (forceOnly)
    {
        // Push one sizable window to full-width x:0 and stop — the running spike's
        // WindowManager (AXObserver) should be the thing that clamps it back.
        if (size.height > 200 && !Ax.ReadBool(window, Ax.FullScreen))
        {
            Ax.SetPoint(window, Ax.Position, new CGPoint(0, pos.y));
            Ax.SetSize(window, Ax.Size, new CGSize(screenW, size.height));
            Console.WriteLine($"  [{i}] forced x:0 w:1920 (no clamp)");
        }
        continue;
    }

    // If it already sits inside the insets, force a violating geometry first so
    // the clamp has something real to correct (safe: target is a throwaway window).
    double left0 = pos.x, right0 = pos.x + size.width;
    if (left0 >= inset - 0.5 && right0 <= screenW - inset + 0.5 && size.height > 200)
    {
        pos.x = 0; size.width = screenW;                 // span both edges -> must clamp
        Ax.SetPoint(window, Ax.Position, pos);
        Ax.SetSize(window, Ax.Size, size);
        if (Ax.ReadPoint(window, Ax.Position, out pos) && Ax.ReadSize(window, Ax.Size, out size))
            Console.WriteLine($"  [{i}] forced-violation pos=({pos.x},{pos.y}) size=({size.width},{size.height})");
    }

    double left = pos.x, right = pos.x + size.width;
    Console.WriteLine($"  [{i}] before pos=({pos.x},{pos.y}) size=({size.width},{size.height})");

    if (left < inset - 0.5 || right > screenW - inset + 0.5)
    {
        double newLeft = Math.Max(left, inset);
        double newRight = Math.Min(right, screenW - inset);
        double newWidth = Math.Max(120, newRight - newLeft);
        pos.x = newLeft;
        size.width = newWidth;

        int e1 = Ax.SetPoint(window, Ax.Position, pos);
        int e2 = Ax.SetSize(window, Ax.Size, size);
        Console.WriteLine($"       set pos err={e1}, size err={e2}");

        // Re-read to confirm the clamp actually applied.
        if (Ax.ReadPoint(window, Ax.Position, out CGPoint verify)
            && Ax.ReadSize(window, Ax.Size, out CGSize vsize))
        {
            Console.WriteLine($"  [{i}] after  pos=({verify.x},{verify.y}) size=({vsize.width},{vsize.height})");
        }
    }
    else
    {
        // Already inside insets — still exercise the write path once (no-op move)
        // to prove AXValueCreate + SetAttributeValue succeed (err 0).
        int e1 = Ax.SetPoint(window, Ax.Position, pos);
        Console.WriteLine($"       already within insets; write-path test pos err={e1}");
    }
}

return 0;

static class Nf
{
    const string CF = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";

    [DllImport(CF)] public static extern nint CFStringCreateWithCString(nint alloc, string cStr, uint enc);
    [DllImport(CF, EntryPoint = "CFArrayGetCount")] public static extern nint ArrayGetCount(nint array);
    [DllImport(CF, EntryPoint = "CFArrayGetValueAtIndex")] public static extern nint ArrayGetValue(nint array, nint idx);
    [DllImport(CF, EntryPoint = "CFBooleanGetValue")] public static extern byte BooleanGetValue(nint cfBool);

    public static nint Str(string s) => CFStringCreateWithCString(0, s, 0x08000100 /*UTF8*/);
}

static class Ax
{
    const string HS = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices";

    public static readonly nint Windows = Nf.Str("AXWindows");
    public static readonly nint Position = Nf.Str("AXPosition");
    public static readonly nint Size = Nf.Str("AXSize");
    public static readonly nint FullScreen = Nf.Str("AXFullScreen");

    const int kValueCGPoint = 1;
    const int kValueCGSize = 2;

    [StructLayout(LayoutKind.Sequential)] struct CGP { public double x, y; }
    [StructLayout(LayoutKind.Sequential)] struct CGS { public double w, h; }

    [DllImport(HS)] static extern nint AXUIElementCreateApplication(int pid);
    [DllImport(HS)] static extern int AXUIElementCopyAttributeValue(nint e, nint attr, out nint value);
    [DllImport(HS)] static extern int AXUIElementSetAttributeValue(nint e, nint attr, nint value);
    [DllImport(HS)] static extern bool AXValueGetValue(nint value, int type, out CGP p);
    [DllImport(HS)] static extern bool AXValueGetValue(nint value, int type, out CGS s);
    [DllImport(HS)] static extern nint AXValueCreate(int type, ref CGP p);
    [DllImport(HS)] static extern nint AXValueCreate(int type, ref CGS s);
    [DllImport("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")]
    static extern bool AXIsProcessTrusted();

    public static bool IsTrusted() => AXIsProcessTrusted();
    public static nint CreateApp(int pid) => AXUIElementCreateApplication(pid);
    public static int CopyAttribute(nint e, nint attr, out nint value) => AXUIElementCopyAttributeValue(e, attr, out value);

    public static bool ReadBool(nint window, nint attr)
    {
        if (AXUIElementCopyAttributeValue(window, attr, out nint v) != 0 || v == 0) return false;
        return Nf.BooleanGetValue(v) != 0;
    }

    public static bool ReadPoint(nint window, nint attr, out CGPoint pos)
    {
        pos = default;
        if (AXUIElementCopyAttributeValue(window, attr, out nint v) != 0 || v == 0) return false;
        if (!AXValueGetValue(v, kValueCGPoint, out CGP p)) return false;
        pos = new CGPoint(p.x, p.y);
        return true;
    }

    public static bool ReadSize(nint window, nint attr, out CGSize size)
    {
        size = default;
        if (AXUIElementCopyAttributeValue(window, attr, out nint v) != 0 || v == 0) return false;
        if (!AXValueGetValue(v, kValueCGSize, out CGS s)) return false;
        size = new CGSize(s.w, s.h);
        return true;
    }

    public static int SetPoint(nint window, nint attr, CGPoint pos)
    {
        CGP p = new CGP { x = pos.x, y = pos.y };
        return AXUIElementSetAttributeValue(window, attr, AXValueCreate(kValueCGPoint, ref p));
    }

    public static int SetSize(nint window, nint attr, CGSize size)
    {
        CGS s = new CGS { w = size.width, h = size.height };
        return AXUIElementSetAttributeValue(window, attr, AXValueCreate(kValueCGSize, ref s));
    }
}

[StructLayout(LayoutKind.Sequential)]
struct CGPoint { public double x, y; public CGPoint(double x, double y) { this.x = x; this.y = y; } }
[StructLayout(LayoutKind.Sequential)]
struct CGSize { public double width, height; public CGSize(double w, double h) { width = w; height = h; } }
