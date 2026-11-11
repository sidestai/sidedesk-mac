using System;
using System.Collections.Generic;
using AppKit;
using Foundation;

namespace SpikeNspanel;

/// <summary>
/// Keeps every other app's windows clear of the left edge so the 100px side bar always has room
/// (e.g. when a window is zoomed by double-clicking its title bar). Ports the Swift WindowManager
/// strategy to the C# spike: a per-app AXObserver for window moved/resized/created plus a periodic
/// rescan for newly launched apps. Native-fullscreen windows and our own pid are skipped.
/// Everything runs on the AppKit main thread (the AXObserver source is on the main run loop).
/// </summary>
internal sealed class WindowManager
{
    private const double LeftInset = 100;
    private readonly int _ownPid = Environment.ProcessId;

    // A single shared callback; the pid travels in the refcon. Kept in a static field so the
    // function pointer handed to AXObserverCreate is never collected.
    private static readonly AxInterop.AXObserverCallback Callback = OnAxNotify;
    private static WindowManager _current;

    private readonly Dictionary<int, nint> _observers = new();
    private readonly HashSet<int> _seenPids = new();
    private NSTimer _rescanTimer;
    private NSTimer _trustTimer;
    private bool _started;
    private bool _inEnforce;

    public static void Start()
    {
        _current?.Stop();
        _current = new WindowManager();
        _current.StartInternal();
    }

    private void StartInternal()
    {
        if (_started) return;
        if (!AxInterop.IsTrusted())
        {
            Console.WriteLine("[wm] not trusted yet; prompting and polling for Accessibility grant");
            AxInterop.PromptTrust();
            _trustTimer = NSTimer.CreateScheduledTimer(TimeSpan.FromSeconds(1.5), t =>
            {
                if (!AxInterop.IsTrusted()) return;
                _trustTimer?.Invalidate();
                _trustTimer = null;
                Begin();
            });
            return;
        }
        Begin();
    }

    private void Begin()
    {
        _started = true;
        var apps = NSWorkspace.SharedWorkspace.RunningApplications;
        Console.WriteLine($"[wm] begin trusted apps={apps.Length}");
        foreach (var app in apps) AddApp(app);

        _rescanTimer = NSTimer.CreateScheduledTimer(TimeSpan.FromSeconds(3.0), t => Rescan());
    }

    public void Stop()
    {
        _trustTimer?.Invalidate();
        _rescanTimer?.Invalidate();
        foreach (var obs in _observers.Values) AxInterop.ObserverDetachFromMainLoop(obs);
        _observers.Clear();
        _seenPids.Clear();
        _started = false;
    }

    private void Rescan()
    {
        if (!AxInterop.IsTrusted()) return;
        var live = new HashSet<int>();
        foreach (var app in NSWorkspace.SharedWorkspace.RunningApplications)
        {
            live.Add(app.ProcessIdentifier);
            if (!_seenPids.Contains(app.ProcessIdentifier)) AddApp(app);
        }
        // Drop observers for apps that terminated.
        List<int> gone = null;
        foreach (int pid in _observers.Keys)
            if (!live.Contains(pid)) (gone ??= new List<int>()).Add(pid);
        if (gone != null)
            foreach (int pid in gone)
            {
                AxInterop.ObserverDetachFromMainLoop(_observers[pid]);
                _observers.Remove(pid);
                _seenPids.Remove(pid);
            }
    }

    private void AddApp(NSRunningApplication app)
    {
        int pid = app.ProcessIdentifier;
        if (pid == _ownPid) return;
        if (app.ActivationPolicy == NSApplicationActivationPolicy.Prohibited) return;
        if (_observers.ContainsKey(pid)) return;
        _seenPids.Add(pid);

        nint axApp = AxInterop.CreateApp(pid);
        nint observer = AxInterop.ObserverCreate(pid, Callback);
        if (observer == 0) return;

        nint refcon = (nint)(long)pid;
        int r1 = AxInterop.ObserverAdd(observer, axApp, AxInterop.NotifyWindowMoved, refcon);
        int r2 = AxInterop.ObserverAdd(observer, axApp, AxInterop.NotifyWindowResized, refcon);
        int r3 = AxInterop.ObserverAdd(observer, axApp, AxInterop.NotifyWindowCreated, refcon);
        AxInterop.ObserverAttachToMainLoop(observer);
        _observers[pid] = observer;
        if (Environment.GetEnvironmentVariable("WM_VERBOSE") == "1") Console.WriteLine($"[wm] add pid={pid} moved={r1} resized={r2} created={r3}");
        EnforceApp(pid);
    }

    private static void OnAxNotify(nint axObserver, nint axUIElement, nint notificationName, nint refcon)
    {
        try
        {
            if (Environment.GetEnvironmentVariable("WM_VERBOSE") == "1")
                Console.WriteLine($"[wm] notify pid={(int)refcon.ToInt64()}");
            _current?.EnforceApp((int)refcon.ToInt64());
        }
        catch (Exception e) { Console.WriteLine("[wm] callback EX: " + e.Message); }
    }

    private void EnforceApp(int pid)
    {
        if (_inEnforce) return; // our own sets re-fire notifications; one pass suffices
        _inEnforce = true;
        try
        {
            nint axApp = AxInterop.CreateApp(pid);
            nint windows = AxInterop.EnumerateWindows(axApp);
            if (windows == 0) return;
            int count = AxInterop.WindowCount(windows);
            double screenW = (double)NSScreen.MainScreen.Frame.Width;
            for (int i = 0; i < count; i++)
                Adjust(AxInterop.WindowAt(windows, i), screenW);
        }
        catch (Exception e)
        {
            Console.WriteLine($"[wm] enforce pid={pid} EX: {e.Message}");
        }
        finally { _inEnforce = false; }
    }

    private static void Adjust(nint window, double screenW)
    {
        if (window == 0 || AxInterop.IsFullscreen(window)) return;
        if (!AxInterop.ReadPos(window, out double x, out double y)) return;
        if (!AxInterop.ReadSize(window, out double w, out double h)) return;

        // Only reserve the left strip; leave the right edge where the window put it.
        if (x >= LeftInset - 0.5) return; // already clear -> also breaks the notify loop

        double newLeft = Math.Max(x, LeftInset);
        double newRight = Math.Max(x + w, screenW);
        double newWidth = newRight - newLeft;
        if (newWidth < 120) newWidth = Math.Max(120, w);

        AxInterop.SetPos(window, newLeft, y);
        AxInterop.SetSize(window, newWidth, h);
        Console.WriteLine($"[wm] clamp x:{x:0}->{newLeft:0} w:{w:0}->{newWidth:0}");
    }
}
