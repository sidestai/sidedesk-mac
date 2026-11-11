import Foundation

/// 资源包解析（替代直接用 SPM 生成的 `Bundle.module`）。
///
/// `Bundle.module` 只认两个位置：`Bundle.main.bundleURL` 同级的 `<名字>.bundle`，以及编译期写死的
/// `.build/.../release/<名字>.bundle` 绝对路径。装进 `.app` 后两个都不成立——`bundleURL` 是 `.app` 根目录，
/// 而资源包按规范放在 `Contents/Resources`；一旦 `.build` 被清理或 app 被挪走就直接 `fatalError`。
/// 这里按标准位置自己找，找不到再退回调用方给的 `Bundle.module`（单元测试时它仍然有效）。
public enum ResourceBundles {

    /// 取名为 `<name>.bundle` 的资源包（`name` 形如 `SidestMac_SideDeskCore`）。
    /// - Parameter fallback: 标准位置都没有时的兜底，一般传本 target 的 `Bundle.module`。
    ///   必须是 `@autoclosure`：`Bundle.module` 一旦被求值就可能直接 fatalError，兜底只能懒触发。
    public static func bundle(named name: String, fallback: @autoclosure () -> Bundle) -> Bundle {
        for base in searchBases {
            if let bundle = Bundle(path: base.appendingPathComponent(name + ".bundle").path) {
                return bundle
            }
        }
        return fallback()
    }

    /// 本 target（SideDeskCore）的资源包：`langs/` 与 `themes/` 都在这里。
    public static var core: Bundle { bundle(named: "SidestMac_SideDeskCore", fallback: Bundle.module) }

    /// 候选根目录：正常启动的 app 取 `Contents/Resources`；直接跑 `.app` 里的可执行文件（冒烟脚本、
    /// 调试）时 `Bundle.main` 退化成 `Contents/MacOS`，故再往上一层找 `Resources`。
    private static var searchBases: [URL] {
        let main = Bundle.main
        return [main.resourceURL, main.bundleURL].compactMap { $0 }
            + [main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources")]
    }
}
