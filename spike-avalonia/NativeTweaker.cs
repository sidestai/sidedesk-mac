using System;
using System.IO;
using System.Runtime.InteropServices;
using Avalonia.Controls;
using Avalonia.Platform;

namespace spike_avalonia;

// Spike B2: reach the native NSWindow behind an Avalonia window and set
// level + collectionBehavior via the Objective-C runtime (objc_msgSend).
// Defensive: probes selectors and logs incrementally to disk so a native
// crash still leaves a trace of how far we got.
public static class NativeTweaker
{
    const string ObjC = "/usr/lib/libobjc.dylib";
    const string Path = "/tmp/avtweak.txt";

    [DllImport(ObjC)] static extern nint sel_registerName(string name);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern nint MsgSendObj(nint recv, nint sel);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern long MsgSendGetLong(nint recv, nint sel);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern void MsgSendSetLong(nint recv, nint sel, long v);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern void MsgSendSetULong(nint recv, nint sel, ulong v);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern byte MsgSendResponds(nint recv, nint sel, nint aSelector);

    const long NSStatusWindowLevel = 25;                    // == kCGStatusWindowLevel
    const ulong JoinAllSpacesFullScreenAux = (1UL << 1) | (1UL << 8);

    static readonly nint SelResp = sel_registerName("respondsToSelector:");

    public static void Apply(Window w)
    {
        File.WriteAllText(Path, "");
        try
        {
            IPlatformHandle? ph = w.TryGetPlatformHandle();
            if (ph is null) { Log("TryGetPlatformHandle null"); return; }
            nint h = ph.Handle;
            Log($"handle=0x{h:x}");

            // The handle may be an NSWindow or an NSView; find the NSWindow.
            nint window;
            if (Responds(h, "level"))
            {
                window = h;
                Log("handle is NSWindow");
            }
            else if (Responds(h, "window"))
            {
                window = MsgSendObj(h, sel_registerName("window"));
                Log($"NSView -> window=0x{window:x}");
            }
            else { Log("handle is neither NSWindow nor NSView"); return; }

            if (window == 0 || !Responds(window, "setLevel:")) { Log("bad window / no setLevel:"); return; }

            long before = MsgSendGetLong(window, sel_registerName("level"));
            MsgSendSetLong(window, sel_registerName("setLevel:"), NSStatusWindowLevel);
            long after = MsgSendGetLong(window, sel_registerName("level"));
            Log($"level: {before} -> {after} (want {NSStatusWindowLevel})");

            if (Responds(window, "setCollectionBehavior:"))
            {
                MsgSendSetULong(window, sel_registerName("setCollectionBehavior:"), JoinAllSpacesFullScreenAux);
                ulong cb = (ulong)MsgSendGetLong(window, sel_registerName("collectionBehavior"));
                Log($"collectionBehavior now 0x{cb:x} (want 0x{JoinAllSpacesFullScreenAux:x})");
            }
            else Log("no setCollectionBehavior:");
        }
        catch (Exception ex)
        {
            Log("EXCEPTION: " + ex.Message);
        }
    }

    static bool Responds(nint recv, string selector) =>
        MsgSendResponds(recv, SelResp, sel_registerName(selector)) != 0;

    static void Log(string s) => File.AppendAllText(Path, s + "\n");
}
