using System;
using System.Collections.Generic;
using AppKit;
using CoreGraphics;
using Foundation;
using SideDesk.Models;
using SideDesk.UI.Yaml;
using SpikeNspanel.SideUi;
using NFloat = System.Runtime.InteropServices.NFloat;

namespace SpikeNspanel;

public static class Program
{
    public static void Main(string[] args)
    {
        // Standard .NET-for-macOS entry: establishes AppKit's main-thread affinity,
        // so AppKit calls inside DidFinishLaunching do not throw AppKitThreadAccessException.
        NSApplication.Init();
        NSApplication.SharedApplication.Delegate = new AppDelegate();
        NSApplication.Main(args);
    }
}

public sealed class AppDelegate : NSApplicationDelegate
{
    private const double BarWidth = 100;
    private NonActivatingPanel _panel = null!;
    private StickyNoteSourceMac _source = null!;
    private IUiActionHost _actions = null!;

    public override void DidFinishLaunching(NSNotification notification)
    {
        try
        {
            Console.WriteLine("[app] DidFinishLaunching on main thread = " + NSThread.IsMain);
            NSApplication.SharedApplication.ActivationPolicy = NSApplicationActivationPolicy.Accessory;

            var screen = NSScreen.MainScreen;
            var frame = screen.Frame;
            var vf = screen.VisibleFrame;
            var barHeight = (double)(vf.Y + vf.Height) - (double)frame.Y;
            var rect = new CGRect(frame.X, frame.Y, (NFloat)BarWidth, (NFloat)barHeight);

            _panel = new NonActivatingPanel(rect);
            // Give the bar a visible panel background (token, not a literal) so the card shows against the desktop.
            _panel.BackgroundColor = UiTokensMac.Brush(UiCardHostMac.Registries, "bg.panel");

            _source = new StickyNoteSourceMac(SampleNotes(), editMode: true);
            _actions = new DelegateUiActionHost(HandleAction);

            Render();
            _panel.OrderFrontRegardless();
            Console.WriteLine($"[app] panel shown x={rect.X} y={rect.Y} h={rect.Height}");

            WindowManager.Start();
            Console.WriteLine("[app] window manager started (left inset 100)");
        }
        catch (Exception e)
        {
            Console.WriteLine("[app] EXCEPTION: " + e);
        }
        finally
        {
            Console.Out.Flush();
        }
    }

    // Render (or re-render) the sticky-notes card into the panel.
    private void Render()
    {
        var view = UiCardHostMac.Build("sticky-notes", _source, _actions, out var reason);
        if (view == null)
        {
            Console.WriteLine("[app] card build FAILED: " + reason);
            return;
        }
        PanelHost.AttachContent(_panel, view);
        Console.WriteLine("[app] sticky-notes card rendered into panel");
    }

    // Host-side wiring by position (same contract as Windows: Rows[i] <-> notes[i]).
    private bool HandleAction(string action, string? value)
    {
        if (!int.TryParse(value, out var index)) return false;
        switch (action)
        {
            case "sticky.open":
                Console.WriteLine($"[app] sticky.open #{index} (desktop note window not ported yet)");
                return true;
            case "sticky.delete":
            {
                var ordered = StickyNoteSourceMac.Ordered(_source.Notes);
                if (index < 0 || index >= ordered.Count) return false;
                var note = ordered[index];
                _source.Notes.Remove(note);
                Console.WriteLine($"[app] sticky.delete #{index} -> removed {note.Id}; {_source.Notes.Count} left");
                Render();   // collection change => full rebuild (matches Windows host behavior)
                return true;
            }
            default:
                return false;
        }
    }

    // Sample data so the milestone-1 render is visible. Exercises ordering (UpdatedAt),
    // emoji preview, and >200-char tooltip truncation.
    private static List<StickyNote> SampleNotes()
    {
        var now = DateTime.Now;
        return new List<StickyNote>
        {
            Note("买菜 🥬 牛奶 鸡蛋", now.AddMinutes(-1)),
            Note("重构 sideui 渲染后端：节点 → NSView", now.AddMinutes(-30)),
            Note(string.Concat(System.Linq.Enumerable.Repeat("长内容测试 ", 40)), now.AddHours(-2)),   // >200 chars => tooltip truncates
            Note("(空)", now.AddHours(-5)),
        };
    }

    private static StickyNote Note(string content, DateTime updatedAt) =>
        new() { Content = content, UpdatedAt = updatedAt, Pinned = false };
}
