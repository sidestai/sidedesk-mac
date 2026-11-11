using System;
using System.IO;
using System.Reflection;
using System.Text;
using Avalonia.Controls;

namespace spike_avalonia;

// Reflection probe: discover how to reach the native window handle on this
// Avalonia version. Writes findings to /tmp/avapi.txt.
public static class NativeProbe
{
    public static void Write(Window w)
    {
        var sb = new StringBuilder();
        var flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance;

        for (var t = w.GetType(); t != null && t != typeof(object); t = t.BaseType)
        {
            foreach (var m in t.GetMethods(flags))
            {
                var n = m.Name;
                if (n.Contains("Feature") || n.Contains("Handle") || n.Contains("Platform"))
                    sb.AppendLine($"[M] {t.Name}.{n}({Args(m)}) : {m.ReturnType.Name}");
            }
            foreach (var p in t.GetProperties(flags))
            {
                var n = p.Name;
                if (n.Contains("Handle") || n.Contains("Platform") || n.Contains("Native"))
                    sb.AppendLine($"[P] {t.Name}.{n} : {p.PropertyType.Name}");
            }
            if (t.Name == "Control") break;
        }

        File.WriteAllText("/tmp/avapi.txt", sb.ToString());
    }

    private static string Args(MethodInfo m)
    {
        var ps = m.GetParameters();
        return ps.Length == 0 ? "" : string.Join(", ", Array.ConvertAll(ps, p => $"{p.ParameterType.Name} {p.Name}"));
    }
}
