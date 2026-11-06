import AppKit
import Combine
import DotistCore
import SwiftUI

struct DraggableFilterButton: View {
    let title: String
    let selected: Bool
    let language: String
    var distance: Int = 0
    let choose: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var origin: (mouse: NSPoint, window: NSPoint)?
    @StateObject private var motion: DateFilterSelectionMotion

    init(title: String, selected: Bool, language: String, distance: Int = 0, choose: @escaping () -> Void) {
        self.title = title; self.selected = selected; self.language = language
        self.distance = distance; self.choose = choose
        _motion = StateObject(wrappedValue: DateFilterSelectionMotion(selected: selected))
    }

    var body: some View {
        Button { if origin == nil { choose() } } label: {
            DateFilterInkLabel(title: title, language: language, fraction: motion.fraction,
                               regularColor: focused ? DotistDesign.accent : hovering ? DotistDesign.muted : DotistDesign.faint,
                               selectedColor: focused ? DotistDesign.accent : DotistDesign.ink,
                               regularOpacity: TaskDateFilterMetrics.opacity(distance: distance, hovered: hovering, focused: focused,
                                                                            increasedContrast: contrast == .increased, voiceOver: voiceOver),
                               feedbackAnimation: DateFilterSelectionMotion.animation(reduceMotion: reduceMotion))
                .frame(width: TaskDateFilterMetrics.slotWidth(title: title, language: language), height: TaskDateFilterMetrics.rowHeight)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focused).focusEffectDisabled().onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .onAppear { motion.appear(selected: selected) }
            .onChange(of: selected) { _, value in motion.setSelected(value, reduceMotion: DateFilterSelectionMotion.environmentReduceMotion(reduceMotion)) }
            .onChange(of: reduceMotion) { _, _ in motion.setSelected(selected, reduceMotion: DateFilterSelectionMotion.environmentReduceMotion(reduceMotion)) }
            .onDisappear { motion.stop() }
            .highPriorityGesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard let event = NSApp.currentEvent, let window = event.window else { return }
                    let mouse = window.convertPoint(toScreen: event.locationInWindow)
                    if origin == nil { origin = (NSPoint(x: mouse.x - value.translation.width, y: mouse.y + value.translation.height), window.frame.origin) }
                    guard let origin else { return }
                    window.setFrameOrigin(NSPoint(x: origin.window.x + mouse.x - origin.mouse.x, y: origin.window.y + mouse.y - origin.mouse.y))
                }.onEnded { _ in DispatchQueue.main.async { origin = nil } })
    }
}
