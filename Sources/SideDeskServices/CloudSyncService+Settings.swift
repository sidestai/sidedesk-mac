import Foundation
import SideDeskCore

/// 云同步：设置项白名单同步（敏感字段加密）/ 云端恢复设置 / 资源排序上报。
/// 对应 C# `CloudSyncService.Local.cs` 的设置同步与资源排序段（本地备份段另见 +Backup）。
extension CloudSyncService {

    /// 需要同步的设置项白名单（key = 上传标识, category, isSensitive）。对应 C# `SettingWhitelist`。
    static let settingWhitelist: [(key: String, category: String, sensitive: Bool)] = [
        // general
        ("general.theme_mode", "general", false),
        ("general.background_opacity", "general", false),
        ("general.show_notification", "general", false),
        ("general.enable_auto_update", "general", false),
        ("general.enable_mcp_server", "general", false),
        ("general.data_connection", "general", false),
        // cloud_drive
        ("baidu_pan.access_token", "cloud_drive", true),
        ("baidu_pan.refresh_token", "cloud_drive", true),
        ("baidu_pan.token_expiry", "cloud_drive", false),
    ]

    /// 从 Settings 提取指定 key 的上传值。对应 C# `GetSettingValue`。
    /// Bool 按 C# `ToString()` 口径输出 "True"/"False"（首字母大写）——
    /// 应用端按 `== "True"` 精确匹配，跨端线格式必须一致。
    static func getSettingValue(_ s: Settings, _ key: String) -> String? {
        switch key {
        case "general.theme_mode": return s.ThemeMode
        case "general.background_opacity": return numberText(s.BackgroundOpacity)
        case "general.show_notification": return s.ShowNotificationStrip ? "True" : "False"
        case "general.enable_auto_update": return s.EnableAutoUpdate ? "True" : "False"
        case "general.enable_mcp_server": return s.EnableMcpServer ? "True" : "False"
        case "general.data_connection": return s.DataConnectionMode
        case "baidu_pan.access_token": return s.BaiduPanAccessToken
        case "baidu_pan.refresh_token": return s.BaiduPanRefreshToken
        case "baidu_pan.token_expiry": return s.BaiduPanTokenExpiry.map { isoO($0) }
        default: return nil
        }
    }

    /// 将云端值写回本地 Settings。对应 C# `ApplySettingValue`。
    static func applySettingValue(_ s: Settings, _ key: String, _ value: String?) {
        switch key {
        case "general.theme_mode": s.ThemeMode = value ?? "Dark"
        case "general.background_opacity":
            if let op = value.flatMap(Double.init) { s.BackgroundOpacity = op }
        case "general.show_notification": s.ShowNotificationStrip = value == "True"
        case "general.enable_auto_update": s.EnableAutoUpdate = value == "True"
        case "general.enable_mcp_server": s.EnableMcpServer = value == "True"
        case "general.data_connection": s.DataConnectionMode = value ?? "extension"
        case "baidu_pan.access_token": s.BaiduPanAccessToken = value
        case "baidu_pan.refresh_token": s.BaiduPanRefreshToken = value
        case "baidu_pan.token_expiry":
            // C# DateTime.TryParse 宽口径：带/不带小数秒的 ISO8601 都认（复用共享解码策略）
            s.BaiduPanTokenExpiry = value.flatMap { decode(.string($0), Date.self) }
        default: break
        }
    }

    /// C# double.ToString() 不带无意义小数尾（50 → "50"）；Swift String(50.0) 会带 ".0"。
    private static func numberText(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(v)
    }

    /// 当前加密密钥（启用加密同步且本地有保护密钥时）。对应 C# `GetEncryptionKey`。
    static func getEncryptionKey(_ s: Settings) -> Data? {
        guard s.SyncEncryptEnabled, let stored = s.SyncDerivedKey, !stored.isEmpty else { return nil }
        return SyncEncryption.unprotectKeyFromLocal(stored)
    }

    /// 将本地设置项同步到服务器；敏感字段在启用加密同步时加密后上传。
    /// 对应 C# `SyncSettingsAsync`（结构上传成功后追加调用）。
    func syncSettingsUpload(_ settings: Settings) async {
        let encKey = Self.getEncryptionKey(settings)
        var items: [JSONValue] = []
        for entry in Self.settingWhitelist {
            guard let raw = Self.getSettingValue(settings, entry.key) else { continue }
            var upload = raw
            var isEncrypted = 0
            if entry.sensitive, let key = encKey {
                // 加密失败不上传明文（C# 此处异常会中止整次同步；Swift 逐项跳过更稳）
                guard let enc = SyncEncryption.encrypt(raw, key: key) else { continue }
                upload = enc
                isEncrypted = 1
            }
            items.append(.object([
                "key": .string(entry.key),
                "value": .string(upload),
                "isEncrypted": .int(isEncrypted),
                "category": .string(entry.category),
            ]))
        }
        if items.isEmpty { return }

        RuntimeLog.debug("[CloudSync] settings sync POST \(Self.settingSyncEndpoint)")
        let r = await api.send("POST", Self.settingSyncEndpoint, body: .object(["settings": .array(items)]))
        if r.ok {
            settings.LastSettingsSyncTime = Date()
            settings.Save()
            RuntimeLog.debug("[CloudSync] settings sync succeeded")
        } else {
            RuntimeLog.debug("[CloudSync] settings sync failed: \(r.transportError ?? r.msg)")
        }
    }

    /// 从服务器拉取设置并写回本地（「恢复设置」）；加密字段自动解密。
    /// 返回恢复的设置项数，-1 表示失败。对应 C# `RestoreSettingsAsync`。
    @discardableResult
    public func restoreSettings() async -> Int {
        let settings = Seam.settings
        guard let token = settings.AccountToken, !token.isEmpty else { return -1 }
        let r = await api.send("GET", Self.settingListEndpoint)
        guard r.ok, case .array(let entries)? = r.data else { return -1 }

        let encKey = Self.getEncryptionKey(settings)
        var count = 0
        for entry in entries {
            guard let o = entry.objectValue,
                  let key = o["key"]?.stringValue, !key.isEmpty,
                  var value = o["value"]?.stringValue else { continue }
            let isEncrypted = Int(o["isEncrypted"]?.doubleValue ?? 0)
            if isEncrypted == 1, let k = encKey, SyncEncryption.isEncrypted(value) {
                // 解密失败跳过该项（密钥不符/密文损坏），不中断其余项恢复
                guard let plain = SyncEncryption.decrypt(value, key: k) else { continue }
                value = plain
            }
            Self.applySettingValue(settings, key, value)
            count += 1
        }
        if count > 0 { settings.Save() }
        return count
    }

    /// 推送资源排序到服务端。resourceType: "bar"/"item"/"row"；serverIds 按当前顺序；
    /// 团队模块行调序传 corpId（团队加密串，user_id 置 0，全团队共享顺序）。
    /// 对应 C# `PushResourcePosAsync`（发后不管，失败只记日志）。
    public func pushResourcePos(resourceType: String, serverIds: [String], corpId: String? = nil) async {
        let settings = Seam.settings
        guard let token = settings.AccountToken, !token.isEmpty, !serverIds.isEmpty else { return }
        // C# 先 Where 过滤空 id 再 Select 带下标——posInx 是过滤后的序号
        let ids = serverIds.filter { !$0.isEmpty }
        if ids.isEmpty { return }
        let items: [JSONValue] = ids.enumerated().map { idx, id in
            .object(["resourceServerId": .string(id), "posInx": .int(idx)])
        }
        var payload: [String: JSONValue] = ["resourceType": .string(resourceType), "items": .array(items)]
        if let corpId { payload["corpId"] = .string(corpId) }
        RuntimeLog.debug("[CloudSync] sort push POST \(Self.resourcePosEndpoint): type=\(resourceType), count=\(items.count), corpId=\(corpId ?? "nil")")
        let r = await api.send("POST", Self.resourcePosEndpoint, body: .object(payload))
        RuntimeLog.debug("[CloudSync] sort push response: ok=\(r.ok), msg=\(r.msg)")
    }
}