import Foundation
import SideDeskCore

/// 数据变量「手动值」层。对应 C# `DataPollingService` 中 `_manualValues` 一族
/// （`EnsureManualLoaded` / `SetVariableValue` / `ClearVariableValue` / `GetManualValue`）。
///
/// 语义：外部程序（本地 HTTP 接口）或后端推送设置的变量值优先于轮询与变量集聚合结果，
/// 设置后该变量不再被自动取值覆盖，直到 `clear` 解除。值按数据作用域（`local` / `u:{密文}`）
/// 隔离并落库 `local_data_variable`，防止切换登录账号后串号。
///
/// 与 C# 的差别：本类只做「手动值存储」这一件平台无关的事；把值应用到同名运行中变量
/// （`UpdateItemValue` / `FindItemByVarKey`）依赖 `DataPollingService`，留待该服务移植时接入。
public final class ManualVariableStore {

    /// 变量名大小写不敏感（对应 C# `StringComparer.OrdinalIgnoreCase`），值保留原始大小写
    private var entries: [String: (key: String, value: String)] = [:]
    private var loadedScope: String?

    /// 作用域提供者；默认取本地库当前作用域。测试可注入固定作用域。
    public var scopeProvider: () -> String = { LocalDbService.currentScope() }

    /// 晋升到登录作用域的未归属（local）变量回调：C# 在此把离线期间产生的变量补传服务器
    /// （`HttpServerService.ForwardVariableToBackendAsync`，A8 接入）。默认 no-op。
    public var onAdoptedVariables: ([(varKey: String, varValue: String, corpId: String?)]) -> Void = { _ in }

    /// 旧版存储：手动值曾整体存为一个 JSON blob（varKey -> value）放在 local_app_state。
    private static let legacyStoreKey = "manual_var_values"

    public init() {}

    /// 作用域变化（登录/登出/切号）后重新按当前作用域加载
    public func reload() { loadedScope = nil }

    private func ensureLoaded() {
        let scope = scopeProvider()
        if loadedScope == scope { return }
        loadedScope = scope
        entries.removeAll()

        // 未归属数据晋升：登录用户首次加载时，把未登录期间产生的 local 作用域变量归入本人作用域
        //（离线数据"跟人走"；同名 key 离线值更新故覆盖已有；加载完成后交由 onAdoptedVariables 转发服务器）
        var adopted: [(varKey: String, varValue: String, corpId: String?)] = []
        if scope != "local" {
            adopted = LocalDbService.loadDataVariables("local")
            for row in adopted where !row.varKey.trimmingCharacters(in: .whitespaces).isEmpty {
                LocalDbService.upsertDataVariable(scope, row.varKey, row.varValue, row.corpId)
                LocalDbService.deleteDataVariable("local", row.varKey)
            }
        }

        for row in LocalDbService.loadDataVariables(scope) where !row.varKey.trimmingCharacters(in: .whitespaces).isEmpty {
            entries[Self.norm(row.varKey)] = (row.varKey, row.varValue)
        }
        migrateLegacyBlob(scope)
        if !adopted.isEmpty { onAdoptedVariables(adopted) }
    }

    /// 旧 blob KV 逐条迁入新表（仅当该作用域尚无手动值），迁完删除 blob
    private func migrateLegacyBlob(_ scope: String) {
        guard entries.isEmpty,
              let json = LocalDbService.loadBusinessData(Self.legacyStoreKey),
              let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        for (k, v) in obj {
            let key = k.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = "\(v)"
            entries[Self.norm(key)] = (key, value)
            LocalDbService.upsertDataVariable(scope, key, value, nil)
        }
        LocalDbService.deleteBusinessData(Self.legacyStoreKey)
    }

    private static func norm(_ key: String) -> String { key.lowercased() }

    /// 读取手动值；无手动覆盖返回 nil（对应 C# `GetManualValue`）
    public func get(_ varKey: String) -> String? {
        let key = varKey.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return nil }
        ensureLoaded()
        return entries[Self.norm(key)]?.value
    }

    /// 是否已有该变量的存储行（含空串值；区别于 `get` 的「无覆盖」语义）
    public func hasValue(_ varKey: String) -> Bool {
        get(varKey) != nil
    }

    /// 设置手动值并落库。`corpId`（团队密文，可空）随行存入。空变量名忽略（对应 C# `SetVariableValue`）
    public func set(_ varKey: String, _ value: String, corpId: String? = nil) {
        let key = varKey.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return }
        ensureLoaded()
        entries[Self.norm(key)] = (key, value)
        LocalDbService.upsertDataVariable(scopeProvider(), key, value,
                                          corpId?.trimmingCharacters(in: .whitespaces).isEmpty == true ? nil : corpId)
    }

    /// 解除手动值：变量恢复轮询/聚合自动取值。返回是否确实存在手动值（对应 C# `ClearVariableValue`）
    @discardableResult
    public func clear(_ varKey: String) -> Bool {
        let key = varKey.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return false }
        ensureLoaded()
        guard let entry = entries.removeValue(forKey: Self.norm(key)) else { return false }
        LocalDbService.deleteDataVariable(scopeProvider(), entry.key)
        return true
    }

    /// 当前作用域全部手动值快照（供变量列表展示 / 本地 HTTP 接口）
    public func snapshot() -> [(varKey: String, value: String)] {
        ensureLoaded()
        return entries.values.map { ($0.key, $0.value) }.sorted { $0.varKey < $1.varKey }
    }
}
