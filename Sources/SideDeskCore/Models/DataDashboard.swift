import Foundation

/// 数据看板条目。对应 C# `Models.DataDashboardItem`。
public final class DataDashboardItem: Codable {
    public var Id: String = UUID().uuidString
    public var Label: String = ""
    public var Value: String = "--"
    public var TemplateId: String = ""
    public var BrowserId: String?
    public var ProfileId: String?
    public var TargetUrl: String = ""
    public var Selector: String = ""
    public var SelectorType: String = ""       // xpath/css/regex/js（空=旧版自动识别）
    public var RefreshIntervalSeconds: Int = 60

    // API 请求模式（ApiMethod 非空时直接 HTTP 取数）
    public var ApiMethod: String?              // GET / POST
    public var ApiBody: String?
    public var ResponseExtract: String?
    public var ApiExtractType: String?         // json / regex

    // 正则后过滤
    public var ExtractRegex: String?
    public var ExtractFormat: String?

    // 团队归属与变量
    public var TeamId: String?
    public var TeamName: String?
    public var VarKey: String?
    public var DashboardGroupId: String?
    public var RefVarKey: String?

    // 样式配置
    public var LabelColor: String = ""
    public var LabelFontSize: Double = 0
    public var LabelBold: Bool = false
    public var ValueColor: String = ""
    public var ValueFontSize: Double = 0
    public var ValueBold: Bool = false
    public var HorizontalAlignment: String = ""
    public var ValueFormat: String?

    public init() {}

    /// 对原始值应用正则后过滤（与插件侧语义一致）：无正则/正则非法返回原文；未匹配返回空串。
    /// 格式串 {0} 整匹配，{1}..{n} 捕获组。对应 C# `ApplyValueExtract`。
    public static func ApplyValueExtract(_ raw: String, _ regex: String?, _ format: String?) -> String {
        guard let regex, !regex.isEmpty else { return raw }
        guard let re = try? NSRegularExpression(pattern: regex) else { return raw }
        let ns = raw as NSString
        guard let m = re.firstMatch(in: raw, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return ""
        }
        let fmt = (format == nil || format!.isEmpty) ? "{0}" : format!
        var result = ""
        var i = fmt.startIndex
        while i < fmt.endIndex {
            if fmt[i] == "{",
               let close = fmt[fmt.index(after: i)...].firstIndex(of: "}"),
               let n = Int(fmt[fmt.index(after: i)..<close]) {
                if n < m.numberOfRanges {
                    let gr = m.range(at: n)
                    result += (gr.location == NSNotFound) ? "" : ns.substring(with: gr)
                }
                i = fmt.index(after: close)
                continue
            }
            result.append(fmt[i])
            i = fmt.index(after: i)
        }
        return result
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, UUID().uuidString)
        Label = c.or(.Label, "")
        Value = c.or(.Value, "--")
        TemplateId = c.or(.TemplateId, "")
        BrowserId = c.opt(.BrowserId)
        ProfileId = c.opt(.ProfileId)
        TargetUrl = c.or(.TargetUrl, "")
        Selector = c.or(.Selector, "")
        SelectorType = c.or(.SelectorType, "")
        RefreshIntervalSeconds = c.or(.RefreshIntervalSeconds, 60)
        ApiMethod = c.opt(.ApiMethod)
        ApiBody = c.opt(.ApiBody)
        ResponseExtract = c.opt(.ResponseExtract)
        ApiExtractType = c.opt(.ApiExtractType)
        ExtractRegex = c.opt(.ExtractRegex)
        ExtractFormat = c.opt(.ExtractFormat)
        TeamId = c.opt(.TeamId)
        TeamName = c.opt(.TeamName)
        VarKey = c.opt(.VarKey)
        DashboardGroupId = c.opt(.DashboardGroupId)
        RefVarKey = c.opt(.RefVarKey)
        LabelColor = c.or(.LabelColor, "")
        LabelFontSize = c.or(.LabelFontSize, 0)
        LabelBold = c.or(.LabelBold, false)
        ValueColor = c.or(.ValueColor, "")
        ValueFontSize = c.or(.ValueFontSize, 0)
        ValueBold = c.or(.ValueBold, false)
        HorizontalAlignment = c.or(.HorizontalAlignment, "")
        ValueFormat = c.opt(.ValueFormat)
    }
}

/// 变量集：把多个运行中的变量按 SUM/AVG/MAX/MIN/COUNT 聚合成一个新变量。对应 C# `VariableSet`。
public final class VariableSet: Codable {
    public var VarKey: String = ""
    public var Op: String = "SUM"
    public var SourceKeys: [String] = []
    public var Pattern: String = ""
    public var TeamId: String?
    public var TeamName: String?
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        VarKey = c.or(.VarKey, "")
        Op = c.or(.Op, "SUM")
        SourceKeys = c.or(.SourceKeys, [])
        Pattern = c.or(.Pattern, "")
        TeamId = c.opt(.TeamId)
        TeamName = c.opt(.TeamName)
    }
}

/// 后端登记的变量集行（`GET /api/sidebar/data-variable/sets` 的 data 数组元素）。
/// 对应 C# `Services.VariableSetInfo`。与本地 `VariableSet` 分开：后端字段是 lowerCamel，
/// 且 `op`/`sourceKeys`/`pattern` 允许缺省（空 op 在并入时按 SUM 处理）。
public struct VariableSetInfo: Codable {
    public var VarKey: String = ""
    public var Op: String = "SUM"
    public var SourceKeys: [String]?
    public var Pattern: String?
    /// 团队加密串；nil=个人作用域
    public var CorpId: String?

    enum CodingKeys: String, CodingKey {
        case VarKey = "varKey"
        case Op = "op"
        case SourceKeys = "sourceKeys"
        case Pattern = "pattern"
        case CorpId = "corpId"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        VarKey = c.or(.VarKey, "")
        Op = c.or(.Op, "SUM")
        SourceKeys = c.opt(.SourceKeys)
        Pattern = c.opt(.Pattern)
        CorpId = c.opt(.CorpId)
    }
}

/// 模板数据点（一条选择器条目）。对应 C# `TemplateSelector`。
public final class TemplateSelector: Codable {
    public var VarKey: String = ""
    public var TargetUrl: String = ""
    public var Selector: String = ""
    public var SelectorType: String = ""
    public var RefreshIntervalSeconds: Int = 60
    public var ExtractRegex: String?
    public var ExtractFormat: String?
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        VarKey = c.or(.VarKey, "")
        TargetUrl = c.or(.TargetUrl, "")
        Selector = c.or(.Selector, "")
        SelectorType = c.or(.SelectorType, "")
        RefreshIntervalSeconds = c.or(.RefreshIntervalSeconds, 60)
        ExtractRegex = c.opt(.ExtractRegex)
        ExtractFormat = c.opt(.ExtractFormat)
    }
}

/// 数据模板定义（预定义或用户自建）。对应 C# `DataTemplate`。
/// 注：C# 的 `DataTemplateManager`（文件 IO 编排）属服务层，移植到 T3 SideDeskServices。
public final class DataTemplate: Codable {
    public var Id: String = ""
    public var Name: String = ""
    public var Description: String = ""
    public var Category: String = ""
    public var TargetUrl: String = ""
    public var Selector: String = ""
    public var SelectorType: String = ""
    public var RefreshIntervalSeconds: Int = 60
    public var DefaultBrowserId: String?
    public var DefaultProfileId: String?
    public var TeamId: String?
    public var TeamName: String?
    public var Source: String?
    public var MarketPublished: Bool = false
    public var ValueFormat: String?
    public var LabelColor: String = ""
    public var LabelFontSize: Double = 0
    public var LabelBold: Bool = false
    public var ValueColor: String = ""
    public var ValueFontSize: Double = 0
    public var ValueBold: Bool = false
    public var HorizontalAlignment: String = ""
    public var Selectors: [TemplateSelector] = []

    public init() {}

    /// 是否市场下载来源（新数据带 Source 标记；旧数据回退认 market- 前缀 ID）。对应 C# `[JsonIgnore] IsMarketSourced`。
    public var IsMarketSourced: Bool {
        (Source?.caseInsensitiveCompare("market") == .orderedSame)
            || Id.lowercased().hasPrefix("market-")
    }

    /// 列表展示用标签：市场下载统一显示「市场」，其余显示自建分类。
    public var DisplayTag: String { IsMarketSourced ? Lang.t("common.market") : Category }

    /// 生效数据点位：Selectors 优先；空时用旧版单点位字段兜底一条。
    public var EffectiveSelectors: [TemplateSelector] {
        if !Selectors.isEmpty { return Selectors }
        let s = TemplateSelector()
        s.TargetUrl = TargetUrl
        s.Selector = Selector
        s.SelectorType = SelectorType
        s.RefreshIntervalSeconds = RefreshIntervalSeconds
        return [s]
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        Id = c.or(.Id, "")
        Name = c.or(.Name, "")
        Description = c.or(.Description, "")
        Category = c.or(.Category, "")
        TargetUrl = c.or(.TargetUrl, "")
        Selector = c.or(.Selector, "")
        SelectorType = c.or(.SelectorType, "")
        RefreshIntervalSeconds = c.or(.RefreshIntervalSeconds, 60)
        DefaultBrowserId = c.opt(.DefaultBrowserId)
        DefaultProfileId = c.opt(.DefaultProfileId)
        TeamId = c.opt(.TeamId)
        TeamName = c.opt(.TeamName)
        Source = c.opt(.Source)
        MarketPublished = c.or(.MarketPublished, false)
        ValueFormat = c.opt(.ValueFormat)
        LabelColor = c.or(.LabelColor, "")
        LabelFontSize = c.or(.LabelFontSize, 0)
        LabelBold = c.or(.LabelBold, false)
        ValueColor = c.or(.ValueColor, "")
        ValueFontSize = c.or(.ValueFontSize, 0)
        ValueBold = c.or(.ValueBold, false)
        HorizontalAlignment = c.or(.HorizontalAlignment, "")
        Selectors = c.or(.Selectors, [])
    }
}
