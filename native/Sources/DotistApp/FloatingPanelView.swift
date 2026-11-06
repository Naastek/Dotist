import AppKit
import CoreText
import DotistCore
import SwiftUI

/// The content and material share the same animated silhouette, including the
/// unused transparent area of the already-resized hover window.
struct FloatingPanelShape: Shape {
    let compact: Bool
    let transitioning: Bool
    let onRight: Bool
    var reveal: CGFloat
    var base: CGFloat = 48
    var debug: GlassDebugParameters? = nil
    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let width = compact && !transitioning ? base + (rect.width - base) * min(1, max(0, reveal)) : rect.width
        let surface = CGRect(x: rect.minX + (onRight ? rect.width - width : 0), y: rect.minY, width: width, height: rect.height)
        if compact, let debug {
            if debug.shape == .capsule { return Capsule().path(in: surface) }
            return RoundedRectangle(cornerRadius: CGFloat(debug.radius.rawValue), style: .continuous).path(in: surface)
        }
        return RoundedRectangle(cornerRadius: compact ? 24 : DotistDesign.windowCornerRadius, style: .continuous).path(in: surface)
    }
}

struct FloatingPanelView<Content: View>: View {
    @ObservedObject private var glassDebug = GlassDebugState.shared
    @ObservedObject var model: AppModel
    @ObservedObject var motion: PanelMotion
    @ObservedObject var colorState: TaskPanelState
    let title: String
    let remaining: Int
    let total: Int
    let groupName: String?
    let contextMenu: (NSEvent, NSView) -> Void
    let content: Content
    @State private var hoverReveal: CGFloat = 0
    var filter: [String] { colorState.filterParts(in: model, includeGroup: groupName == nil) }
    var bubbleContent: BubbleContent {
        // groupName controls panel wording, never the selected task scope.
        BubbleContent(model: model, groupID: colorState.groupID, fallbackTitle: title, state: colorState)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            let fixed = motion.bubble || motion.animationInProgress
            let width = fixed ? motion.transitionSize.width : geometry.size.width
            let height = fixed ? motion.transitionSize.height : geometry.size.height
            let extra = motion.animationInProgress ? 0 : motion.filterExtra
            ZStack(alignment: .topTrailing) {
                content
                    .frame(width: width, height: height)
                    .opacity(motion.bubble ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14).delay(motion.bubble ? 0 : 0.1), value: motion.bubble)
                    .allowsHitTesting(!motion.bubble)
                    .accessibilityHidden(motion.bubble)
                // Keep text, font cascade and SwiftUI metadata warm before the first
                // collapse. The circle's content never lays out at intermediate widths.
                FloatingBubble(model: model, motion: motion,
                    details: bubbleContent,
                    groupName: groupName, contextMenu: contextMenu, width: motion.bubble && !motion.animationInProgress ? geometry.size.width : 48, reveal: hoverReveal,
                    extra: extra, filter: filter)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: motion.animationInProgress || motion.bubbleOnRight ? .topTrailing : .topLeading)
                    .opacity(motion.bubble ? 1 : 0)
                    .allowsHitTesting(motion.bubble && !motion.animationInProgress)
                    .accessibilityHidden(!motion.bubble)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
            // Clip the animated content, then attach glass. Masking the combined
            // result also cuts the system material's light at the silhouette.
            .clipShape(FloatingPanelShape(compact: motion.bubble, transitioning: motion.animationInProgress,
                onRight: motion.bubbleOnRight, reveal: hoverReveal, base: 48 + extra,
                debug: glassDebug.enabled && !reduceTransparency && contrast != .increased ? glassDebug.parameters : nil))
            .background(FloatingSurface(opacity: model.settings.opacity, frost: model.settings.frost,
                compact: motion.bubble, transitioning: motion.animationInProgress, onRight: motion.bubbleOnRight,
                size: geometry.size, reveal: hoverReveal, color: model.themeColor(forGroup: colorState.groupID), base: 48 + extra,
                frameInsets: motion.surfaceInsets))
            .background(WindowShadowInvalidation())
        }
        .environment(\.glassDebugParameters, glassDebug.enabled ? glassDebug.parameters : nil)
        .onAppear { motion.refreshShadow(); motion.filterState = colorState; motion.filterLines = filter }
        .onChange(of: filter) { motion.filterLines = filter; motion.refreshBaseWidth() }
        .onChange(of: model.settings) { motion.refreshShadow() }
        .onChange(of: model.groups) { motion.refreshShadow() }
        .onChange(of: colorState.groupID) { motion.refreshShadow() }
        .onChange(of: title) { motion.refreshShadow() }
        .onChange(of: scheme) { motion.refreshShadow() }
        .onChange(of: reduceTransparency) { motion.refreshShadow() }
        .onChange(of: contrast) { motion.refreshShadow() }
        .onChange(of: motion.hovering) { _, active in
            // The window already has its final width. Reveal text and glass in the
            // same transaction, then shrink the window after both have settled.
            if reduceMotion {
                hoverReveal = active ? 1 : 0
                motion.finishHover(active)
            } else {
                withAnimation(.easeInOut(duration: 0.26), completionCriteria: .removed) {
                    hoverReveal = active ? 1 : 0
                } completion: {
                    motion.finishHover(active)
                }
            }
        }
        .modifier(DotistTheme(theme: model.settings.theme))
    }
}

