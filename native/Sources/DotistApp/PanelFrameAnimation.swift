import AppKit
import CoreText
import DotistCore
import SwiftUI

/// The observed whole-rect animator produced integer frames with reversing
/// edges. Align edges at one shared progress before deriving the rect, keeping
/// those geometric invariants without assuming AppKit's internal rounding rule.
@MainActor
final class PanelFrameAnimation {
    private weak var window: NSWindow?
    private let start: NSRect
    private let target: NSRect
    private var previous: NSRect
    private var completion: (() -> Void)?
    let duration: TimeInterval
    private var task: Task<Void, Never>?
    private(set) var displayLink: CADisplayLink?
    private var began: TimeInterval = 0
    var isAnimating: Bool { task != nil || displayLink != nil }

    init(window: NSWindow, target: NSRect, duration: TimeInterval, completion: @escaping () -> Void) {
        self.window = window
        start = window.frame
        previous = window.frame
        self.target = target
        self.completion = completion
        self.duration = duration
    }
    isolated deinit { stopDrivers() }

    func startMotion() {
        guard completion != nil, !isAnimating else { return }
        if duration <= 0 { currentProgress = 1; return }
        guard let window else { cancel(); return }
        began = ProcessInfo.processInfo.systemUptime
        currentProgress = 0
        if QAPerf.enabled { QAPerf.mark("initial_frame") }
        if window.isVisible, window.screen != nil {
            guard let view = window.contentView else { currentProgress = 1; return }
            let link = view.displayLink(target: PanelFrameDisplayTarget(animation: self),
                                        selector: #selector(PanelFrameDisplayTarget.tick(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
            return
        }
        // Unordered/no-screen fixtures have no display callbacks. This bounded
        // fallback is never started alongside a visible window's display link.
        let began = self.began
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let duration = self?.duration else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                self?.advanceFrame()
                if elapsed >= duration { self?.task = nil; return }
                do { try await Task.sleep(for: .seconds(min(1.0 / 60, duration - elapsed))) }
                catch { return }
            }
        }
    }
    func cancel() {
        completion = nil
        stopDrivers()
    }
    private func stopDrivers() {
        task?.cancel(); task = nil
        displayLink?.invalidate(); displayLink = nil
    }
    fileprivate func advanceFrame() {
        guard completion != nil, duration > 0 else { return }
        if QAPerf.enabled { QAPerf.tickStart() }; defer { if QAPerf.enabled { QAPerf.tickEnd() } }
        currentProgress = Float(min(1, (ProcessInfo.processInfo.systemUptime - began) / duration))
    }
    var currentProgress: Float = 0 {
        didSet {
            guard completion != nil else { return }
            guard let window else { cancel(); return }
            let progress = CGFloat(currentProgress)
            let frame = Self.frame(from: start, to: target, progress: progress, previous: previous)
            if window.frame != frame { window.setFrame(frame, display: true) }
            previous = window.frame
            if progress >= 1 {
                let done = completion
                completion = nil
                stopDrivers()
                done?()
            }
        }
    }

    /// Invert the x coordinate of CA's easeInEaseOut cubic (not smoothstep or
    /// NSAnimation's differently defined easeInOut curve).
    static func easedProgress(_ time: CGFloat) -> CGFloat {
        if time <= 0 { return 0 }; if time >= 1 { return 1 }
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        var a: [Float] = [0, 0], b: [Float] = [0, 0]
        timing.getControlPoint(at: 1, values: &a)
        timing.getControlPoint(at: 2, values: &b)
        func cubic(_ u: CGFloat, _ p: Float, _ q: Float) -> CGFloat {
            3 * (1 - u) * (1 - u) * u * CGFloat(p) + 3 * (1 - u) * u * u * CGFloat(q) + u * u * u
        }
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<30 {
            let u = (low + high) / 2
            if cubic(u, a[0], b[0]) < time { low = u } else { high = u }
        }
        return cubic((low + high) / 2, a[1], b[1])
    }

    static func frame(from start: NSRect, to target: NSRect, progress: CGFloat, previous: NSRect) -> NSRect {
        if progress <= 0 { return start }; if progress >= 1 { return target }
        let p = easedProgress(progress)
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat,
                  _ previousSize: CGFloat) -> (CGFloat, CGFloat) {
            var low = (a + (c - a) * p).rounded(), high = (b + (d - b) * p).rounded()
            // Edge rounding can otherwise reverse size when parallel edges move
            // by different amounts. Advance the dominant edge to preserve size.
            let size = min(max(high - low, min(previousSize, d - c)), max(previousSize, d - c))
            if abs(c - a) >= abs(d - b) { low = high - size } else { high = low + size }
            return (low, high - low)
        }
        let x = axis(start.minX, start.maxX, target.minX, target.maxX, previous.width)
        let y = axis(start.minY, start.maxY, target.minY, target.maxY, previous.height)
        return NSRect(x: x.0, y: y.0, width: x.1, height: y.1)
    }
}

/// The link retains this target; its weak reference cannot retain the animation.
@MainActor
private final class PanelFrameDisplayTarget: NSObject {
    weak var animation: PanelFrameAnimation?
    init(animation: PanelFrameAnimation) { self.animation = animation }
    @objc func tick(_ link: CADisplayLink) {
        guard let animation else { link.invalidate(); return }
        if QAPerf.enabled { QAPerf.updatePeriod(link.targetTimestamp - link.timestamp) }; animation.advanceFrame()
    }
}

