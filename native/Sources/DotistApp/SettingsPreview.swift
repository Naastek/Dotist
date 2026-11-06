import AppKit
import DotistCore
import QuartzCore
import SwiftUI

/// A fixture only: production tracks and geometry, with no AppModel or settings writes.
@MainActor
final class SettingsPreviewPlayback: ObservableObject {
    static let ids = ["preview-all", "preview-work", "preview-notes"]
    @Published private(set) var values: [CGFloat] = [1, 1, 1]
    @Published private(set) var isPlaying = false
    private var entrance = SideTabEntrance()
    private let time: () -> TimeInterval
    private var samplingEnabled = false
    private var resetGeneration = UUID()
    private var clockOwner: UUID?
    var startClock: (() -> Void)?
    var stopClock: (() -> Void)?

    init(time: @escaping () -> TimeInterval = { CACurrentMediaTime() }) { self.time = time }
    func play(reduceMotion: Bool) {
        stop()
        guard !reduceMotion else { return }
        let started = time()
        entrance = SideTabEntrance()
        entrance.update(ids: Self.ids, visible: true, at: started, reduceMotion: false)
        values = entrance.values(ids: Self.ids, at: started)
        samplingEnabled = true
        isPlaying = true
        startClock?()
    }
    func sample() {
        guard samplingEnabled, isPlaying else { return }
        let now = time()
        values = entrance.values(ids: Self.ids, at: now)
        if values.allSatisfy({ $0 == 1 }) { stop() }
    }
    func stop() {
        resetGeneration = UUID()
        samplingEnabled = false
        stopClock?()
        resetPresentation()
    }
    private func resetPresentation() {
        isPlaying = false
        values = Array(repeating: 1, count: Self.ids.count)
    }

    /// Graph destruction must release native resources immediately without
    /// sending objectWillChange back into the graph being invalidated.
    func suspend() {
        samplingEnabled = false
        stopClock?()
        let request = UUID()
        resetGeneration = request
        DispatchQueue.main.async { [weak self] in
            guard let self, self.resetGeneration == request else { return }
            self.resetPresentation()
        }
    }
    func attachClock(owner: UUID, start: @escaping () -> Void, stop: @escaping () -> Void) {
        if clockOwner != nil { suspend() }
        clockOwner = owner
        startClock = start; stopClock = stop
    }
    func detachClock(owner: UUID) {
        guard clockOwner == owner else { return }
        suspend()
        clockOwner = nil
        startClock = nil; stopClock = nil
    }
    func suspendClock(owner: UUID) {
        if clockOwner == owner { suspend() }
    }
}

/// The fixture uses the live renderer, attachment geometry, selected ear and track samples.
struct SettingsSideTabSample: View {
    let values: [CGFloat]
    let language: String
    var body: some View {
        let panel = CGRect(x: 24, y: 0, width: 84, height: 164)
        let sample = SideTabGeometry.snapshot(panel: panel, fullWidths: [84, 84, 84], progress: 0,
            inward: false, selectedIndex: 0, entrance: values)
        let rows = SettingsPreviewPlayback.ids.enumerated().map { index, id in
            SideTabLayout(id: id, groupID: id, name: "", rect: sample.tabs[index], fullWidth: 84,
                          dragged: false, opacity: sample.opacities[index], interactive: false)
        }
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(DotistDesign.surface)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DotistDesign.rule, lineWidth: 0.5))
                .frame(width: panel.width, height: panel.height).offset(x: panel.minX)
            SideTabsCanvas(rows: rows, size: CGSize(width: 108, height: 164), language: language,
                selectedGroupID: SettingsPreviewPlayback.ids[0], hovered: nil, inward: false,
                textOpacity: 0, opacity: 85, color: { _ in .none })
        }.frame(width: 108, height: 164).accessibilityHidden(true)
    }
}

struct SettingsSideTabPreview: View {
    let language: String
    let text: (String) -> String
    let emphasized: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var playback: SettingsPreviewPlayback
    init(language: String, text: @escaping (String) -> String, emphasized: Bool = false, playback: SettingsPreviewPlayback? = nil) {
        self.language = language; self.text = text; self.emphasized = emphasized
        _playback = StateObject(wrappedValue: playback ?? SettingsPreviewPlayback())
    }
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            SettingsSideTabSample(values: playback.values, language: language)
            VStack(alignment: .leading, spacing: 10) {
                Text(text("便签入场预览")).font(DotistDesign.font(13, weight: .semibold, language: language))
                    .foregroundStyle(emphasized ? DotistDesign.accent : DotistDesign.ink)
                Text(text(reduceMotion ? "已降低动态效果，显示静态终态。" : "仅演示便签依次出现，不影响任务或设置。"))
                    .font(DotistDesign.font(12, language: language)).foregroundStyle(DotistDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(text("播放便签动画")) { playback.play(reduceMotion: reduceMotion) }
                    .disabled(reduceMotion).modifier(DotistFocusRing())
                    .accessibilityIdentifier("settings-preview-play")
                    .accessibilityValue(text(playback.isPlaying ? "正在播放" : "预览就绪"))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(14)
            .background(PreviewClock(playback: playback))
            .background(SettingsWindowLifetime { playback.suspend() })
            .onChange(of: reduceMotion) { _, _ in playback.stop() }
            .onDisappear { playback.suspend() }
    }

    /// Same native display-link/CACurrentMediaTime domain as SideTabsController.
    /// There is one sampler, no interpolating SwiftUI animation or sleeping task.
    struct PreviewClock: NSViewRepresentable {
        let playback: SettingsPreviewPlayback
        func makeNSView(context: Context) -> ClockView { ClockView(playback: playback) }
        func updateNSView(_ view: ClockView, context: Context) {}
        static func dismantleNSView(_ view: ClockView, coordinator: ()) {
            view.invalidate()
            view.playback.detachClock(owner: view.owner)
        }
        final class ClockView: NSView {
            let playback: SettingsPreviewPlayback
            let owner = UUID()
            private(set) var link: CADisplayLink?
            init(playback: SettingsPreviewPlayback) {
                self.playback = playback; super.init(frame: .zero)
                playback.attachClock(owner: owner, start: { [weak self] in self?.start() },
                                     stop: { [weak self] in self?.invalidate() })
            }
            required init?(coder: NSCoder) { fatalError() }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if window == nil { playback.suspendClock(owner: owner) }
            }
            func invalidate() { link?.invalidate(); link = nil }
            private func start() {
                invalidate()
                link = displayLink(target: self, selector: #selector(tick(_:)))
                link?.add(to: .main, forMode: .common)
            }
            @objc func tick(_ source: CADisplayLink) {
                guard source === link else { return }
                playback.sample()
            }
        }
    }
}
