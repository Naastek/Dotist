import AppKit
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class FloatingSurfaceLifetimeTests: XCTestCase {
    private final class State: ObservableObject { @Published var transitioning = true }
    private final class Lifetime {
        var made = 0
        var removed = 0
        var lastPhase: Bool?
    }
    private struct NativeMaterial: NSViewRepresentable {
        let lifetime: Lifetime
        let phase: Bool
        func makeNSView(context: Context) -> NSView {
            lifetime.made += 1
            return NSView()
        }
        func updateNSView(_ view: NSView, context: Context) { lifetime.lastPhase = phase }
        func makeCoordinator() -> Lifetime { lifetime }
        static func dismantleNSView(_ view: NSView, coordinator: Lifetime) { coordinator.removed += 1 }
    }
    private struct Surface: View {
        @ObservedObject var state: State
        let lifetime: Lifetime
        var body: some View {
            NativeMaterial(lifetime: lifetime, phase: state.transitioning)
                .modifier(FloatingSurfaceClipping(shape: FloatingPanelShape(compact: true, transitioning: state.transitioning,
                    onRight: true, reveal: 0), clipsSilhouette: state.transitioning))
        }
    }
    func testCollapseCompletionKeepsTheMountedMaterial() async throws {
        _ = NSApplication.shared
        let state = State(), lifetime = Lifetime()
        let host = NSHostingView(rootView: Surface(state: state, lifetime: lifetime))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 48, height: 48),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()
        for transitioning in [true, false, true, false] {
            state.transitioning = transitioning
            let deadline = ContinuousClock.now + .seconds(2)
            while lifetime.lastPhase != transitioning && ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(lifetime.lastPhase, transitioning, "Require the native subtree to receive the new phase")
            XCTAssertEqual(lifetime.made, 1, "Transition clipping must not recreate native material")
            XCTAssertEqual(lifetime.removed, 0, "Collapse completion must not discard native material")
        }
    }
}
