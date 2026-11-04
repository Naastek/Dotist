import AppKit
import DotistCore
import SwiftUI

/// Session-only optical experiments. Never read from or write to user settings.
struct GlassDebugParameters: Codable, Equatable {
    enum Style: String, Codable, CaseIterable { case regular, clear }
    enum Tint: String, Codable, CaseIterable {
        case none, light, medium, original
        // Scale the production tint, retaining its hue and light/dark adaptation.
        var scale: Double {
            switch self {
            case .none: 0
            case .light: 1.0 / 3
            case .medium: 2.0 / 3
            case .original: 1
            }
        }
    }
    enum Shape: String, Codable, CaseIterable { case continuous, capsule }
    enum Spacing: Int, Codable, CaseIterable { case zero = 0, small = 12, medium = 24, large = 48 }
    enum Radius: Int, Codable, CaseIterable { case small = 16, original = 24, large = 32 }

    var style: Style = .regular
    var interactive = true
    var tint: Tint = .original
    var container = false
    var spacing: Spacing = .medium
    var shape: Shape = .continuous
    var radius: Radius = .original
    var removeOverlay = true
    var hasShadow = true
    var effectID = false

    /// Stable, complete encoding suitable for pasting into a review or bug report.
    var combination: String {
        "glass-v1;style=\(style.rawValue);interactive=\(interactive);tint=\(tint.rawValue);container=\(container);spacing=\(spacing.rawValue);shape=\(shape.rawValue);radius=\(radius.rawValue);removeOverlay=\(removeOverlay);hasShadow=\(hasShadow);effectID=\(effectID)"
    }

    enum Preset: String, CaseIterable {
        case production = "生产", clear = "净透", soft = "柔和"
        var parameters: GlassDebugParameters {
            var value = GlassDebugParameters()
            switch self {
            case .production: break
            case .clear:
                value.style = .clear; value.tint = .none; value.container = true
                value.shape = .capsule; value.effectID = true
            case .soft:
                value.tint = .light; value.interactive = false
                value.container = true; value.spacing = .small
            }
            return value
        }
    }
}

private struct GlassDebugParametersKey: EnvironmentKey {
    static let defaultValue: GlassDebugParameters? = nil
}
extension EnvironmentValues {
    var glassDebugParameters: GlassDebugParameters? {
        get { self[GlassDebugParametersKey.self] }
        set { self[GlassDebugParametersKey.self] = newValue }
    }
}

@MainActor
final class GlassDebugState: ObservableObject {
    static let shared = GlassDebugState(environment: ProcessInfo.processInfo.environment)
    let enabled: Bool
    @Published var parameters = GlassDebugParameters() {
        didSet { applyShadows() }
    }
    private let panels = NSHashTable<NSPanel>.weakObjects()
    private var debugPanel: NSPanel?

    init(environment: [String: String]) { enabled = environment["DOTIST_GLASS_DEBUG"] == "1" }

    func register(_ panel: NSPanel) {
        guard enabled else { return }
        panels.add(panel)
        panel.hasShadow = parameters.hasShadow
        panel.invalidateShadow()
    }

    func unregister(_ panel: NSPanel) { panels.remove(panel) }

    private func applyShadows() {
        guard enabled else { return }
        for panel in panels.allObjects {
            panel.hasShadow = parameters.hasShadow
            panel.invalidateShadow()
        }
    }

    func showPanel(avoiding target: NSWindow) {
        guard enabled, debugPanel == nil else { return }
        let panel = GlassDebugPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 520),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Dotist · 玻璃调试"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        panel.contentView = NSHostingView(rootView: GlassDebugControls(state: self))
        if let area = (target.screen ?? NSScreen.main)?.visibleFrame {
            let size = panel.frame.size
            let origins = [
                NSPoint(x: area.minX + 12, y: area.maxY - size.height - 12),
                NSPoint(x: area.maxX - size.width - 12, y: area.maxY - size.height - 12),
                NSPoint(x: area.minX + 12, y: area.minY + 12),
                NSPoint(x: area.maxX - size.width - 12, y: area.minY + 12),
            ]
            let origin = origins.first { !NSRect(origin: $0, size: size).intersects(target.frame.insetBy(dx: -12, dy: -12)) } ?? origins[0]
            panel.setFrameOrigin(origin)
        }
        debugPanel = panel
        panel.orderFront(nil)
    }
}

private final class GlassDebugPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct GlassDebugControls: View {
    @ObservedObject var state: GlassDebugState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ForEach(GlassDebugParameters.Preset.allCases, id: \.self) { preset in
                        Button(preset.rawValue) { state.parameters = preset.parameters }
                    }
                }
                Picker("玻璃", selection: $state.parameters.style) {
                    Text("regular").tag(GlassDebugParameters.Style.regular)
                    Text("clear").tag(GlassDebugParameters.Style.clear)
                }.pickerStyle(.segmented)
                Toggle("Interactive", isOn: $state.parameters.interactive)
                Picker("Tint", selection: $state.parameters.tint) {
                    Text("无").tag(GlassDebugParameters.Tint.none)
                    Text("轻").tag(GlassDebugParameters.Tint.light)
                    Text("中").tag(GlassDebugParameters.Tint.medium)
                    Text("原值").tag(GlassDebugParameters.Tint.original)
                }.pickerStyle(.segmented)
                Toggle("共用 GlassEffectContainer", isOn: $state.parameters.container)
                Picker("Spacing", selection: $state.parameters.spacing) {
                    ForEach(GlassDebugParameters.Spacing.allCases, id: \.self) { Text("\($0.rawValue)").tag($0) }
                }.pickerStyle(.segmented).disabled(!state.parameters.container)
                Picker("形状", selection: $state.parameters.shape) {
                    Text("Continuous").tag(GlassDebugParameters.Shape.continuous)
                    Text("Capsule").tag(GlassDebugParameters.Shape.capsule)
                }.pickerStyle(.segmented)
                Picker("圆角", selection: $state.parameters.radius) {
                    ForEach(GlassDebugParameters.Radius.allCases, id: \.self) { Text("\($0.rawValue)").tag($0) }
                }.pickerStyle(.segmented).disabled(state.parameters.shape == .capsule)
                Toggle("去掉半透明叠层（生产已无）", isOn: $state.parameters.removeOverlay)
                Toggle("窗口 hasShadow", isOn: $state.parameters.hasShadow)
                Toggle("稳定 glassEffectID / 本地 namespace", isOn: $state.parameters.effectID)
                Text("圆点与横条为同一连续变宽表面，共用当前窗口的容器；不会跨 NSPanel 融合。Tint 无分组颜色时无效。辅助功能实心回退优先。关闭“去掉叠层”添加 12% paper 对照。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(state.parameters.combination).font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button("复制参数") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.parameters.combination, forType: .string)
                }
            }
            .controlSize(.small).padding(14).frame(width: 350)
        }.frame(width: 350, height: 520)
    }
}

/// Native-only experiments; the production effect and accessibility fill stay
/// in TransientGlassSurface's original branches.
struct GlassDebugOpticalSurface: View {
    let parameters: GlassDebugParameters
    let color: DotistGroupColor
    let scheme: ColorScheme
    @Namespace private var namespace

    private var glass: Glass {
        let tint = color == .none || parameters.tint == .none ? nil
            : DotistTheme.tint(color, scheme).opacity(parameters.tint.scale)
        return (parameters.style == .regular ? Glass.regular : Glass.clear)
            .tint(tint).interactive(parameters.interactive)
    }

    var body: some View {
        if parameters.container {
            GlassEffectContainer(spacing: CGFloat(parameters.spacing.rawValue)) { surface }
        } else { surface }
    }

    @ViewBuilder private var surface: some View {
        if parameters.shape == .capsule {
            effect(in: Capsule())
        } else {
            effect(in: RoundedRectangle(cornerRadius: CGFloat(parameters.radius.rawValue), style: .continuous))
        }
    }

    @ViewBuilder private func effect<S: Shape>(in shape: S) -> some View {
        if parameters.effectID {
            Color.clear.glassEffect(glass, in: shape)
                .glassEffectID("compact-surface", in: namespace)
                .overlay { if !parameters.removeOverlay { shape.fill(DotistDesign.paper.opacity(0.12)) } }
        } else {
            Color.clear.glassEffect(glass, in: shape)
                .overlay { if !parameters.removeOverlay { shape.fill(DotistDesign.paper.opacity(0.12)) } }
        }
    }
}
