import Foundation

/// 模块运行时形态（module.json 的 kind 字段）：安装期声明"这个模块底下是怎么跑的"，
/// 宿主按 kind 分派到三套加载器之一（对应 C# ModuleKind）。
/// 与 ModuleMountKind（挂载形态）正交：kind 说"怎么加载"，mounts 说"挂到哪"。
public enum ModuleKind: Equatable {
    /// 独立进程 sidecar（新模块系统，NDJSON/JSON-RPC 协议）——缺省值
    case exe
    /// 宿主进程内 .NET DLL（老 native 插件系统）
    case dll
    /// WebView 沙箱 HTML 插件（老 html 插件系统）
    case html
}

/// kind 字段的字符串白名单与解析（宽松解析：未知值回落 .exe，不炸整份清单）。
public enum ModuleKinds {
    public static let exe = "exe"
    public static let dll = "dll"
    public static let html = "html"

    /// 解析单个 kind 字符串（未知/空 = nil）
    public static func parse(_ raw: String?) -> ModuleKind? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case exe: return .exe
        case dll: return .dll
        case html: return .html
        default: return nil
        }
    }

    /// 枚举 → 清单字符串
    public static func token(_ kind: ModuleKind) -> String {
        switch kind {
        case .exe: return exe
        case .dll: return dll
        case .html: return html
        }
    }

    /// 从 plugin.json 内容推断 kind：mode == "html" → html；entry 以 .dll 结尾 → dll；否则 exe
    public static func infer(modeField: String?, entryField: String?) -> ModuleKind {
        if modeField == "html" { return .html }
        if let e = entryField, !e.isEmpty, e.lowercased().hasSuffix(".dll") { return .dll }
        return .exe
    }
}
