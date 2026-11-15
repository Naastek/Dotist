import DotistCore

import SwiftUI
import AppKit

struct TaskRowActionButtonStyle: ButtonStyle {
    var destructive = false
    let visible: Bool
    func makeBody(configuration: Configuration) -> some View {
        Feedback(label: configuration.label, pressed: configuration.isPressed, destructive: destructive, visible: visible)
    }
    private struct Feedback: View {
        let label: ButtonStyleConfiguration.Label
        let pressed: Bool
        let destructive: Bool
        let visible: Bool
        @State private var hovered = false
        @Environment(\.colorScheme) private var scheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            let active = visible && (hovered || pressed)
            let color = destructive ? DotistDesign.danger : DotistDesign.accent
            label
                .foregroundStyle(active ? color : DotistDesign.muted)
                .scaleEffect(pressed ? 0.92 : 1)
                .background {
                    TaskRowActionHighlight(active: active, pressed: pressed, destructive: destructive, dark: scheme == .dark)
                }
                .onHover { hovered = visible && $0 }
                .onChange(of: visible) { _, value in if !value { hovered = false } }
                .onDisappear { hovered = false }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        }
    }
}

struct TaskRowActionBacking: View {
    let color: DotistGroupColor
    let scheme: ColorScheme
    let opaque: Bool
    var keyboardFocused = false
    var body: some View {
        Group {
            if opaque {
                Capsule().fill(DotistDesign.paper)
                    .overlay(Capsule().strokeBorder(keyboardFocused ? DotistDesign.accent : DotistDesign.rule, lineWidth: 1))
            } else {
                Color.clear.dotistGlass(.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(keyboardFocused ? DotistDesign.accent.opacity(0.65) : Color.clear, lineWidth: 0.5))
            }
        }.clipShape(Capsule()).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Shared paint path used by live button feedback and isolated raster checks.
struct TaskRowActionHighlight: View {
    let active: Bool
    let pressed: Bool
    let destructive: Bool
    let dark: Bool
    var body: some View {
        RadialGradient(colors: [Color.white.opacity(pressed ? 0.24 : (dark ? 0.16 : 0.28)), .white.opacity(0)],
                       center: .center, startRadius: 0, endRadius: 11)
            .opacity(active ? 1 : 0).allowsHitTesting(false)
    }
}
