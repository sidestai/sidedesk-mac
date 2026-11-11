using System;
using AppKit;
using CoreGraphics;
using Foundation;
using NFloat = System.Runtime.InteropServices.NFloat;

namespace SpikeNspanel;

// A borderless, non-activating panel pinned above full-screen spaces.
// This is the one thing a plain (Avalonia-owned) NSWindow cannot do:
// NSWindowStyle.NonactivatingPanel is only valid on NSPanel, and CanBecomeKeyWindow
// is a subclass override, not a settable property.
public sealed class NonActivatingPanel : NSPanel
{
    public NonActivatingPanel(CGRect frame)
        : base(frame,
               NSWindowStyle.Borderless | NSWindowStyle.NonactivatingPanel,
               NSBackingStore.Buffered, false)
    {
        HasShadow = false;
        Level = NSWindowLevel.Status;
        CollectionBehavior =
            NSWindowCollectionBehavior.CanJoinAllSpaces |
            NSWindowCollectionBehavior.FullScreenAuxiliary;
        HidesOnDeactivate = false;
        BecomesKeyOnlyIfNeeded = true;
        BackgroundColor = NSColor.Clear;
        Title = "SidestMacBar";
    }

    // Never become key: clicking the bar must not take keyboard focus from the active app.
    public override bool CanBecomeKeyWindow => false;
    public override bool CanBecomeMainWindow => false;
}

public static class PanelHost
{
    // Put a rendered NSView (the sideui card) into the panel's content view, filling it.
    public static void AttachContent(NSPanel panel, NSView content)
    {
        var bounds = panel.ContentView?.Bounds ?? new CGRect(0, 0, panel.Frame.Width, panel.Frame.Height);
        var container = new NSView(bounds);
        container.AutoresizingMask = NSViewResizingMask.WidthSizable | NSViewResizingMask.HeightSizable;
        panel.ContentView = container;

        content.Frame = container.Bounds;
        content.AutoresizingMask = NSViewResizingMask.WidthSizable | NSViewResizingMask.HeightSizable;
        container.AddSubview(content);
        container.NeedsDisplay = true;
    }
}
