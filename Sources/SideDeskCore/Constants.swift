import Foundation

/// 应用级常量。对应 Windows C# 的 `SideDesk.Constants`。
/// 区域选择：定义 `API_REGION_EN` 编译标志切国际版；缺省为中文版（bigjing 域名）。
public enum Constants {

    /// API 区域标记（仅用于启动日志与诊断，与 C# 的三个编译标志分支一致）。
    /// 对应 C# `App.OnStartup` 里 `#if API_REGION_ZH / API_REGION_EN` 算出的 `apiRegion`。
    public static let apiRegion: String = {
        #if API_REGION_ZH
        return "zh"
        #elseif API_REGION_EN
        return "en"
        #else
        return "default"
        #endif
    }()

    public enum Generic {
        public static let taskName = "SideDeskStartup"
    }

    public enum URLs {
        public static let ipify = "https://api.ipify.org"

        /// 产品主页（根域名）基址。其它根域名用途默认从此派生。
        #if API_REGION_EN
        public static let homePageBaseUrl = "https://sidedesk.desktxp.com"
        #else
        public static let homePageBaseUrl = "https://sidedesk.bigjing.com"
        #endif

        /// 自动更新源（自建静态文件服务器）。中文版用独立 CDN。
        #if API_REGION_EN
        public static let updateUrl = homePageBaseUrl + "/updates"
        #else
        public static let updateUrl = "https://cdn.bigjing.com/updates/sidedesk-cn"
        #endif

        /// 后端 API + 管理前端统一基址（发布时只需改这一处）。
        #if API_REGION_EN
        public static let serverBaseUrl = "https://api.sidedesk.desktxp.com/console"
        #else
        public static let serverBaseUrl = "https://api.sidedesk.bigjing.com/console"
        #endif

        /// 前端站点基址（与后端同基址，保留别名以便语义区分）。
        public static var frontendBaseUrl: String { serverBaseUrl }

        /// 是否本地/测试环境（ServerBaseUrl 指向本机）。
        public static var isDev: Bool {
            serverBaseUrl.lowercased().contains("localhost") || serverBaseUrl.contains("127.0.0.1")
        }

        /// OAuth2「系统浏览器登录」客户端 ID（授权码 + PKCE）。
        public static let oauthClientId = "sidedesk-desktop"
    }
}
