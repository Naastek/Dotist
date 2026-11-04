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
        isPlaying = true
        startClock?()
    }
    func sample() {
        guard isPlaying else { return }
        let now = time()
        values = entrance.values(ids: Self.ids, at: now)
        if values.allSatisfy({ $0 == 1 }) { stop() }
    }
    func stop() {
        stopClock?()
        isPlaying = false
        values = Array(repeating: 1, count: Self.ids.count)
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
            .background(SettingsWindowLifetime { playback.stop() })
            .onChange(of: reduceMotion) { _, _ in playback.stop() }
            .onDisappear { playback.stop() }
    }

    /// Same native display-link/CACurrentMediaTime domain as SideTabsController.
    /// There is one sampler, no interpolating SwiftUI animation or sleeping task.
    private struct PreviewClock: NSViewRepresentable {
        let playback: SettingsPreviewPlayback
        func makeNSView(context: Context) -> ClockView { ClockView(playback: playback) }
        func updateNSView(_ view: ClockView, context: Context) {}
        static func dismantleNSView(_ view: ClockView, coordinator: ()) { view.playback.stop() }
        final class ClockView: NSView {
            let playback: SettingsPreviewPlayback
            private var link: CADisplayLink?
            init(playback: SettingsPreviewPlayback) {
                self.playback = playback; super.init(frame: .zero)
                playback.startClock = { [weak self] in self?.start() }
                playback.stopClock = { [weak self] in self?.link?.invalidate(); self?.link = nil }
            }
            required init?(coder: NSCoder) { fatalError() }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            private func start() {
                link?.invalidate()
                link = displayLink(target: self, selector: #selector(tick(_:)))
                link?.add(to: .main, forMode: .common)
            }
            @objc private func tick(_ link: CADisplayLink) { playback.sample() }
        }
    }
}
