import Foundation

/// `--test-mode` 一族启动参数的解析结果。对应 C# `App.ApplyTestMode` + `ParseTestDirArg`
/// 与 OnStartup 尾部的 `--test-timeout` 读取。
public struct TestModeLaunch: Equatable {
    /// 窗口级 E2E：恢复侧栏/布局注册（`--test-with-bars`），其余副作用守卫保持不变。
    public var withBars: Bool
    /// 隔离数据目录（`--test-dir`，缺省 `<tempDir>/SideDesk-test`）。
    public var dataDir: String
    /// 自动退出秒数（`--test-timeout`，缺省 60）。
    public var timeoutSeconds: Int
}

/// 启动参数解析（纯函数，供单测逐分支钉死；布置目录的副作用留在宿主）。
///
/// 判等一律不分大小写——与 C# `StringComparer.OrdinalIgnoreCase` 一致。
public enum TestModeArgs {

    /// 没有 `--test-mode` 时返回 nil（= 正常生产启动，什么都不布置）。
    public static func parse(_ args: [String], tempDir: String) -> TestModeLaunch? {
        guard contains(args, "--test-mode") else { return nil }
        return TestModeLaunch(
            withBars: contains(args, "--test-with-bars"),
            dataDir: testDir(args) ?? (tempDir as NSString).appendingPathComponent("SideDesk-test"),
            timeoutSeconds: timeoutSeconds(args)
        )
    }

    /// `--test-dir=<path>`（单参）与 `--test-dir <path>`（空格双参）两种写法都认；
    /// 值去首尾双引号，空白视为未指定（回落到默认目录）。
    public static func testDir(_ args: [String]) -> String? {
        let prefix = "--test-dir="
        for a in args where a.lowercased().hasPrefix(prefix) {
            let v = String(a.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return v.isEmpty ? nil : v
        }
        guard let value = nextValue(args, "--test-dir") else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `--test-timeout <秒>`（仅空格双参形式，与 C# 一致）；非正整数回落 60。
    public static func timeoutSeconds(_ args: [String]) -> Int {
        guard let raw = nextValue(args, "--test-timeout"), let parsed = Int(raw), parsed > 0 else { return 60 }
        return parsed
    }

    private static func contains(_ args: [String], _ flag: String) -> Bool {
        args.contains { $0.lowercased() == flag }
    }

    /// 定位 flag 元素并取紧随其后的那个参数；flag 是最后一项时返回 nil。
    private static func nextValue(_ args: [String], _ flag: String) -> String? {
        guard let idx = args.firstIndex(where: { $0.lowercased() == flag }), idx + 1 < args.count else { return nil }
        let value = args[idx + 1]
        return value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
    }
}
