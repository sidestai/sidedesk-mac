import Foundation

/// 第三方模块清单（module.json，模块 zip 包根声明）（对应 C# ModuleManifest）。
public final class ModuleManifest: Codable {
    /// 模块 id（目录名 / 虚拟主机名 / 授权记账键）
    public var Id: String = ""
    /// 显示名称
    public var Name: String = ""
    /// 多语言名称（语言代码 → 文本），缺失回落 Name
    public var NameI18n: [String: String] = [:]
    /// 模块版本
    public var Version: String = "1.0.0"
    /// 描述
    public var Description: String = ""
    /// 多语言描述，缺失回落 Description
    public var DescriptionI18n: [String: String] = [:]
    /// 作者
    public var Author: String = ""
    /// 入口文件名（相对模块目录）
    public var Entry: String = ""
    /// 运行时形态原始字符串：exe / dll / html；缺失或未知回落 exe
    public var KindRaw: String?
    /// 仅 dll：IPlugin 实现类全名
    public var TypeName: String?
    /// 仅 html：主界面 HTML 相对路径
    public var ModuleHtml: String?
    /// 仅 html：设置页 HTML 相对路径
    public var SettingsHtml: String?
    /// 声明消费的能力族
    public var Capabilities: [String] = []
    /// 声明提供的能力
    public var Provides: [String] = []
    /// 挂载形态声明（card / background / tool / overlay）
    public var Mounts: [String] = []
    /// 声明接管的旧提供方能力
    public var Supersedes: [String] = []
    /// 图标：模块目录内 .svg 相对路径
    public var Icon: String = ""
    /// 最低宿主版本
    public var MinHostVersion: String?
    /// 依赖的宿主模块 API 版本
    public var ApiVersion: Int = 1

    /// 模块所在目录（扫描时填充，不参与序列化，对应 C# [JsonIgnore]）
    public var SourceDirectory: String?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case Id = "id"
        case Name = "name"
        case NameI18n = "nameI18n"
        case Version = "version"
        case Description = "description"
        case DescriptionI18n = "descriptionI18n"
        case Author = "author"
        case Entry = "entry"
        case KindRaw = "kind"
        case TypeName = "typeName"
        case ModuleHtml = "moduleHtml"
        case SettingsHtml = "settingsHtml"
        case Capabilities = "capabilities"
        case Provides = "provides"
        case Mounts = "mounts"
        case Supersedes = "supersedes"
        case Icon = "icon"
        case MinHostVersion = "minHostVersion"
        case ApiVersion = "apiVersion"
    }

    public convenience init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, "")
        Name = c.or(.Name, "")
        NameI18n = c.or(.NameI18n, [:])
        Version = c.or(.Version, "1.0.0")
        Description = c.or(.Description, "")
        DescriptionI18n = c.or(.DescriptionI18n, [:])
        Author = c.or(.Author, "")
        Entry = c.or(.Entry, "")
        KindRaw = c.opt(.KindRaw)
        TypeName = c.opt(.TypeName)
        ModuleHtml = c.opt(.ModuleHtml)
        SettingsHtml = c.opt(.SettingsHtml)
        Capabilities = c.or(.Capabilities, [])
        Provides = c.or(.Provides, [])
        Mounts = c.or(.Mounts, [])
        Supersedes = c.or(.Supersedes, [])
        Icon = c.or(.Icon, "")
        MinHostVersion = c.opt(.MinHostVersion)
        ApiVersion = c.or(.ApiVersion, 1)
    }

    /// 解析后的挂载形态集合（未知值记日志后跳过）
    public var MountKinds: [ModuleMountKind] {
        var kinds: [ModuleMountKind] = []
        for raw in Mounts {
            if let k = ModuleMounts.parse(raw) { kinds.append(k) }
            else { RuntimeLog.debug("Modules", "[manifest] \(Id): 未知挂载形态 '\(raw)'（忽略）") }
        }
        return kinds
    }

    /// 是否挂了指定形态
    public func hasMount(_ kind: ModuleMountKind) -> Bool {
        MountKinds.contains(kind)
    }

    /// 解析后的运行时形态：命中白名单用它；缺失/未知回落 .exe
    public var Kind: ModuleKind {
        guard let raw = KindRaw, !raw.isEmpty else { return .exe }
        if let k = ModuleKinds.parse(raw) { return k }
        RuntimeLog.debug("Modules", "[manifest] \(Id): 未知 kind '\(raw)'（回落 exe）")
        return .exe
    }

    /// 按宿主当前语言解析的显示名称
    public var DisplayName: String { ModuleManifest.resolveI18n(NameI18n, Name) }
    /// 按宿主当前语言解析的显示描述
    public var DisplayDescription: String { ModuleManifest.resolveI18n(DescriptionI18n, Description) }

    /// 多语言字段解析（镜像 C# PluginTextI18n.Resolve）：
    /// 先按 Lang.current 精确匹配，再按前缀匹配区域变体（zh → zh-CN/zh-TW），均无则回落。
    static func resolveI18n(_ map: [String: String]?, _ fallback: String) -> String {
        guard let map, !map.isEmpty else { return fallback }
        let lang = Lang.current
        if let exact = map[lang], !exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return exact
        }
        for (key, value) in map {
            if !key.isEmpty,
               lang.lowercased().hasPrefix(key.lowercased()),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return fallback
    }
}
