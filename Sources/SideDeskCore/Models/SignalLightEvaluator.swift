import Foundation

/// 信号灯三态条件求值与状态机（对应 C# `UI/Yaml/Nodes/SignalLightBoard.cs` 的条件求值段，逐式对齐）。
///
/// 纯函数、不依赖任何服务：变量值经 `ValueProvider` 注入（宿主接 `DataPollingService.findItem(byVarKey:)?.Value`），
/// 时钟经 `nowMs` 注入，便于单测。状态机语义与 C# 一致：**闪烁 > 关 > 开 > 手动 IsOn**。
public enum SignalLightEvaluator {

    /// 按 VarKey 取当前变量值；nil = 变量不存在（未被轮询/未定义）。
    public typealias ValueProvider = (String) -> String?

    /// 单盏灯的求值结果：`lit` 是否点亮、`blinking` 是否处于闪烁态（闪烁命中时 `lit` 为当前相位）。
    public struct State: Equatable {
        public var lit: Bool
        public var blinking: Bool
        public init(lit: Bool, blinking: Bool) {
            self.lit = lit
            self.blinking = blinking
        }
    }

    /// 状态机单灯分支（对应 `RefreshVisuals` 的 foreach 体）：闪烁条件命中 → 相位亮灭；
    /// 否则关条件命中 → 灭；否则开条件命中 → 亮；都不命中 → 手动 `IsOn`。
    public static func state(for light: SignalLightItem, value: ValueProvider, nowMs: Int64) -> State {
        if condsMet(light.BlinkConditions, mode: light.BlinkConditionMode, value: value) {
            return State(lit: blinkPhaseOn(light, nowMs: nowMs), blinking: true)
        }
        if condsMet(light.OffConditions, mode: light.OffConditionMode, value: value) {
            return State(lit: false, blinking: false)
        }
        if condsMet(light.OnConditions, mode: light.OnConditionMode, value: value) {
            return State(lit: true, blinking: false)
        }
        return State(lit: light.IsOn, blinking: false)
    }

    /// 闪烁相位（对应 `BlinkPhaseOn`）：按系统时钟整除半个周期取偶为亮，间隔下限 0.1s。
    public static func blinkPhaseOn(_ light: SignalLightItem, nowMs: Int64) -> Bool {
        let intervalMs = Int64((max(0.1, light.BlinkIntervalSeconds) * 1000).rounded())
        guard intervalMs > 0 else { return true }
        return (nowMs / intervalMs) % 2 == 0
    }

    /// 条件组求值（对应 `CondsMet`）：空组 = false；AND 需全满足（任一不满足即 false）、
    /// OR 任一满足即 true；遍历完未提前返回时 AND=true / OR=false。
    public static func condsMet(_ conds: [SignalLightCondition]?, mode: String, value: ValueProvider) -> Bool {
        guard let conds, !conds.isEmpty else { return false }
        let and = mode.caseInsensitiveCompare("AND") == .orderedSame
        for c in conds {
            let met = condMet(c, value: value)
            if and && !met { return false }
            if !and && met { return true }
        }
        return and
    }

    /// 单条件求值（对应 `CondMet`）：VarKey 空 = false；MISSING 判变量缺失（不存在/空/"--"）；
    /// 其余操作符在值缺失时 = false；GT/LT 数值可解析则比数值、否则按字节序比字符串；EQ 忽略大小写相等。
    public static func condMet(_ c: SignalLightCondition, value: ValueProvider) -> Bool {
        guard !c.VarKey.isEmpty else { return false }
        let raw = value(c.VarKey)
        let missing = raw == nil || raw!.isEmpty || raw! == "--"
        if c.Op.caseInsensitiveCompare("MISSING") == .orderedSame { return missing }
        guard let rawValue = raw, !rawValue.isEmpty, rawValue != "--" else { return false }
        let val = rawValue.trimmingCharacters(in: .whitespaces)
        let expect = c.Value.trimmingCharacters(in: .whitespaces)
        if c.Op.caseInsensitiveCompare("GT") == .orderedSame || c.Op.caseInsensitiveCompare("LT") == .orderedSame {
            let cmp: Int
            if let a = extractNumber(val), let b = extractNumber(expect) {
                cmp = a < b ? -1 : (a > b ? 1 : 0)
            } else {
                cmp = ordinalCompare(val, expect)
            }
            return c.Op.caseInsensitiveCompare("GT") == .orderedSame ? cmp > 0 : cmp < 0
        }
        return val.caseInsensitiveCompare(expect) == .orderedSame
    }

    /// 数值提取（对应 `ExtractNumber`）：整体可解析优先，否则取首个 `-?数字(.数字)?` 片段。
    public static func extractNumber(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let d = Double(t) { return d }
        guard let regex = try? NSRegularExpression(pattern: #"-?\d+(\.\d+)?"#),
              let m = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let range = Range(m.range, in: t),
              let v = Double(String(t[range])) else { return nil }
        return v
    }

    /// 字节序比较的符号（对应 C# `string.CompareOrdinal` 的 <0/0/>0）。
    static func ordinalCompare(_ a: String, _ b: String) -> Int {
        let ua = Array(a.utf8); let ub = Array(b.utf8)
        for i in 0..<min(ua.count, ub.count) {
            if ua[i] != ub[i] { return ua[i] < ub[i] ? -1 : 1 }
        }
        return ua.count == ub.count ? 0 : (ua.count < ub.count ? -1 : 1)
    }

    // MARK: - 熄灭压暗（对应 `ApplyLightVisual` 的 else 分支）

    /// 熄灭色（0-255 分量入、0-255 分量出）：去白分量（min 通道归零）得纯色相，再压暗到最大通道 ≈130；
    /// 纯灰/纯黑（去白后 max=0）时整体 ×0.4。明显暗于点亮态但原色可辨。
    public static func dimmedRGB(r: Int, g: Int, b: Int) -> (r: Int, g: Int, b: Int) {
        let minC = min(r, min(g, b))
        let rr = r - minC, gg = g - minC, bb = b - minC
        let maxC = max(rr, max(gg, bb))
        if maxC <= 0 {
            return (clampByte(r * 4 / 10), clampByte(g * 4 / 10), clampByte(b * 4 / 10))
        }
        return (clampByte(Int((Double(rr) * (130.0 / Double(maxC))).rounded())),
                clampByte(Int((Double(gg) * (130.0 / Double(maxC))).rounded())),
                clampByte(Int((Double(bb) * (130.0 / Double(maxC))).rounded())))
    }

    private static func clampByte(_ v: Int) -> Int { min(255, max(0, v)) }
}
