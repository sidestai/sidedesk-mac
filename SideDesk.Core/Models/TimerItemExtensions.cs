using System;

namespace SideDesk.Models;

/// <summary>
/// TimerItem 行为扩展（#340 契约统一）：计时结束累计到当日记录，原 NativeModePanel 与 QuickGroupUIService 各有一份，这里唯一。
/// </summary>
public static class TimerItemExtensions
{
    /// <summary>计时结束累计到当日记录</summary>
    public static void AccumulateToDailyRecord(this TimerItem timer)
    {
        var today = DateTime.Now.ToString("yyyy-MM-dd");
        var secondsToAdd = (int)timer.GetElapsed().TotalSeconds;
        if (timer.DailyRecords.ContainsKey(today))
            timer.DailyRecords[today] += secondsToAdd;
        else
            timer.DailyRecords[today] = secondsToAdd;
    }
}
