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
    private let applyFrame: ((NSRect) -> Void)?
    private let settleBeforeResize: Bool
    private var waitingToResize = false
    private var previous: NSRect
    private var completion: (() -> Void)?
    let duration: TimeInterval
    private var task: Task<Void, Never>?
    private(set) var displayLink: CADisplayLink?
    private var began: TimeInterval = 0
    var isAnimating: Bool { task != nil || displayLink != nil }

    init(window: NSWindow, target: NSRect, duration: TimeInterval,
         from initialFrame: NSRect? = nil, settleBeforeResize: Bool = false,
         applyFrame: ((NSRect) -> Void)? = nil, completion: @escaping () -> Void) {
        self.window = window
        start = initialFrame ?? window.frame
        previous = start
        self.applyFrame = applyFrame
        self.settleBeforeResize = settleBeforeResize
        self.target = target
        self.completion = completion
        self.duration = duration
    }
    isolated deinit { stopDrivers() }

    func startMotion(beganAt: CFTimeInterval? = nil, initialLead: TimeInterval = 0) {
        guard completion != nil, !isAnimating else { return }
        if duration <= 0 { currentProgress = 1; return }
        guard let window else { cancel(); return }
        began = beganAt ?? CACurrentMediaTime()
        if beganAt != nil {
            advanceFrame(at: max(CACurrentMediaTime(), began + initialLead))
            guard completion != nil else { return }
        }
        if window.isVisible, window.screen != nil {
            guard let view = window.contentView else { currentProgress = 1; return }
            let link = view.displayLink(target: PanelFrameDisplayTarget(animation: self),
                                        selector: #selector(PanelFrameDisplayTarget.tick(_:)))
            #if DOTIST_BENCH
            if BenchPerf.enabled { BenchPerf.driverStarted(kind: target.height < start.height ? "collapse" : "expand", period: link.duration) }
            #endif
            displayLink = link
            link.add(to: .main, forMode: .common)
            // The view's clock can pause if its window is ordered out mid-morph.
            if applyFrame != nil {
                task = Task { [weak self, duration] in
                    do { try await Task.sleep(for: .seconds(duration + 0.05)) }
                    catch { return }
                    guard let self else { return }
                    self.waitingToResize = false
                    self.currentProgress = 1
                }
            }
            return
        }
        // Unordered/no-screen fixtures have no display callbacks. This bounded
        // fallback is never started alongside a visible window's display link.
        let began = self.began
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let duration = self?.duration else { return }
                let elapsed = CACurrentMediaTime() - began
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
    fileprivate func advanceFrame(at time: CFTimeInterval = CACurrentMediaTime(), displayPeriod: CFTimeInterval = 0) {
        guard completion != nil, duration > 0 else { return }
        if waitingToResize {
            finish()
            return
        }
        if settleBeforeResize, displayPeriod > 0, time + displayPeriod >= began + duration {
            // Give AppKit a display interval with the final silhouette in the
            // existing backing surface before resizing the native window.
            waitingToResize = true
            currentProgress = 1
            return
        }
        let progress = Float(min(1, max(0, (time - began) / duration)))
        if progress > currentProgress { currentProgress = progress }
    }

    private func finish() {
        let done = completion
        completion = nil
        stopDrivers()
        #if DOTIST_BENCH
        if BenchPerf.enabled { BenchPerf.end() }
        #endif
        done?()
    }
    var currentProgress: Float = 0 {
        didSet {
            guard completion != nil else { return }
            guard let window else { cancel(); return }
            let progress = CGFloat(currentProgress)
            if let applyFrame {
                let frame = surfaceFrame(progress: progress)
                if frame != previous { applyFrame(frame) }
                previous = frame
            } else {
                applyWindowFrame(window, progress: progress)
            }
            if progress >= 1 && !waitingToResize { finish() }
        }
    }

    private func surfaceFrame(progress: CGFloat) -> NSRect {
        if progress <= 0 { return start }
        if progress >= 1 { return target }
        // The local surface can move by subpixels. Only AppKit's window
        // frame needs integer edge quantization.
        let eased = Self.easedProgress(progress)
        // A slight head start makes the small opening steps visible. Blend it
        // away before the midpoint so the established settling curve holds.
        let lead = target.height > start.height ? 0.25 * max(0, 1 - 2 * progress) : 0
        let amount = eased + lead * (progress - eased)
        return NSRect(x: start.minX + (target.minX - start.minX) * amount,
                      y: start.minY + (target.minY - start.minY) * amount,
                      width: start.width + (target.width - start.width) * amount,
                      height: start.height + (target.height - start.height) * amount)
    }

    private func applyWindowFrame(_ window: NSWindow, progress: CGFloat) {
        let frame = Self.frame(from: start, to: target, progress: progress, previous: previous)
        if window.frame != frame {
            #if DOTIST_BENCH
            let setStart = CACurrentMediaTime()
            BenchPerf.count(.panelSetFrame)
            #endif
            window.setFrame(frame, display: progress >= 1 || displayLink == nil)
            #if DOTIST_BENCH
            BenchPerf.recordSetFrameMs((CACurrentMediaTime() - setStart) * 1000)
            #endif
        } else {
            #if DOTIST_BENCH
            BenchPerf.count(.panelSetFrameSkipped)
            #endif
        }
        previous = window.frame
    }

    private static let easeInEaseOutPoints: (CGFloat, CGFloat, CGFloat, CGFloat) = {
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        var a: [Float] = [0, 0], b: [Float] = [0, 0]
        timing.getControlPoint(at: 1, values: &a)
        timing.getControlPoint(at: 2, values: &b)
        return (CGFloat(a[0]), CGFloat(a[1]), CGFloat(b[0]), CGFloat(b[1]))
    }()

    /// Invert the x coordinate of CA's easeInEaseOut cubic (not smoothstep or
    /// NSAnimation's differently defined easeInOut curve).
    static func easedProgress(_ time: CGFloat) -> CGFloat {
        if time <= 0 { return 0 }; if time >= 1 { return 1 }
        let (ax, ay, bx, by) = easeInEaseOutPoints
        func cubic(_ u: CGFloat, _ p: CGFloat, _ q: CGFloat) -> CGFloat {
            3 * (1 - u) * (1 - u) * u * p + 3 * (1 - u) * u * u * q + u * u * u
        }
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<30 {
            let u = (low + high) / 2
            if cubic(u, ax, bx) < time { low = u } else { high = u }
        }
        return cubic((low + high) / 2, ay, by)
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
        #if DOTIST_BENCH
        if BenchPerf.enabled { BenchPerf.tickStart(linkTimestamp: link.timestamp, linkTargetTimestamp: link.targetTimestamp) }
        #endif
        animation.advanceFrame(at: max(CACurrentMediaTime(), link.targetTimestamp),
                               displayPeriod: link.targetTimestamp - link.timestamp)
        #if DOTIST_BENCH
        if BenchPerf.enabled { BenchPerf.tickEnd() }
        #endif
    }
}

