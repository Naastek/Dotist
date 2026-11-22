import AppKit
import SwiftUI

/// Uses the approved panel shadow profile without painting underneath the glass.
@MainActor
final class ViewsWindowShadow {
    private static let margin: CGFloat = 48

    private weak var parent: NSWindow?
    private let panel: NSPanel
    private let shadow = CALayer()
    private let cutout = CAShapeLayer()
    private var observations: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private var enteringFullScreen = false

    init(parent: NSWindow) {
        self.parent = parent
        panel = ShadowPanel(contentRect: parent.frame.insetBy(dx: -Self.margin, dy: -Self.margin),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        if let content = panel.contentView {
            content.wantsLayer = true
            content.layer?.addSublayer(shadow)
            content.layer?.mask = cutout
        }
        cutout.fillRule = .evenOdd
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: -6)

        for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    switch note.name {
                    case NSWindow.willEnterFullScreenNotification:
                        self?.enteringFullScreen = true
                    case NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification:
                        self?.enteringFullScreen = false
                    default:
                        break
                    }
                    self?.synchronize()
                }
            })
        }
        appearanceObservation = parent.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.synchronize() }
        }
    }

    func synchronize() {
        guard let parent, parent.isVisible, !parent.isMiniaturized,
              !enteringFullScreen, !parent.styleMask.contains(.fullScreen) else {
            detach()
            return
        }
        let frame = parent.frame.insetBy(dx: -Self.margin, dy: -Self.margin)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        panel.level = parent.level
        let bounds = CGRect(origin: .zero, size: frame.size)
        let outline = RoundedRectangle(cornerRadius: DotistDesign.windowCornerRadius, style: .continuous)
            .path(in: bounds.insetBy(dx: Self.margin, dy: Self.margin)).cgPath
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addPath(outline)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cutout.frame = bounds
        cutout.path = mask
        shadow.frame = bounds
        shadow.shadowPath = outline
        shadow.shadowOpacity = parent.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.25 : 0.14
        CATransaction.commit()
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .below) }
    }

    func detach() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func didFailToEnterFullScreen() {
        enteringFullScreen = false
        synchronize()
    }

    deinit {
        observations.forEach(NotificationCenter.default.removeObserver)
        MainActor.assumeIsolated { detach() }
    }

    private final class ShadowPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }
}
