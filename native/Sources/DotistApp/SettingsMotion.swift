import AppKit
import SwiftUI

/// These transitions belong to their local feedback surfaces, never the form root.
struct SettingsMotion {
    let reduceMotion: Bool
    var hover: Animation? { reduceMotion ? nil : .easeOut(duration: 0.1) }
    var selection: Animation? { reduceMotion ? nil : .easeOut(duration: 0.12) }
    var search: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }
    var toolbar: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.18) }
    static let searchHold: Duration = .milliseconds(1200)
}

struct SettingsSearchAnchors: PreferenceKey {
    static var defaultValue: Set<String> = []
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) { value.formUnion(nextValue()) }
}

extension View {
    /// Geometry is reported after layout, including rows below the scroll viewport.
    func settingsSearchAnchor(_ id: String) -> some View {
        self.id(id).background {
            GeometryReader { geometry in
                Color.clear.preference(key: SettingsSearchAnchors.self,
                    value: geometry.size.width > 0 && geometry.size.height > 0 ? [id] : [])
            }
        }
    }
}

@MainActor
final class SettingsSearchFeedback: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let target: String
    }
    @Published private(set) var request: Request?
    @Published private(set) var emphasized: String?
    var motion = SettingsMotion(reduceMotion: false)
    private var expiry: Task<Void, Never>?
    private var located: UUID?
    private let sleep: (Duration) async throws -> Void

    init(sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) { self.sleep = sleep }

    func select(_ target: String) {
        cancel()
        request = Request(target: target)
    }

    func layoutReady(_ anchors: Set<String>, locate: (String, Animation?) -> Void) {
        guard let request, anchors.contains(request.target), located != request.id else { return }
        located = request.id
        locate(request.target, motion.search)
        // The result remains explicit even when movement is disabled.
        emphasized = request.target
        let sleep = sleep
        expiry = Task { [weak self] in
            do { try await sleep(SettingsMotion.searchHold) } catch { return }
            guard !Task.isCancelled, let self, self.request?.id == request.id else { return }
            withAnimation(self.motion.search) { self.emphasized = nil }
            self.expiry = nil
        }
    }

    func cancel() {
        expiry?.cancel(); expiry = nil
        request = nil; located = nil; emphasized = nil
    }
    deinit { expiry?.cancel() }
}

/// A retained settings window can close without dismantling its SwiftUI tree.
/// Observe only this host's window, so closing another window cannot cancel it.
struct SettingsWindowLifetime: NSViewRepresentable {
    let close: () -> Void
    func makeNSView(context: Context) -> LifetimeView { LifetimeView(close: close) }
    func updateNSView(_ view: LifetimeView, context: Context) { view.close = close }
    final class LifetimeView: NSView {
        var close: () -> Void
        private var observer: NSObjectProtocol?
        init(close: @escaping () -> Void) { self.close = close; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { close(); return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
