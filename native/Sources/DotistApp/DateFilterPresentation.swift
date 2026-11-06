import AppKit
import SwiftUI

/// Mask only the scrolling ink, before applying the glass shell. A clear band
/// keeps even antialiased glyph pixels away from the outline at either edge.
struct DateFilterEdgeMask: View {
    static let safeBand: CGFloat = 4
    static let fadeWidth: CGFloat = 20
    static let contentInset: CGFloat = safeBand + fadeWidth

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let clear = min(0.5, Self.safeBand / width)
            let solid = min(0.5, Self.contentInset / width)
            LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .clear, location: clear),
                .init(color: .black, location: solid), .init(color: .black, location: 1 - solid),
                .init(color: .clear, location: 1 - clear), .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        }
    }
}

/// Hover and date-control interaction hold the strip open. Only an exit (or
/// an opening without hover) starts the two-second idle lifetime.
@MainActor
final class DateFilterPresentation: ObservableObject {
    @Published private(set) var isOpen = false
    private var generation = UUID()
    private(set) var isHovered = false
    private(set) var controlsActive = false
    private let schedule: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    init(schedule: @escaping (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }) { self.schedule = schedule }

    func toggle() {
        if isOpen { dismiss() }
        else { isOpen = true; restartTimeout() }
    }
    func selected() {
        // Selection leaves the exit (or opening fallback) deadline untouched.
        // In particular it must never create a deadline while hovered.
    }
    func hoverChanged(_ inside: Bool) {
        guard isHovered != inside else { return }
        isHovered = inside
        if isOpen { restartTimeout() }
    }
    func dateControlsChanged(_ active: Bool) {
        guard controlsActive != active else { return }
        controlsActive = active
        if isOpen { restartTimeout() }
    }
    func contentClicked() {
        let request = generation
        // A local monitor runs before the native mouse-up target. Even with
        // Reduce Motion, let that event finish before changing its layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == request else { return }
            self.dismiss()
        }
    }
    private func restartTimeout() {
        generation = UUID()
        guard isOpen, !isHovered, !controlsActive else { return }
        let request = generation
        schedule(2) { [weak self] in
            guard let self, self.generation == request, !self.isHovered, !self.controlsActive else { return }
            self.dismiss()
        }
    }
    func dismiss() {
        generation = UUID()
        isOpen = false
        isHovered = false
    }
}

/// Native tracking also samples after layout: an expanding strip can arrive
/// under a stationary pointer without receiving a mouse-entered event.
struct DateFilterHoverObserver: NSViewRepresentable {
    let enabled: Bool
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> DateFilterHoverView {
        let view = DateFilterHoverView(); view.updateTrackingAreas(); return view
    }
    func updateNSView(_ view: DateFilterHoverView, context: Context) {
        view.enabled = enabled
        view.changed = changed
        view.sampleAfterLayout()
    }
    static func dismantleNSView(_ view: DateFilterHoverView, coordinator: ()) { view.stop() }
}

final class DateFilterHoverView: NSView {
    var enabled = false
    var changed: (Bool) -> Void = { _ in }
    // Per-instance seam for unordered native fixtures. Production reads only
    // this window's native pointer position; it never synthesizes input.
    var pointerInWindow: ((NSWindow) -> CGPoint?) = { window in
        window.isVisible ? window.mouseLocationOutsideOfEventStream : nil
    }
    private var tracking: NSTrackingArea?
    private var sampleGeneration = UUID()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); sampleAfterLayout() }
    override func layout() { super.layout(); sampleAfterLayout() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
        sampleAfterLayout()
    }
    override func mouseEntered(with event: NSEvent) { samplePointer() }
    override func mouseExited(with event: NSEvent) { publish(false) }
    func sampleAfterLayout() {
        let request = UUID(); sampleGeneration = request
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sampleGeneration == request else { return }
            self.samplePointer()
        }
    }
    func samplePointer() {
        guard enabled, !isHiddenOrHasHiddenAncestor, let window,
              let point = pointerInWindow(window) else { publish(false); return }
        let local = convert(point, from: nil)
        publish(bounds.contains(local) && visibleRect.contains(local))
    }
    private func publish(_ value: Bool) {
        changed(value)
    }
    func stop() {
        sampleGeneration = UUID()
        if let tracking { removeTrackingArea(tracking) }; tracking = nil
        publish(false)
    }
}

/// A permanent layout identity lets an opening reverse an unfinished return.
/// Its real height moves all following content; the window and composer stay put.
struct DateFilterPushdown<Content: View>: View {
    let isOpen: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motion: DateFilterSelectionMotion

    init(isOpen: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.isOpen = isOpen; self.content = content
        _motion = StateObject(wrappedValue: DateFilterSelectionMotion(selected: isOpen))
    }
    var body: some View {
        content()
            .frame(height: TaskDateFilterMetrics.rowHeight)
            .frame(height: TaskDateFilterMetrics.rowHeight * motion.fraction, alignment: .top)
            .clipped().opacity(Double(motion.fraction))
            .allowsHitTesting(isOpen).accessibilityHidden(!isOpen)
            .onAppear { motion.appear(selected: isOpen) }
            .onChange(of: isOpen) { _, value in motion.setSelected(value, reduceMotion: DateFilterSelectionMotion.environmentReduceMotion(reduceMotion)) }
            .onChange(of: reduceMotion) { _, _ in motion.setSelected(isOpen, reduceMotion: DateFilterSelectionMotion.environmentReduceMotion(reduceMotion)) }
            .onDisappear { motion.stop() }
    }
}

/// Observe clicks in only the below-filter content. A background with no hit
/// target leaves native controls, editors, scrolling, and task gestures in charge.
/// Dismiss on release so the original press cannot move its own target away.
struct DateFilterContentClickObserver: NSViewRepresentable {
    let enabled: Bool
    let dismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> DateFilterContentClickView {
        let view = DateFilterContentClickView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        ) { [weak view] event in
            view?.observe(event, from: event.window) ?? event
        }
        return view
    }
    func updateNSView(_ view: DateFilterContentClickView, context: Context) {
        view.enabled = enabled
        view.dismiss = dismiss
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DateFilterContentClickView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    static func dismantleNSView(_ view: DateFilterContentClickView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    final class Coordinator { var monitor: Any? }
}

final class DateFilterContentClickView: NSView {
    var enabled = false { didSet { if !enabled { pressedButton = nil } } }
    var dismiss: () -> Void = {}
    private var pressedButton: Int?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func observe(_ event: NSEvent, from eventWindow: NSWindow?) -> NSEvent {
        guard enabled, let window, eventWindow === window else { return event }
        let point = convert(event.locationInWindow, from: nil)
        let inside = !isHiddenOrHasHiddenAncestor && bounds.contains(point) && visibleRect.contains(point)
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            pressedButton = inside ? event.buttonNumber : nil
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let clicked = inside && pressedButton == event.buttonNumber
            pressedButton = nil
            if clicked { dismiss() }
        default: break
        }
        return event
    }
}

/// Use the same bounded ease-out timing as the toolbar. A run-loop clock keeps
/// native offscreen hosting and interrupted selections on the same drawing path.
@MainActor
final class DateFilterSelectionMotion: ObservableObject {
    static let duration = 0.16
    #if DEBUG
    struct Sample {
        let id: ObjectIdentifier
        let event: String
        let time: TimeInterval
        let fraction: CGFloat
        let target: CGFloat
    }
    static var trace: ((Sample) -> Void)?
    // Tests deliver the very same Timer callback explicitly instead of assuming
    // a wall-clock sleep delivered a logical-time sample. Release uses RunLoop.
    static var installTimer: ((Timer) -> Void)?
    static var testEnvironmentReduceMotion: Bool?
    private func record(_ event: String, target: CGFloat) {
        Self.trace?(Sample(id: ObjectIdentifier(self), event: event, time: LayoutMotionInputs.now,
                           fraction: fraction, target: target))
    }
    #endif
    @Published private(set) var fraction: CGFloat
    private var timer: Timer?

    init(selected: Bool) { fraction = selected ? 1 : 0 }
    static func environmentReduceMotion(_ value: Bool) -> Bool {
        #if DEBUG
        if let testEnvironmentReduceMotion { return testEnvironmentReduceMotion }
        #endif
        return value
    }
    func appear(selected: Bool) {
        stop()
        publish(selected ? 1 : 0)
        #if DEBUG
        record("appear", target: selected ? 1 : 0)
        #endif
    }
    static func animation(reduceMotion: Bool) -> Animation? {
        (environmentReduceMotion(reduceMotion) || LayoutMotionInputs.shouldReduceMotion(false)) ? nil : .easeOut(duration: duration)
    }
    func setSelected(_ selected: Bool, reduceMotion: Bool) {
        stop()
        let target: CGFloat = selected ? 1 : 0
        #if DEBUG
        record("select(environment=\(reduceMotion),system=\(LayoutMotionInputs.shouldReduceMotion(false)))", target: target)
        #endif
        guard !reduceMotion, !LayoutMotionInputs.shouldReduceMotion(false), fraction != target else {
            publish(target)
            #if DEBUG
            record("snap", target: target)
            #endif
            return
        }
        let start = fraction
        let began = LayoutMotionInputs.now
        let clock = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, max(0, (LayoutMotionInputs.now - began) / Self.duration))
                let eased = 1 - pow(1 - t, 3)
                self.publish(LayoutMotionInputs.shouldReduceMotion(false) ? target : start + (target - start) * eased)
                #if DEBUG
                self.record("tick(began=\(began))", target: target)
                #endif
                if t >= 1 || self.fraction == target { self.stop() }
            }
        }
        timer = clock
        #if DEBUG
        if let installTimer = Self.installTimer { installTimer(clock); return }
        #endif
        RunLoop.main.add(clock, forMode: .common)
    }
    private func publish(_ value: CGFloat) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) { fraction = value }
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
}

/// Calibrate the two resting fonts once. Scale both around their corrected ink
/// center and crossfade weight, rather than replacing font/baseline attributes
/// during a selection. The enclosing button owns the unchanged hit rectangle.
struct DateFilterInkLabel: View {
    let title: String
    let language: String
    let fraction: CGFloat
    let regularColor: Color
    let selectedColor: Color
    let regularOpacity: Double
    let feedbackAnimation: Animation?

    var body: some View {
        let size = 14 + 3 * fraction
        ZStack {
            OpticalText(title: title, size: 14, weight: .regular, language: language)
                .foregroundColor(regularColor).opacity(regularOpacity)
                .animation(feedbackAnimation, value: regularColor)
                .animation(feedbackAnimation, value: regularOpacity)
                .fixedSize()
                .scaleEffect(size / 14)
                .opacity(1 - fraction)
            OpticalText(title: title, size: 17, weight: .medium, language: language)
                .foregroundColor(selectedColor)
                .animation(feedbackAnimation, value: selectedColor)
                .fixedSize()
                .scaleEffect(size / 17)
                .opacity(fraction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
    }
}
