import Foundation
import SideDeskCore

/// 变量集服务：把多个运行中的变量（显式勾选 + 通配符匹配）按 求和/求平均/最大/最小/计数
/// 聚合成一个新变量（如 qoder.count_all）。对应 C# `Services.VariableSetService`。
///
/// 每个变量集对应一个虚拟 `DataDashboardItem`（VarKey=变量集名），经 `findItem(byVarKey:)`
/// 对外暴露，从而像普通变量一样被信号灯条件、显示引用（RefVarKey）、格式 `{变量名}` 使用。
///
/// 与 C# 的差别（服务不自行 Resolve 容器，跨服务调用一律由组合根以闭包注入，语义不变）：
/// - `runningValuesProvider` ← C# `DataPollingService.GetAllItems()`（VarKey -> 该名下全部运行值）
/// - `manualValueProvider` ← C# `DataPollingService.GetManualValue()`（手动值优先，跳过重算）
/// - `publishUpdate` ← C# `DataPollingService.PublishUpdate()`（广播给引用展示/信号灯）
/// - `onDataUpdated` 的挂接 ← C# `Init` 里的 `DataPollingService.DataUpdated += OnDataUpdated`
/// - `setsProvider` ← C# `WindowConfigManager.VariableSets`（本地定义）
/// - `cloudListProvider` / `teamsProvider` ← C# `PullRemoteAsync` 里 Resolve 的两个后端服务
public final class VariableSetService {

    /// 变量集名（小写键，名大小写不敏感）-> 虚拟数据项（保持实例稳定，引用方持有的对象不失效）
    private var items: [String: DataDashboardItem] = [:]
    /// 云端登记的变量集（其他设备/团队成员创建；同名时本地定义优先）
    private var remoteSets: [VariableSet] = []
    private let lock = NSLock()
    /// 5 秒兜底重算定时器（对应 C# `_timer`），启动时挂上
    private var fallbackTimer: ServiceTimer?
    /// 合并标志：同一轮消息循环内的多次数据更新只重算一次（对应 C# `_recomputePending`）
    private var recomputePending = false

    public var setsProvider: () -> [VariableSet] = { [] }
    public var runningValuesProvider: () -> [String: [String]] = { [:] }
    public var manualValueProvider: (String) -> String? = { _ in nil }
    public var publishUpdate: (String, String) -> Void = { _, _ in }
    /// 云端变量集列表来源（对应 C# 在 `PullRemoteAsync` 里 Resolve 的 `DataVariableService.ListSetsAsync`）；
    /// nil=未登录或后端失败
    public var cloudListProvider: (_ corpId: String?) async -> [VariableSetInfo]? = { _ in nil }
    /// 团队列表来源（对应 C# `TeamService.ListTeamsAsync()`）；nil=失败
    public var teamsProvider: () async -> [Team]? = { nil }

    public init() {}

    // MARK: - 生命周期

    /// 变量集定义变化后重建虚拟项并重算（增删变量集时由 UI 调用）。对应 C# `Rebuild()`。
    public func rebuild() {
        lock.lock()
        let sets = effectiveSetsLocked()
        let live = Set(sets.map { $0.VarKey.lowercased() })
        for k in items.keys where !live.contains(k) { items.removeValue(forKey: k) }
        for set in sets where !set.VarKey.isEmpty {
            let k = set.VarKey.lowercased()
            if items[k] == nil {
                let item = DataDashboardItem()
                item.VarKey = set.VarKey
                item.Label = set.VarKey
                items[k] = item
            }
        }
        lock.unlock()
        recomputeAll()
    }

    /// 数据项更新入口（对应 C# `OnDataUpdated`）：合并高频更新，同一轮消息循环只重算一次。
    /// 由组合根订阅到 `DataPollingService.DataUpdated`（C# 是在 `Init` 里自行 Resolve 后 `+=`）。
    public func onDataUpdated(_ itemId: String, _ value: String) {
        lock.lock()
        if recomputePending { lock.unlock(); return }
        recomputePending = true
        lock.unlock()
        // 没有 UI 线程就直接放弃这一轮（并复位合并标志）——这个分流是语义，不能只发个 no-op
        guard Seam.hasUiThread() else {
            lock.lock(); recomputePending = false; lock.unlock()
            return
        }
        Seam.uiPost { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.recomputePending = false; self.lock.unlock()
            self.recomputeAll()
        }
    }

    /// 挂上 5 秒兜底定时重算（对应 C# `Init` 尾步）：源变量陆续上线、通配符匹配集变化时也能及时更新。
    public func startFallbackTimer() {
        guard fallbackTimer == nil else { return }
        let timer = Seam.timerFactory(5) { [weak self] in self?.recomputeAll() }
        fallbackTimer = timer
        timer.start()
    }

    /// 有效变量集定义：本地 + 云端（同名时本地优先）。须在 `lock` 内调用
    private func effectiveSetsLocked() -> [VariableSet] {
        var sets = setsProvider().filter { !$0.VarKey.isEmpty }
        let localKeys = Set(sets.map { $0.VarKey.lowercased() })
        for r in remoteSets where !r.VarKey.isEmpty && !localKeys.contains(r.VarKey.lowercased()) {
            sets.append(r)
        }
        return sets
    }

    // MARK: - 查询

    /// 按变量名查找变量集虚拟项（供运行变量表兜底）。对应 C# `FindItemByVarKey`。
    public func findItem(byVarKey varKey: String?) -> DataDashboardItem? {
        guard let varKey, !varKey.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return items[varKey.lowercased()]
    }

    /// 全部变量集虚拟项（供变量选择器列出，如信号灯条件选择）
    public func getItems() -> [DataDashboardItem] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.values)
    }

    /// 全部有效变量集定义（本地 + 云端，同名时本地优先）
    public func getSets() -> [VariableSet] {
        lock.lock()
        defer { lock.unlock() }
        return effectiveSetsLocked()
    }

    /// 云端登记的变量集快照（含作用域，供详情窗展示/删除）
    public func getRemoteSets() -> [VariableSet] {
        lock.lock()
        defer { lock.unlock() }
        return remoteSets
    }

    // MARK: - 云端登记

    /// 拉取云端登记的变量集（个人 + 已加入的每个团队），并入聚合计算（同名本地优先）。
    /// 对应 C# `PullRemoteAsync`：应用启动后与变量详情窗打开时调用。
    /// 未登录/后端不可达时各来源回落 nil，本轮按「云端为空」并入——与 C# 一致，
    /// 拿不到就清掉快照，不留上一次成功的旧数据冒充本次结果。
    public func pullRemote() async {
        var fetched: [VariableSet] = []
        // 个人作用域
        if let mine = await cloudListProvider(nil) {
            for s in mine { fetched.append(Self.toSet(s, teamId: nil, teamName: nil)) }
        }
        // 每个已加入团队的作用域
        if let teams = await teamsProvider() {
            for t in teams {
                guard let list = await cloudListProvider(t.Id) else { continue }
                for s in list { fetched.append(Self.toSet(s, teamId: t.Id, teamName: t.Name)) }
            }
        }
        setRemoteSets(fetched)
    }

    /// 后端变量集记录转本地模型（teamName 仅本地展示用）。对应 C# `ToSet`。
    static func toSet(_ s: VariableSetInfo, teamId: String?, teamName: String?) -> VariableSet {
        let set = VariableSet()
        set.VarKey = s.VarKey
        set.Op = s.Op.isEmpty ? "SUM" : s.Op
        set.SourceKeys = s.SourceKeys ?? []
        set.Pattern = s.Pattern ?? ""
        set.TeamId = teamId ?? s.CorpId
        set.TeamName = teamName
        return set
    }

    /// 并入云端登记的变量集（整体替换快照）并重算
    public func setRemoteSets(_ sets: [VariableSet]) {
        lock.lock()
        remoteSets = sets
        lock.unlock()
        rebuild()
    }

    /// 从云端登记列表移除指定变量集（服务端删除成功后由 UI 调用）并重算
    public func removeRemote(_ varKey: String, teamId: String?) {
        let t = teamId ?? ""
        lock.lock()
        remoteSets.removeAll { r in
            r.VarKey.lowercased() == varKey.lowercased()
                && Self.isBlank(r.TeamId) == Self.isBlank(t)
                && (t.isEmpty || r.TeamId == t)
        }
        lock.unlock()
        rebuild()
    }

    private static func isBlank(_ s: String?) -> Bool { s == nil || s!.isEmpty }

    /// 团队成员身份失效（被移除/退出/团队解散）：清除该团队全部云端登记变量集并重算
    public func purgeTeam(_ teamId: String) {
        if teamId.isEmpty { return }
        lock.lock()
        remoteSets.removeAll { $0.TeamId == teamId }
        lock.unlock()
        rebuild()
    }

    // MARK: - 重算

    /// 重算全部变量集：收集运行中变量当前值 → 按各变量集的来源取子集 → 聚合。对应 C# `RecomputeAll()`。
    public func recomputeAll() {
        lock.lock()
        let sets = effectiveSetsLocked()
        let snapshot = items
        lock.unlock()
        if sets.isEmpty { return }

        // 运行中变量：VarKey -> 该名下的全部运行值（变量名允许重复：多个 Profile/账号下的同名变量
        // 各占一个值，聚合时全部参与）
        let running = runningValuesProvider()

        for set in sets {
            guard let item = snapshot[set.VarKey.lowercased()] else { continue }
            // 手动值覆盖：外部已设置值时跳过自动重算，保持手动值直到解除
            if manualValueProvider(set.VarKey) != nil { continue }
            let newValue = Self.computeValue(set, running)
            if item.Value != newValue {
                item.Value = newValue
                // 广播更新：引用展示/格式渲染/信号灯均订阅该事件
                publishUpdate(item.Id, newValue)
            }
        }
    }

    // MARK: - 聚合逻辑（纯函数，与 C# 静态方法一一对应）

    /// 解析变量集的源变量名集合（显式勾选 ∪ 通配匹配；排除变量集自身，避免自引用）
    public static func resolveSourceKeys(_ set: VariableSet, _ candidates: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for k in set.SourceKeys where !k.isEmpty && k.lowercased() != set.VarKey.lowercased() {
            if seen.insert(k.lowercased()).inserted { result.append(k) }
        }
        let trimmedPattern = set.Pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPattern.isEmpty {
            let patterns = splitPatterns(set.Pattern)
            for k in candidates where !k.isEmpty && k.lowercased() != set.VarKey.lowercased() {
                guard patterns.contains(where: { matchesPattern($0, k) }) else { continue }
                if seen.insert(k.lowercased()).inserted { result.append(k) }
            }
        }
        return result
    }

    /// 按聚合逻辑计算变量集的值；无有效数值时返回 "--"。
    /// runningValues：VarKey -> 该名下的全部运行值（同名重复变量的多个值都参与聚合）
    public static func computeValue(_ set: VariableSet, _ runningValues: [String: [String]]) -> String {
        // 变量名大小写不敏感（对应 C# StringComparer.OrdinalIgnoreCase）
        var ci: [String: [String]] = [:]
        for (k, v) in runningValues { ci[k.lowercased()] = v }

        let keys = resolveSourceKeys(set, Array(ci.keys))
        if keys.isEmpty { return "--" }

        var values: [String] = []
        for k in keys { values.append(contentsOf: ci[k.lowercased()] ?? []) }

        if set.Op.uppercased() == "COUNT" {
            // 计数：统计有运行值（非缺失）的个数
            return String(values.filter { !isMissing($0) }.count)
        }

        var nums: [Double] = []
        for v in values {
            if isMissing(v) { continue }
            if let n = parseNumber(v) { nums.append(n) }
        }
        if nums.isEmpty { return "--" }

        let result: Double
        switch set.Op.uppercased() {
        case "AVG": result = nums.reduce(0, +) / Double(nums.count)
        case "MAX": result = nums.max()!
        case "MIN": result = nums.min()!
        default: result = nums.reduce(0, +) // SUM（默认）
        }
        return formatNum(result)
    }

    private static func isMissing(_ v: String?) -> Bool {
        guard let v else { return true }
        return v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || v == "--"
    }

    /// 从值文本提取数字（优先整串解析，支持千分位逗号；否则取首个数字串），失败返回 nil
    public static func parseNumber(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = Double(trimmed.replacingOccurrences(of: ",", with: "")) { return d }
        let pattern = "-?\\d[\\d,]*(\\.\\d+)?"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = trimmed as NSString
        guard let m = re.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        let found = ns.substring(with: m.range)
        return Double(found.replacingOccurrences(of: ",", with: ""))
    }

    /// 拆分通配符串：支持逗号分隔多个模式（含中文逗号），返回去空白后的模式列表
    public static func splitPatterns(_ pattern: String?) -> [String] {
        guard let pattern else { return [] }
        if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return pattern
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 通配符匹配：* 匹配任意字符（含空），? 匹配单个字符；忽略大小写
    public static func matchesPattern(_ pattern: String, _ key: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return false }
        var regex = ""
        for ch in p {
            switch ch {
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        guard let re = try? NSRegularExpression(pattern: "^\(regex)$", options: [.caseInsensitive]) else { return false }
        let ns = key as NSString
        return re.firstMatch(in: key, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// 整数不带小数位，小数最多两位且去尾零（对应 C# `v.ToString("0")` / `v.ToString("0.##")`）
    private static func formatNum(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        let r = (v * 100).rounded() / 100
        if r == r.rounded() { return String(Int64(r)) }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
