import AppKit
import SwiftUI
import SideDeskCore
import SideDeskServices

/// 信号灯看板运行时（对应 C# `SignalLightBoardNode` 的定时器/订阅段，生命周期自包含）：
/// 订阅 `DataPollingService.DataUpdated`——变量一变立即重算；1s 监控定时器兜底（变量缺失/未被轮询
/// 等场景也能及时激活状态）；仅在有灯处于闪烁态时启 200ms 相位定时器、无闪烁即停（与 C# 同）。
/// 求值本身是纯函数 `SignalLightEvaluator`（Core），这里只负责时钟、订阅与按需重算。
@MainActor
final class SignalLightTicker: ObservableObject {

    /// 每盏灯的当前状态（与构造时传入的 lights 同序）。视图读它渲染亮灭与闪烁相位。
    @Published private(set) var states: [SignalLightEvaluator.State] = []

    private let lights: [SignalLightItem]
    private let valueProvider: SignalLightEvaluator.ValueProvider
    private var monitorTimer: Timer?
    private var blinkTimer: Timer?
    private var observerToken: UUID?
    private weak var polling: DataPollingService?

    init(lights: [SignalLightItem]) {
        self.lights = lights
        let polling = AppContainer.shared.resolve(DataPollingService.self)
        self.polling = polling
        self.valueProvider = { [weak polling] key in polling?.findItem(byVarKey: key)?.Value }
        recompute()
        startMonitoring()
    }

    /// 视图销毁时释放定时器与订阅（对应 C# `Unloaded` 里的 Teardown）。
    func teardown() {
        monitorTimer?.invalidate(); monitorTimer = nil
        blinkTimer?.invalidate(); blinkTimer = nil
        if let token = observerToken {
            polling?.removeDataUpdatedObserver(token)
            observerToken = nil
        }
    }

    // MARK: - 重算

    /// 重算全部灯的状态；结果有变才发布（避免每秒无谓重绘），并按需启停闪烁定时器。
    private func recompute() {
        let nowMs = Self.nowMs()
        let next = lights.map { SignalLightEvaluator.state(for: $0, value: valueProvider, nowMs: nowMs) }
        if next != states { states = next }
        syncBlinkTimer(anyBlinking: next.contains { $0.blinking })
    }

    /// 闪烁定时器按需启停（对应 `RefreshVisuals` 尾部的 anyBlink 分支）。
    private func syncBlinkTimer(anyBlinking: Bool) {
        if anyBlinking, blinkTimer == nil {
            let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.recompute() }
            }
            RunLoop.main.add(t, forMode: .common)
            blinkTimer = t
        } else if !anyBlinking, blinkTimer != nil {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
    }

    private func startMonitoring() {
        observerToken = polling?.addDataUpdatedObserver { [weak self] _, _ in
            Task { @MainActor in self?.recompute() }
        }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        RunLoop.main.add(t, forMode: .common)
        monitorTimer = t
    }

    /// 单调毫秒时钟（对应 C# `Environment.TickCount64`）：取系统启动时长，闪烁相位只取模、不要求绝对基准。
    static func nowMs() -> Int64 {
        Int64((ProcessInfo.processInfo.systemUptime * 1000).rounded())
    }
}

/// 信号灯看板视图（对应 C# `SignalLightBoardNode` 的渲染段 + `NativeModePanel.BuildSignalLightWidget`）：
/// 布局/对齐/形状/右键菜单照旧，亮灭改由 `SignalLightTicker` 的三态状态机驱动——
/// 点亮用原色 + 辉光、熄灭走「去白分量压暗到 ≈130」算法（对应 `ApplyLightVisual`），不再用透明度区分。
struct SignalLightBoardView: View {

    let panel: PanelItem
    let model: BarCardsModel
    @StateObject private var ticker: SignalLightTicker

    init(panel: PanelItem, model: BarCardsModel) {
        self.panel = panel
        self.model = model
        _ticker = StateObject(wrappedValue: SignalLightTicker(lights: panel.SignalLights ?? []))
    }

    var body: some View {
        let lights = panel.SignalLights ?? []
        Group {
            if lights.isEmpty {
                // 空态可点击直接打开设置弹窗（与其它卡片的空态添加入径一致）。
                Button {
                    SignalLightSettingsDialog.present(panel: panel, model: model)
                } label: {
                    Text(Lang.t("nativePanel.setSignalLight"))
                        .font(cardFont(12))
                        .foregroundStyle(ThemeManager.palette.textMuted.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                let layout = panel.SignalLightVertical
                    ? AnyLayout(VStackLayout(spacing: panel.SignalLightSpacing))
                    : AnyLayout(HStackLayout(spacing: panel.SignalLightSpacing))
                layout {
                    ForEach(Array(lights.enumerated()), id: \.element.Id) { index, light in
                        lightView(light, state: state(at: index, fallbackFor: light))
                    }
                }
                .frame(maxWidth: .infinity, alignment: signalAlignment)
            }
        }
        .onDisappear { ticker.teardown() }
    }

    /// 取下标状态；灯列表与状态数组短暂不同步时回落手动 IsOn（非闪烁）。
    private func state(at index: Int, fallbackFor light: SignalLightItem) -> SignalLightEvaluator.State {
        ticker.states.indices.contains(index)
            ? ticker.states[index]
            : SignalLightEvaluator.State(lit: light.IsOn, blinking: false)
    }

    /// 对齐口径对应 C# `SignalLightBoardNode.Create` 的 `align switch`（Left/Right/其余居中）。
    private var signalAlignment: Alignment {
        switch panel.SignalLightAlignment {
        case "Left": return .leading
        case "Right": return .trailing
        default: return .center
        }
    }

    /// 单盏灯：图标（可选，置于灯上方，字号 = size*0.5，对应 C# `RenderLights`）+ 形状（按 `LightStyle` 三选一）。
    /// 右键菜单对应 C# `WireSignalLight` 的 `lightMenu`：编辑（单灯详情）/ 删除 / 设置信号灯（管理弹窗）。
    @ViewBuilder private func lightView(_ light: SignalLightItem, state: SignalLightEvaluator.State) -> some View {
        let size = max(4, light.Size)
        let litColor = hexColor(light.Color) ?? ThemeManager.palette.textMuted.color
        VStack(spacing: 2) {
            if let icon = light.Icon, !icon.isEmpty {
                Text(icon).font(.system(size: size * 0.5))
            }
            lightShape(light, size: size)
                .fill(state.lit ? litColor : dimmedColor(light))
                .frame(width: size, height: size)
                // 点亮辉光对应 C# DropShadowEffect（Color=原色、ShadowDepth=0、Opacity=0.7、BlurRadius=size*0.4）
                .shadow(color: state.lit ? litColor.opacity(0.7) : .clear, radius: size * 0.4)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(Lang.t("common.edit")) {
                SignalLightDetailDialog.present(model: model, light: light)
            }
            Button(Lang.t("common.delete"), role: .destructive) {
                model.removeSignalLight(panel, light)
            }
            Divider()
            Button(Lang.t("nativePanel.setSignalLight")) {
                SignalLightSettingsDialog.present(panel: panel, model: model)
            }
        }
    }

    /// 熄灭色（对应 `ApplyLightVisual` 的 else 分支）：去白分量再压暗到最大通道 ≈130；
    /// 解析失败回落主题的次要文字色。
    private func dimmedColor(_ light: SignalLightItem) -> Color {
        guard let t = ThemeColor.parse(light.Color) else { return ThemeManager.palette.textMuted.color }
        let d = SignalLightEvaluator.dimmedRGB(r: Int(t.r), g: Int(t.g), b: Int(t.b))
        return Color(.sRGB, red: Double(d.r) / 255, green: Double(d.g) / 255, blue: Double(d.b) / 255)
    }

    /// 形状分派对应 C# `CreateLightShape`：Square=圆角矩形(0.15)、Pixel=直角矩形、其余=圆。
    private func lightShape(_ light: SignalLightItem, size: Double) -> AnyShape {
        switch light.LightStyle {
        case "Square": return AnyShape(RoundedRectangle(cornerRadius: size * 0.15))
        case "Pixel":  return AnyShape(Rectangle())
        default:       return AnyShape(Circle())
        }
    }
}
