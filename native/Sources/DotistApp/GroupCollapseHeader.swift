import AppKit
import Combine
import DotistCore
import SwiftUI

/// The title and disclosure glyph share the complete title's native ink axis.
struct GroupCollapseHeader: View {
    let title: String
    let language: String
    let collapsed: Bool
    let hovered: Bool
    var empty = false
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motion: DisclosureMotion
    init(title: String, language: String, collapsed: Bool, hovered: Bool, empty: Bool = false, toggle: @escaping () -> Void) {
        self.title = title; self.language = language; self.collapsed = collapsed
        self.hovered = hovered; self.empty = empty; self.toggle = toggle
        _motion = StateObject(wrappedValue: DisclosureMotion(expanded: !collapsed))
    }
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                GroupHeaderInkLabel(title: title, language: language, collapsed: collapsed,
                                    showsChevron: collapsed || hovered || motion.fraction < 1, empty: empty, disclosureProgress: motion.fraction)
                Spacer(minLength: 26)
            }.frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(GroupHeaderButtonStyle()).modifier(DotistFocusRing()).accessibilityLabel(Text(title))
            .onAppear { motion.setExpanded(!collapsed, reduceMotion: true) }
            .onChange(of: collapsed) { value in motion.setExpanded(!value, reduceMotion: LayoutMotionInputs.shouldReduceMotion(reduceMotion)) }
            .onChange(of: reduceMotion) { value in if value { motion.setExpanded(!collapsed, reduceMotion: true) } }
            .onDisappear { motion.stop() }
    }
}

/// Disclosure motion changes only the arrow. PlainButtonStyle applies a
/// transient pressed opacity to the complete label, including rasterized text.
private struct GroupHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private struct HeaderMenuEscape: NSViewRepresentable {
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Hovering does not give a SwiftUI control keyboard focus.
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard event.keyCode == 53, let window = view?.window, event.window === window else { return event }
            isPresented = false
            return nil
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    final class Coordinator {
        var monitor: Any?
    }
}
