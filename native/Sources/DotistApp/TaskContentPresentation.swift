import AppKit
import Combine
import SwiftUI

/// The common destination of filter, calendar, side-tab, menu and navigation
/// changes. Keep presentation keyed to panel state rather than individual actions.
struct TaskContentSelection: Equatable {
    let scope: String
    let start: String?
    let end: String?
    let group: String?
    let tag: String?

    @MainActor init(state: TaskPanelState) {
        scope = state.scope; start = state.customStart; end = state.customEnd
        group = state.groupID; tag = state.activeTag
    }
}

/// Crossfade the previous viewport's pixels over the current, single live tree.
/// The bitmap has no task state, preferences, accessibility or input targets.
/// Keep the scroll view and its editor identities inside this permanent wrapper.
struct TaskContentPresentation<Content: View>: View {
    @ObservedObject var state: TaskPanelState
    let dragging: Bool
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var opacity = TaskContentTransitionOpacity()

    init(state: TaskPanelState, dragging: Bool, @ViewBuilder content: () -> Content) {
        self.state = state; self.dragging = dragging; self.content = content()
    }
    var body: some View {
        content
            .animation(nil, value: TaskContentSelection(state: state))
            // Below one 8-bit alpha step, but never remove the live native/AX tree.
            .opacity(max(0.001, opacity.value))
            .overlay {
                TaskContentTransitionOverlay(state: state, selection: TaskContentSelection(state: state), disabled: reduceMotion || dragging, opacity: opacity)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .onChange(of: TaskContentSelection(state: state)) { _, _ in
                if opacity.hasSnapshot && !reduceMotion && !dragging && !LayoutMotionInputs.shouldReduceMotion(false) { opacity.set(0) }
                else { opacity.set(1) }
            }
            .onChange(of: reduceMotion || dragging) { _, disabled in if disabled { opacity.set(1) } }
            .onDisappear { opacity.set(1) }
    }
}

@MainActor
final class TaskContentTransitionOpacity: ObservableObject {
    @Published private(set) var value: Double = 1
    var hasSnapshot = false
    func set(_ next: Double) {
        guard value != next else { return }
        var transaction = Transaction(); transaction.animation = nil
        withTransaction(transaction) { value = next }
    }
}

private struct TaskContentTransitionOverlay: NSViewRepresentable {
    let state: TaskPanelState
    let selection: TaskContentSelection
    let disabled: Bool
    let opacity: TaskContentTransitionOpacity
    func makeNSView(context: Context) -> TaskContentTransitionView { TaskContentTransitionView() }
    func updateNSView(_ view: TaskContentTransitionView, context: Context) {
        view.opacity = opacity
        view.update(state: state, selection: selection, disabled: disabled)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TaskContentTransitionView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    static func dismantleNSView(_ view: TaskContentTransitionView, coordinator: ()) { view.stop(publishOpacity: false) }
}

/// Capture synchronously from @Published's will-set delivery, while the old
/// selection is still drawn. On a rapid change this captures the *composite*
/// currently on screen, so another fade starts there without a stale-result queue.
/// Only a viewport-sized bitmap is retained, and it is released at completion.
final class TaskContentTransitionView: NSView {
    static let duration: TimeInterval = 0.18
    private weak var state: TaskPanelState?
    private var subscriptions: Set<AnyCancellable> = []
    private var selection: TaskContentSelection?
    private var snapshot: NSImage?
    private var timer: Timer?
    private var pending = false
    private var generation = UUID()
    private var disabled = false
    weak var opacity: TaskContentTransitionOpacity?
    private(set) var outgoingOpacity: CGFloat = 0
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func update(state: TaskPanelState, selection next: TaskContentSelection, disabled: Bool) {
        self.disabled = disabled
        if self.state !== state {
            stop(publishOpacity: false)
            self.state = state
            subscriptions.removeAll()
            // Each publisher delivers before its stored property changes. Data
            // edits and row selection are deliberately outside this subscription.
            state.$scope.dropFirst().sink { [weak self, weak state] value in
                if value != state?.scope { self?.capturePresentedViewport() }
            }.store(in: &subscriptions)
            state.$groupID.dropFirst().sink { [weak self, weak state] value in
                if value != state?.groupID { self?.capturePresentedViewport() }
            }.store(in: &subscriptions)
            state.$customStart.dropFirst().sink { [weak self, weak state] value in
                if value != state?.customStart { self?.capturePresentedViewport() }
            }.store(in: &subscriptions)
            state.$customEnd.dropFirst().sink { [weak self, weak state] value in
                if value != state?.customEnd { self?.capturePresentedViewport() }
            }.store(in: &subscriptions)
            state.$activeTag.dropFirst().sink { [weak self, weak state] value in
                if value != state?.activeTag { self?.capturePresentedViewport() }
            }.store(in: &subscriptions)
        }
        if disabled || LayoutMotionInputs.shouldReduceMotion(false) { stop(publishOpacity: false) }
        else if next != selection && pending { begin() }
        selection = next
    }

    private func capturePresentedViewport() {
        guard !disabled, !LayoutMotionInputs.shouldReduceMotion(false),
              bounds.width > 0, bounds.height > 0 else { return }
        var ancestor = superview
        var captureRoot: NSView?
        while let view = ancestor {
            if view.layer != nil { captureRoot = view }
            ancestor = view.superview
        }
        guard let root = captureRoot else { return }
        // Several fields can change in one transaction. The first capture is
        // already the visible composite; keep it until that update is presented.
        guard !pending else { return }
        let rect = convert(bounds, to: root)
        guard let layer = root.layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        guard let context = CGContext(data: nil, width: Int(ceil(rect.width * scale)),
            height: Int(ceil(rect.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        (layer.presentation() ?? layer).render(in: context)
        guard let pixels = context.makeImage() else { return }
        let image = NSImage(cgImage: pixels, size: bounds.size)
        timer?.invalidate(); timer = nil
        snapshot = image
        opacity?.hasSnapshot = true
        outgoingOpacity = 1
        pending = true
        needsDisplay = true
        // A rapid out-and-back can leave the representable's final selection
        // equal to its old value, so SwiftUI may skip updateNSView entirely.
        // Always retire those pixels after this synchronous state transaction.
        generation = UUID()
        let request = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == request, self.snapshot != nil else { return }
            if self.disabled || LayoutMotionInputs.shouldReduceMotion(false) { self.stop() }
            else {
                // Publishing during @Published's will-set delivery can make
                // SwiftUI consume the query invalidation before the new value
                // is stored. Change live opacity only after that transaction.
                self.opacity?.set(Double(1 - self.outgoingOpacity))
                if self.pending { self.begin() }
            }
        }
    }

    private func begin() {
        pending = false
        let began = LayoutMotionInputs.now
        timer?.invalidate()
        let clock = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, max(0, (LayoutMotionInputs.now - began) / Self.duration))
                if t >= 1 || LayoutMotionInputs.shouldReduceMotion(false) { self.stop(); return }
                // Bounded smoothstep: both ends settle without spring overshoot.
                self.outgoingOpacity = 1 - t * t * (3 - 2 * t)
                self.opacity?.set(Double(1 - self.outgoingOpacity))
                self.needsDisplay = true
            }
        }
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        snapshot?.draw(in: bounds, from: .zero, operation: .sourceOver,
                       fraction: outgoingOpacity, respectFlipped: true, hints: nil)
    }
    func stop(publishOpacity: Bool = true) {
        generation = UUID()
        timer?.invalidate(); timer = nil
        snapshot = nil; pending = false; outgoingOpacity = 0
        opacity?.hasSnapshot = false
        if publishOpacity { opacity?.set(1) }
        needsDisplay = true
    }
    deinit { timer?.invalidate() }
}
