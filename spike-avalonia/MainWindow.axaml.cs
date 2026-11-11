using Avalonia;
using Avalonia.Controls;
using Avalonia.Platform;

namespace spike_avalonia;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Opened += (_, _) =>
        {
            PlaceOnLeftEdge();
            NativeTweaker.Apply(this);
        };
    }

    private void PlaceOnLeftEdge()
    {
        var screen = Screens?.Primary;
        if (screen is null) return;

        var wa = screen.WorkingArea;          // device pixels, excludes menu bar / dock
        var scale = RenderScaling > 0 ? RenderScaling : 1.0;

        // Position is in device pixels; Width/Height are in DIP.
        Position = new PixelPoint(wa.X, wa.Y);
        Width = 100;
        Height = wa.Height / scale;
    }
}
