import Foundation

/// 动效助手（issue #48，L1，对应 C# `Framework.Motion`）：统一尊重系统「减少动效」偏好。
/// C# 侧返回 `Duration`/`TimeSpan` 供 WPF Storyboard 消费；mac 侧唯一的动画消费点是
/// `NSAnimationContext.duration`（秒），故直接返回秒。
public enum Motion {

    /// 动画时长（秒）：`ReduceMotion` 时返回 0（瞬时完成、不闪烁），否则给定毫秒换算成秒。
    /// 对应 C# `Motion.Fade(int milliseconds)`。
    public static func fade(_ milliseconds: Int) -> Double {
        SystemPreferences.reduceMotion ? 0 : Double(milliseconds) / 1000.0
    }
}
