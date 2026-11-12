import AppKit
import CoreText
import DotistCore
import SwiftUI

/// Refresh AppKit's alpha-derived shadow after SwiftUI commits and throughout
/// its longest surface/frame animation. This view draws no pixels and owns no window.
struct ShadowTrackedContent<Content: View>: View {
    @ObservedObject var model: AppModel
    let content: Content
    var body: some View {
        content.background(WindowShadowInvalidation(settings: model.settings))
    }
}

struct WindowShadowInvalidation: NSViewRepresentable {
    var settings: DotistSettings? = nil
    func makeNSView(context: Context) -> ShadowInvalidationView { ShadowInvalidationView() }
    func updateNSView(_ view: ShadowInvalidationView, context: Context) { view.refresh() }
    static func dismantleNSView(_ view: ShadowInvalidationView, coordinator: ()) { view.stop() }
}

final class ShadowInvalidationView: NSView {
    private var timer: Timer?
    private var refreshDisplayLink: CADisplayLink?
    var hasRefreshDriver: Bool { timer != nil || refreshDisplayLink != nil }
    private var deadline = Date.distantPast
    private var closed = false
    private var observations: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        closed = false
        guard let window else { return }
        for name in [NSWindow.didResizeNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed = true; self?.stopFrames() }
        })
        observations.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Settings/search windows are retained and may reopen after close.
                self?.closed = false
                self?.refresh()
            }
        })
        refresh()
    }

    func refresh() {
        guard !closed, let window, window.hasShadow else { return }
        window.invalidateShadow()
        deadline = Date().addingTimeInterval(0.45)
        guard timer == nil, refreshDisplayLink == nil else { return }
        if window.isVisible, window.screen != nil {
            // Follow the display cadence (including ProMotion), rather than
            // sampling a 120 Hz glass animation with a fixed 60 Hz timer.
            let link = displayLink(target: ShadowRefreshTarget(view: self), selector: #selector(ShadowRefreshTarget.tick(_:)))
            refreshDisplayLink = link
            link.add(to: .main, forMode: .common)
            return
        }
        // Offscreen test hosts have no display ticks; still refresh their commits.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.refreshFrame()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    fileprivate func refreshFrame() {
        window?.invalidateShadow()
        if window == nil || Date() >= deadline {
            timer?.invalidate(); timer = nil
            refreshDisplayLink?.invalidate(); refreshDisplayLink = nil
        }
    }

    private func stopFrames() {
        timer?.invalidate(); timer = nil
        refreshDisplayLink?.invalidate(); refreshDisplayLink = nil
    }

    func stop() {
        stopFrames()
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
    }
    isolated deinit { stop() }
}

/// CADisplayLink retains its target. A weak forwarding target lets removing a
/// hosting view release its refresh driver without waiting for a final frame.
private final class ShadowRefreshTarget: NSObject {
    weak var view: ShadowInvalidationView?
    init(view: ShadowInvalidationView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        guard let view else { link.invalidate(); return }
        view.refreshFrame()
    }
}

