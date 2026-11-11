import XCTest
@testable import SideDeskCore

/// T2 领域地基验收：Codable 往返 + 宽松解码 + PascalCase 线上格式 + 迁移路径。
final class ModelsTests: XCTestCase {

    private func roundTrip<T: Codable>(_ value: T, _ type: T.Type) throws -> T {
        let data = try SideDeskJSON.encoder().encode(value)
        return try SideDeskJSON.decoder().decode(type, from: data)
    }

    // MARK: - Settings

    func testSettingsRoundTrip() throws {
        let s = Settings()
        s.Layout = .both
        s.LeftPanelWidth = 140
        s.RightPanelWidth = 160
        s.ThemeMode = "Light"
        s.BackgroundOpacity = 75
        let back = try roundTrip(s, Settings.self)
        XCTAssertEqual(back.Layout, .both)
        XCTAssertEqual(back.LeftPanelWidth, 140)
        XCTAssertEqual(back.RightPanelWidth, 160)
        XCTAssertEqual(back.ThemeMode, "Light")
        XCTAssertEqual(back.BackgroundOpacity, 75, accuracy: 0.001)
    }

    func testSettingsLenientDecodeEmptyObject() throws {
        // 空对象应回落到默认值（镜像 C# JsonSerializer 对缺失键的容忍）
        let back = try SideDeskJSON.decoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(back.Layout, .left)
        XCTAssertEqual(back.LeftPanelWidth, 105)
    }

    func testSettingsPanelWidthMigrationOnSaveLoad() throws {
        let dir = NSTemporaryDirectory() + "sidest-settings-\(UUID().uuidString)"
        Settings.DirOverride = dir
        defer { Settings.DirOverride = nil; try? FileManager.default.removeItem(atPath: dir) }

        // 手写旧配置：仅有 PanelWidth，无 Left/RightPanelWidth 键
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let legacy = "{\"PanelWidth\": 130}"
        try legacy.write(toFile: (dir as NSString).appendingPathComponent("app-settings.json"),
                         atomically: true, encoding: .utf8)
        let loaded = Settings.Load()
        XCTAssertEqual(loaded.LeftPanelWidth, 130, "旧 PanelWidth 应迁移到左侧")
        XCTAssertEqual(loaded.RightPanelWidth, 130, "旧 PanelWidth 应迁移到右侧")
        XCTAssertFalse(loaded.Monitors.isEmpty, "空 Monitors 应迁移出主显示器条目")
    }

    // MARK: - AppSettings

    func testAppSettingsRoundTrip() throws {
        let a = AppSettings()
        a.RunAtStartup = true
        a.CardFontSize = 16
        let back = try roundTrip(a, AppSettings.self)
        XCTAssertEqual(back.RunAtStartup, true)
        XCTAssertEqual(back.CardFontSize, 16)
    }

    // MARK: - Wire-format parity (PascalCase keys)

    func testPascalCaseWireKeys() throws {
        var cs = CloudSpace()
        cs.Name = "微屏云盘"
        cs.IsBuiltin = true
        let data = try SideDeskJSON.encoder().encode(cs)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj?["Id"])
        XCTAssertEqual(obj?["Name"] as? String, "微屏云盘")
        XCTAssertNotNil(obj?["IsBuiltin"])
        XCTAssertNotNil(obj?["CreatedAt"])
    }

    // MARK: - Simple models lenient decode

    func testLenientDecodeDefaults() throws {
        let empty = Data("{}".utf8)
        let tool = try SideDeskJSON.decoder().decode(AITool.self, from: empty)
        XCTAssertEqual(tool.BackgroundColor, "#7C3AED")
        XCTAssertFalse(tool.Id.isEmpty)

        let s3 = try SideDeskJSON.decoder().decode(S3Source.self, from: empty)
        XCTAssertEqual(s3.Region, "us-east-1")

        let emp = try SideDeskJSON.decoder().decode(DigitalEmployee.self, from: empty)
        XCTAssertEqual(emp.Status, "online")
        XCTAssertEqual(emp.Name, "新员工")

        let note = try SideDeskJSON.decoder().decode(StickyNote.self, from: empty)
        XCTAssertFalse(note.Id.isEmpty)
    }

    func testS3NormalizedPrefix() {
        var s = S3Source()
        s.Prefix = "/root/team"
        XCTAssertEqual(s.NormalizedPrefix, "root/team/")
        s.Prefix = "  "
        XCTAssertEqual(s.NormalizedPrefix, "")
    }

    func testWebDavBaseUrl() {
        var w = WebDavSource()
        w.Url = "https://dav.example.com/user"
        XCTAssertEqual(w.BaseUrl, "https://dav.example.com/user/")
    }

    // MARK: - AdvancedItemConfig

    func testAdvancedItemConfigJsonRoundTrip() throws {
        var cfg = AdvancedItemConfig()
        cfg.ActionType = "keys"
        cfg.KeySequences = ["Ctrl+Shift+P", "Enter"]
        cfg.StepIntervalMs = 80
        cfg.PasteText = nil
        let json = cfg.toJson()
        let back = try XCTUnwrap(AdvancedItemConfig.tryParse(json))
        XCTAssertEqual(back.ActionType, "keys")
        XCTAssertEqual(back.KeySequences, ["Ctrl+Shift+P", "Enter"])
        XCTAssertEqual(back.StepIntervalMs, 80)
        XCTAssertEqual(back.PasteMode, "ctrlv", "未设置字段应保持默认")
        XCTAssertNil(AdvancedItemConfig.tryParse("   "))
        XCTAssertNil(AdvancedItemConfig.tryParse("not json"))
    }

    // MARK: - ModuleKind / ModuleMountKind / ModuleManifest

    func testModuleKindsParseAndInfer() {
        XCTAssertEqual(ModuleKinds.parse("dll"), .dll)
        XCTAssertNil(ModuleKinds.parse("bogus"))
        XCTAssertNil(ModuleKinds.parse(""))
        XCTAssertEqual(ModuleKinds.token(.html), "html")
        XCTAssertEqual(ModuleKinds.infer(modeField: "html", entryField: nil), .html)
        XCTAssertEqual(ModuleKinds.infer(modeField: nil, entryField: "Plugin.dll"), .dll)
        XCTAssertEqual(ModuleKinds.infer(modeField: nil, entryField: "app"), .exe)
    }

    func testModuleMountsParse() {
        XCTAssertEqual(ModuleMounts.parse("overlay"), .overlay)
        XCTAssertNil(ModuleMounts.parse("nope"))
        XCTAssertEqual(ModuleMounts.token(.background), "background")
    }

    func testModuleManifestLenientDecodeAndKindFallback() throws {
        // snake/camel 清单键映射 + 未知 kind 回落 exe + 未知 mount 忽略
        let json = """
        {"id":"demo","name":"Demo","nameI18n":{"en":"Demo EN"},"kind":"weird",
         "mounts":["card","garbage"],"apiVersion":2}
        """
        let m = try SideDeskJSON.decoder().decode(ModuleManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.Id, "demo")
        XCTAssertEqual(m.Name, "Demo")
        XCTAssertEqual(m.NameI18n["en"], "Demo EN")
        XCTAssertEqual(m.ApiVersion, 2)
        XCTAssertEqual(m.Kind, .exe, "未知 kind 应回落 exe")
        XCTAssertEqual(m.KindRaw, "weird", "原始字符串应保留")
        XCTAssertEqual(m.MountKinds, [.card], "未知 mount 应被忽略")
        XCTAssertTrue(m.hasMount(.card))
        XCTAssertFalse(m.hasMount(.tool))
        // Version 缺失 → 默认
        XCTAssertEqual(m.Version, "1.0.0")
    }

    func testModuleManifestResolveI18n() {
        // 精确匹配当前语言
        XCTAssertEqual(ModuleManifest.resolveI18n(["en": "Hello"], "Fallback"), "Hello")
        // 空 map 回落
        XCTAssertEqual(ModuleManifest.resolveI18n([:], "Fallback"), "Fallback")
        XCTAssertEqual(ModuleManifest.resolveI18n(nil, "Fallback"), "Fallback")
    }

    // MARK: - Notification

    func testNotificationActionTypeParse() {
        XCTAssertEqual(NotificationActionType.parse("OPEN_URL"), .openUrl)
        XCTAssertEqual(NotificationActionType.parse(" remind_later "), .snooze)
        XCTAssertEqual(NotificationActionType.parse("cancel_job"), .cancelJob)
        XCTAssertEqual(NotificationActionType.parse("zzz"), .unknown)
        XCTAssertEqual(NotificationActionType.parse(nil), .unknown)
    }

    func testNotificationFromJson() throws {
        let data: [String: Any] = [
            "id": "abc123",
            "title": "标题",
            "content": "正文回退",
            "timeout": 5,
            "allow_close": false,
            "priority": "high",
            "display_mode": "alert",
            "sound": true,
            "progress": 42,
            "group_id": "  ",
            "notice_key": "nk",
            "buttons": [
                ["type": "open_url", "label": "打开", "payload": ["url": "https://x", "n": 3]]
            ],
            "click_main": ["type": "dismiss"]
        ]
        let n = NotificationPayload.fromJson(data)
        XCTAssertEqual(n.Id, "abc123")
        XCTAssertEqual(n.Title, "标题")
        XCTAssertEqual(n.Body, "正文回退")
        XCTAssertEqual(n.Timeout, 5)
        XCTAssertEqual(n.AllowClose, false)
        XCTAssertEqual(n.Priority, .high)
        XCTAssertEqual(n.DisplayMode, .alert)
        XCTAssertEqual(n.Sound, true)
        XCTAssertEqual(n.Progress, 42)
        XCTAssertNil(n.GroupId, "空白 group_id 应归一为 nil")
        XCTAssertEqual(n.NoticeKey, "nk")
        XCTAssertEqual(n.Buttons?.count, 1)
        XCTAssertEqual(n.Buttons?.first?.ActionType, .openUrl)
        XCTAssertEqual(n.Buttons?.first?.payloadString("url"), "https://x")
        XCTAssertEqual(n.Buttons?.first?.payloadNumber("n"), 3)
        XCTAssertEqual(n.ClickMain?.ActionType, .dismiss)
    }

    func testNotificationPayloadCodableRoundTrip() throws {
        var n = NotificationPayload()
        n.Title = "T"
        n.Priority = .critical
        n.DisplayMode = .silent
        n.Progress = 90
        var act = NotificationAction()
        act.`Type` = "run_command"
        act.Label = "运行"
        act.Payload = ["cmd": .string("ls"), "bg": .bool(true)]
        n.Buttons = [act]
        let back = try roundTrip(n, NotificationPayload.self)
        XCTAssertEqual(back.Priority, .critical)
        XCTAssertEqual(back.DisplayMode, .silent)
        XCTAssertEqual(back.Progress, 90)
        XCTAssertEqual(back.Buttons?.first?.ActionType, .runCommand)
        XCTAssertEqual(back.Buttons?.first?.payloadString("cmd"), "ls")
        XCTAssertEqual(back.Buttons?.first?.payloadBool("bg"), true)
    }

    func testNotificationShowUnread() {
        var n = NotificationPayload()
        n.IsRead = false
        n.Timestamp = Date()
        XCTAssertTrue(n.ShowUnread)
        n.Timestamp = Date().addingTimeInterval(-31 * 24 * 3600)
        XCTAssertFalse(n.ShowUnread, "超过 30 天的未读不再亮红点")
        n.IsRead = true
        n.Timestamp = Date()
        XCTAssertFalse(n.ShowUnread)
    }

    // MARK: - JSONValue

    func testJSONValueRoundTrip() throws {
        let v: JSONValue = .object([
            "s": .string("hi"), "i": .int(7), "d": .double(1.5),
            "b": .bool(true), "n": .null, "arr": .array([.int(1), .string("x")])
        ])
        let data = try SideDeskJSON.encoder().encode(v)
        let back = try SideDeskJSON.decoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(back, v)
    }

    func testJSONValueFromAny() {
        let dict: [String: Any] = ["k": 5, "f": 2.5, "s": "v", "b": true, "null": NSNull()]
        let obj = JSONValue(any: dict)
        if case .object(let o) = obj {
            XCTAssertEqual(o["k"]?.stringValue, "5")
            XCTAssertEqual(o["s"]?.stringValue, "v")
            XCTAssertEqual(o["b"]?.boolValue, true)
            XCTAssertEqual(o["null"], .null)
        } else {
            XCTFail("expected object")
        }
    }

    // MARK: - AIToolManager file persistence

    func testAIToolManagerRoundTrip() {
        let dir = NSTemporaryDirectory() + "sidest-aitool-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        AIToolManager.resetCache()
        defer {
            AIToolManager.resetCache()
            AppPaths.setOverride(nil)
            try? FileManager.default.removeItem(atPath: dir)
        }

        var t = AITool()
        t.Name = "ChatGPT"
        t.Url = "https://chat.openai.com"
        t.Icon = "🤖"
        AIToolManager.Add(t)

        // 清缓存后从磁盘重载，验证已落盘
        AIToolManager.resetCache()
        let all = AIToolManager.GetAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.Name, "ChatGPT")
        XCTAssertEqual(all.first?.Icon, "🤖")

        AIToolManager.Remove(t.Id)
        AIToolManager.resetCache()
        XCTAssertEqual(AIToolManager.GetAll().count, 0)
    }

    // MARK: - ProgramRegistry 持久化

    /// 程序注册表落盘/重载（启动期 `Load()` 读的就是这份；路径跟 `AppPaths` 覆盖走，
    /// 故 test-mode 的隔离目录里不会碰到真实登记表）。
    func testProgramRegistryRoundTrip() {
        let dir = NSTemporaryDirectory() + "sidest-registry-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        defer {
            AppPaths.setOverride(nil)
            try? FileManager.default.removeItem(atPath: dir)
        }

        let reg = ProgramRegistryManager()
        reg.DefaultProfileBaseDir = "\(dir)/profiles"
        let browser = BrowserConfig()
        browser.Id = "b1"; browser.Name = "Chrome"; browser.ExePath = "/Applications/Chrome.app"
        let profile = UserDataProfile()
        profile.Id = "p1"; profile.Name = "工作"; profile.Directory = "\(dir)/p1"
        browser.Profiles = [profile]
        reg.Browsers = [browser]
        let entry = ProgramEntry()
        entry.Id = "e1"; entry.Name = "Terminal"; entry.ExePath = "/System/Applications/Utilities/Terminal.app"
        reg.Programs = [entry]
        reg.Save()

        let back = ProgramRegistryManager.Load()
        XCTAssertEqual(back.DefaultProfileBaseDir, "\(dir)/profiles")
        XCTAssertEqual(back.Programs.count, 1)
        XCTAssertEqual(back.Programs.first?.Name, "Terminal")
        XCTAssertEqual(back.GetBrowserById("b1")?.ExePath, "/Applications/Chrome.app")
        XCTAssertEqual(back.GetProfileById("b1", "p1")?.Directory, "\(dir)/p1")
        XCTAssertNil(back.GetBrowserById(nil), "空 id 不查表（与 C# 一致）")
        XCTAssertNil(back.GetBrowserById("nope"))
        XCTAssertNil(back.GetProfileById("b1", "nope"))
    }

    /// 文件损坏 / 不存在时回落空表，不抛（启动不能被一份坏登记表挡住）。
    func testProgramRegistryLoadFallsBackOnBadFile() {
        let dir = NSTemporaryDirectory() + "sidest-registry-bad-\(UUID().uuidString)"
        AppPaths.setOverride(dir)
        defer {
            AppPaths.setOverride(nil)
            try? FileManager.default.removeItem(atPath: dir)
        }

        XCTAssertEqual(ProgramRegistryManager.Load().Browsers.count, 0, "缺文件 = 空表")

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: URL(fileURLWithPath: dir + "/program-registry.json"))
        XCTAssertEqual(ProgramRegistryManager.Load().Programs.count, 0, "坏文件也不抛")
    }
}
