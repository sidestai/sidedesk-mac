import AppKit
import SwiftUI
import SideDeskCore
import SideDeskServices

/// 信号灯设置弹窗（对应 C# `NativeModePanel.ShowSignalLightEditDialog`）：
/// 排列方向 / 灯样式 / 大小 / 间距 / 对齐 + 灯列表（编辑 / 删除）+ 添加灯。
/// 灯的增删与单灯详情编辑实时提交（列表与卡片同步刷新，弹窗观察 model）；布局项（方向/样式/大小/间距/对齐）
/// 点「确定」才统一写回（对应 C# OK 里读控件值 + 把样式/大小刷到每盏灯）。
/// 单灯详情里的「开 / 关 / 闪烁」三态变量条件与闪烁频率见 `SignalLightDetailForm`（已接求值状态机）。
@MainActor
final class SignalLightSettingsWindowController: NSWindowController, NSWindowDelegate {

    private static var live: [SignalLightSettingsWindowController] = []

    convenience init(panel: PanelItem, model: BarCardsModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Lang.t("nativePanel.setSignalLight")
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SignalLightSettingsForm(
            panel: panel,
            model: model,
            onClose: { [weak self] in self?.close() }
        ))
    }

    func present() {
        Self.live.append(self)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.live.removeAll { $0 === self }
    }
}

enum SignalLightSettingsDialog {
    @MainActor static func present(panel: PanelItem, model: BarCardsModel) {
        SignalLightSettingsWindowController(panel: panel, model: model).present()
    }
}

private struct SignalLightSettingsForm: View {

    let panel: PanelItem
    @ObservedObject var model: BarCardsModel
    let onClose: () -> Void

    @State private var vertical: Bool
    @State private var style: String
    @State private var sizeText: String
    @State private var spacingText: String
    @State private var alignment: String

    init(panel: PanelItem, model: BarCardsModel, onClose: @escaping () -> Void) {
        self.panel = panel
        self.model = model
        self.onClose = onClose
        let first = panel.SignalLights?.first
        let s = first?.LightStyle
        _vertical = State(initialValue: panel.SignalLightVertical)
        _style = State(initialValue: (s == "Square" || s == "Pixel") ? s! : "Circle")
        _sizeText = State(initialValue: first.map { Self.fmt($0.Size) } ?? "36")
        _spacingText = State(initialValue: Self.fmt(panel.SignalLightSpacing))
        let a = panel.SignalLightAlignment
        _alignment = State(initialValue: (a == "Left" || a == "Right") ? a : "Center")
    }

    private static func fmt(_ v: Double) -> String { String(format: "%g", v) }

    var body: some View {
        let palette = ThemeManager.palette
        VStack(alignment: .leading, spacing: 10) {
            settingRow(Lang.t("nativePanel.arrangementDirection")) {
                Picker("", selection: $vertical) {
                    Text(Lang.t("common.horizontal")).tag(false)
                    Text(Lang.t("common.vertical")).tag(true)
                }
                .pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
            }
            settingRow(Lang.t("nativePanel.lightStyle")) {
                Picker("", selection: $style) {
                    Text(Lang.t("settings.circle")).tag("Circle")
                    Text(Lang.t("nativePanel.square")).tag("Square")
                    Text(Lang.t("common.px")).tag("Pixel")
                }
                .pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
            }
            settingRow(Lang.t("nativePanel.lightSize")) {
                TextField("36", text: $sizeText).dialogFieldStyle()
            }
            settingRow(Lang.t("nativePanel.spacing")) {
                TextField("5", text: $spacingText).dialogFieldStyle()
            }
            settingRow(Lang.t("nativePanel.alignment")) {
                Picker("", selection: $alignment) {
                    Text(Lang.t("nativePanel.left")).tag("Left")
                    Text(Lang.t("nativePanel.center")).tag("Center")
                    Text(Lang.t("nativePanel.right")).tag("Right")
                }
                .pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(Lang.t("nativePanel.signalLight"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.textMain.color)
                .padding(.top, 4)

            lightList

            Button(Lang.t("nativePanel.addLight")) { model.addSignalLight(panel) }

            HStack {
                Spacer()
                Button(Lang.t("common.cancel")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(Lang.t("common.ok")) { confirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    @ViewBuilder private func settingRow<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.system(size: 12)).frame(width: 76, alignment: .leading)
            content()
        }
    }

    /// 灯列表：序号 + 色块 + 颜色值 + 大小 + 图标 + 编辑 / 删除（对应 C# `RenderEditList`）。
    @ViewBuilder private var lightList: some View {
        let lights = panel.SignalLights ?? []
        let tp = ThemeManager.palette
        if lights.isEmpty {
            Text(Lang.t("nativePanel.addLight"))
                .font(.system(size: 11))
                .foregroundStyle(tp.textMuted.color)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lights.enumerated()), id: \.element.id) { index, light in
                    HStack(spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(size: 12))
                            .foregroundStyle(tp.textMuted.color)
                            .frame(width: 20, alignment: .leading)
                        Circle()
                            .fill(ThemeColor.parse(light.Color)?.color ?? tp.accent.color)
                            .frame(width: 14, height: 14)
                        Text(light.Color)
                            .font(.system(size: 12))
                            .foregroundStyle(tp.textMain.color)
                        Text("\(Lang.t("nativePanel.size"))\(Self.fmt(light.Size))")
                            .font(.system(size: 11))
                            .foregroundStyle(tp.textMuted.color)
                        if let icon = light.Icon, !icon.isEmpty {
                            Text(icon).font(.system(size: 13))
                        }
                        Spacer(minLength: 0)
                        Button { openDetail(light) } label: {
                            Image(systemName: "pencil").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help(Lang.t("common.edit"))
                        Button { model.removeSignalLight(panel, light) } label: {
                            Image(systemName: "xmark").font(.system(size: 11))
                                .foregroundStyle(tp.textMuted.color)
                        }
                        .buttonStyle(.plain)
                        .help(Lang.t("common.delete"))
                    }
                }
            }
        }
    }

    private func openDetail(_ light: SignalLightItem) {
        SignalLightDetailDialog.present(model: model, light: light)
    }

    /// 大小：解析失败或 <=0 回落 36；间距：解析失败或 <0 回落 5（对应 C# OK 的解析口径）。
    private func confirm() {
        let size = Double(sizeText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } ?? 36
        let spacing = Double(spacingText.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil } ?? 5
        model.applySignalLightLayout(panel, vertical: vertical, style: style,
                                     size: size, spacing: spacing, alignment: alignment)
        onClose()
    }
}

// MARK: - 单灯详情弹窗

/// 单灯详情编辑弹窗（对应 C# `ShowSignalLightDetailDialog`）：颜色 / 大小 / 图标 + 三态变量条件
/// （开 / 关 / 闪烁，每态可选 OR 任一 / AND 全部，条件行 = 变量 + 操作符 + 值）+ 闪烁频率。
/// 颜色/大小/图标点「确定」才写回（`updateSignalLight`）；条件与频率与 C# 一致——编辑即原地改在灯对象上，
/// 由「确定」的提交统一落库。求值状态机见 `SignalLightEvaluator`（闪烁 > 关 > 开 > 手动 IsOn）。
@MainActor
final class SignalLightDetailWindowController: NSWindowController, NSWindowDelegate {

    private static var live: [SignalLightDetailWindowController] = []

    convenience init(model: BarCardsModel, light: SignalLightItem) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Lang.t("nativePanel.lightDetails")
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: SignalLightDetailForm(
            model: model,
            light: light,
            onClose: { [weak self] in self?.close() }
        ))
    }

    func present() {
        Self.live.append(self)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.live.removeAll { $0 === self }
    }
}

enum SignalLightDetailDialog {
    @MainActor static func present(model: BarCardsModel, light: SignalLightItem) {
        SignalLightDetailWindowController(model: model, light: light).present()
    }
}

private struct SignalLightDetailForm: View {

    let model: BarCardsModel
    let light: SignalLightItem
    let onClose: () -> Void

    /// 变量下拉的候选（对应 C# `CollectLightVarSources`）：构造时收集一次即可。
    private let varSources: [LightVarSource]

    @State private var colorText: String
    @State private var sizeText: String
    @State private var iconText: String
    @State private var blinkText: String
    /// 条件行改的是灯对象上的引用类型（数组/class），SwiftUI 差分感知不到，靠它强制重建条件区。
    @State private var revision = 0

    init(model: BarCardsModel, light: SignalLightItem, onClose: @escaping () -> Void) {
        self.model = model
        self.light = light
        self.onClose = onClose
        self.varSources = Self.collectVarSources()
        _colorText = State(initialValue: light.Color)
        _sizeText = State(initialValue: String(format: "%g", light.Size))
        _iconText = State(initialValue: light.Icon ?? "")
        _blinkText = State(initialValue: String(format: "%g", light.BlinkIntervalSeconds))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldRow(Lang.t("common.color")) {
                HStack(spacing: 8) {
                    TextField("#FF4444", text: $colorText).dialogFieldStyle()
                    Circle()
                        .fill(ThemeColor.parse(colorText.trimmingCharacters(in: .whitespaces))?.color
                              ?? ThemeManager.palette.textMuted.color)
                        .frame(width: 18, height: 18)
                }
            }
            fieldRow(Lang.t("nativePanel.lightSize")) {
                TextField("36", text: $sizeText).dialogFieldStyle()
            }
            fieldRow(Lang.t("common.iconLabel")) {
                TextField("", text: $iconText).dialogFieldStyle()
            }

            // 三态变量条件（开 / 关 / 闪烁）：满足任一（OR）或全部（AND）即进入该状态。
            condSection(Lang.t("common.on"), conds: \.OnConditions, mode: \.OnConditionMode)
            condSection(Lang.t("common.off"), conds: \.OffConditions, mode: \.OffConditionMode)
            condSection(Lang.t("common.flash"), conds: \.BlinkConditions, mode: \.BlinkConditionMode)

            // 闪烁频率（秒/周期）：编辑即生效，下限 0.1（对应 C# freqBox.TextChanged）。
            HStack(alignment: .center, spacing: 8) {
                Text(Lang.t("nativePanel.blinkIntervalSecCycle"))
                    .font(.system(size: 12)).frame(width: 120, alignment: .leading)
                TextField("1", text: $blinkText).dialogFieldStyle().frame(width: 80)
                    .onChange(of: blinkText) { nv in
                        if let v = Double(nv.trimmingCharacters(in: .whitespaces)), v >= 0.1 {
                            light.BlinkIntervalSeconds = v
                        }
                    }
                Spacer(minLength: 0)
            }

            HStack {
                Spacer()
                Button(Lang.t("common.cancel")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(Lang.t("common.ok")) { confirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder private func fieldRow<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).font(.system(size: 12)).frame(width: 70, alignment: .leading)
            content()
        }
    }

    // MARK: - 条件区

    /// 一态的条件区（对应 C# `BuildCondSection`）：标题 + OR/AND 下拉 + 条件行列表 + 添加条件。
    @ViewBuilder private func condSection(
        _ title: String,
        conds condsKP: ReferenceWritableKeyPath<SignalLightItem, [SignalLightCondition]>,
        mode modeKP: ReferenceWritableKeyPath<SignalLightItem, String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .bold))
                Spacer(minLength: 0)
                Picker("", selection: Binding(
                    get: { light[keyPath: modeKP] },
                    set: { light[keyPath: modeKP] = $0; revision += 1 }
                )) {
                    Text(Lang.t("nativePanel.anyMatchTriggersOr")).tag("OR")
                    Text(Lang.t("nativePanel.allMustMatchAnd")).tag("AND")
                }
                .pickerStyle(.menu).frame(width: 150)
            }
            ForEach(Array(light[keyPath: condsKP].enumerated()), id: \.offset) { idx, c in
                condRow(c, conds: condsKP, idx: idx)
            }
            Button(Lang.t("nativePanel.addCondition")) {
                light[keyPath: condsKP].append(SignalLightCondition())
                revision += 1
            }
            .font(.system(size: 12))
        }
        .id(revision)
    }

    /// 单条件行（对应 C# row）：变量下拉 + 操作符下拉 + 值输入（操作符为「不存在」时禁用）+ ✕ 删除。
    @ViewBuilder private func condRow(
        _ c: SignalLightCondition,
        conds condsKP: ReferenceWritableKeyPath<SignalLightItem, [SignalLightCondition]>,
        idx: Int
    ) -> some View {
        HStack(spacing: 4) {
            Picker("", selection: Binding(
                get: { c.VarKey },
                set: { c.VarKey = $0; revision += 1 }
            )) {
                ForEach(varSources, id: \.key) { v in
                    Text("\(v.key)（\(v.label)）").tag(v.key)
                }
            }
            .pickerStyle(.menu).frame(width: 160)

            Picker("", selection: Binding(
                get: { c.Op },
                set: { c.Op = $0; revision += 1 }
            )) {
                Text(Lang.t("common.equals")).tag("EQ")
                Text(Lang.t("common.greater")).tag("GT")
                Text(Lang.t("common.less")).tag("LT")
                Text(Lang.t("common.missing")).tag("MISSING")
            }
            .pickerStyle(.menu).frame(width: 76)

            TextField("", text: Binding(get: { c.Value }, set: { c.Value = $0 }))
                .dialogFieldStyle().frame(width: 56)
                .disabled(c.Op.caseInsensitiveCompare("MISSING") == .orderedSame)

            Button {
                light[keyPath: condsKP].remove(at: idx)
                revision += 1
            } label: {
                Text("✕").font(.system(size: 10))
                    .foregroundStyle(ThemeManager.palette.textMuted.color)
            }
            .buttonStyle(.plain)
        }
    }

    private func confirm() {
        let size = Double(sizeText.trimmingCharacters(in: .whitespaces)) ?? 0
        model.updateSignalLight(light,
                                color: colorText.trimmingCharacters(in: .whitespaces),
                                size: size,
                                icon: iconText.trimmingCharacters(in: .whitespaces))
        onClose()
    }

    // MARK: - 变量候选收集

    /// 收集本地全部变量定义（面板数据项 + 后台数据项 + 变量集），按 VarKey 忽略大小写去重，
    /// 供条件行选择。对应 C# `CollectLightVarSources`：面板项要求 VarKey 非空且 RefVarKey 为空（引用项不算源）。
    private static func collectVarSources() -> [LightVarSource] {
        var seen = Set<String>()
        var order: [LightVarSource] = []
        func add(_ key: String?, _ label: String) {
            guard let k = key, !k.isEmpty else { return }
            if seen.insert(k.lowercased()).inserted {
                order.append(LightVarSource(key: k, label: label))
            }
        }
        func collectPanel(_ p: PanelItem) {
            for d in p.DashboardItems ?? [] where !(d.VarKey ?? "").isEmpty && (d.RefVarKey ?? "").isEmpty {
                add(d.VarKey, d.Label)
            }
            for cp in p.ChildPanels ?? [] { collectPanel(cp) }
        }
        if let mgr = AppContainer.shared.resolve(WindowConfigManager.self) {
            for w in mgr.Windows { for p in w.Panels { collectPanel(p) } }
            for d in mgr.BackgroundDashboardItems { add(d.VarKey, d.Label) }
        }
        if let vs = AppContainer.shared.resolve(VariableSetService.self) {
            for d in vs.getItems() { add(d.VarKey, d.Label) }
        }
        return order
    }
}

/// 条件下拉的一个变量候选：VarKey（写回条件）+ Label（展示）。
private struct LightVarSource {
    let key: String
    let label: String
}
