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
        let radius: CGFloat
        if transitioning {
            let t = min(1, max(0, (min(surface.width, surface.height) - 48) / 80))
            radius = 24 + (DotistDesign.windowCornerRadius - 24) * t
        } else {
            radius = compact ? 24 : DotistDesign.windowCornerRadius
        }
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: surface)
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
        #if DOTIST_BENCH
        let _ = BenchPerf.count(.floatingPanelBody)
        #endif
        GeometryReader { geometry in
            let host = motion.transitionHost
            let fixed = motion.bubble || motion.animationInProgress
            let expanded = host.map { $0.local($0.expanded) }
                ?? CGRect(origin: .zero, size: fixed ? motion.transitionSize : geometry.size)
            let restingCompact = motion.bubble ? CGRect(origin: .zero, size: geometry.size) :
                CGRect(x: motion.bubbleOnRight ? geometry.size.width - 48 : 0, y: 0, width: 48, height: 48)
            let compact = host.map { $0.local($0.compact) } ?? restingCompact
            let extra = motion.filterExtra
            ZStack(alignment: .topLeading) {
                content
                    .frame(width: expanded.width, height: expanded.height)
                    .offset(x: expanded.minX, y: expanded.minY)
                    .opacity(motion.bubble ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: motion.bubble ? 0.08 : 0.14).delay(motion.bubble ? 0 : 0.1), value: motion.bubble)
                    .allowsHitTesting(!motion.bubble && !motion.animationInProgress)
                    .accessibilityHidden(motion.bubble || motion.animationInProgress)
                // Keep the compact content in its final layout throughout the morph.
                FloatingBubble(model: model, motion: motion,
                    details: bubbleContent,
                    groupName: groupName, contextMenu: contextMenu, width: compact.width, reveal: hoverReveal,
                    extra: extra, filter: filter)
                    .frame(width: compact.width, height: compact.height,
                           alignment: motion.bubbleOnRight ? .topTrailing : .topLeading)
                    .offset(x: compact.minX, y: compact.minY)
                    .opacity(motion.bubble ? 1 : 0)
                    .allowsHitTesting(motion.bubble && !motion.animationInProgress)
                    .accessibilityHidden(!motion.bubble || motion.animationInProgress)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .mask {
                FloatingContentMask(surface: motion.surface, shape: FloatingPanelShape(compact: motion.bubble,
                    transitioning: motion.animationInProgress, onRight: motion.bubbleOnRight, reveal: hoverReveal,
                    base: 48 + extra, debug: glassDebug.enabled && !reduceTransparency && contrast != .increased
                        ? glassDebug.parameters : nil))
            }
            .background(alignment: .topLeading) {
                ObservedFloatingSurface(surface: motion.surface, material: model.settings.resolvedPanelMaterial,
                    compact: motion.bubble, transitioning: motion.animationInProgress, onRight: motion.bubbleOnRight,
                    size: geometry.size, reveal: hoverReveal, color: model.themeColor(forGroup: colorState.groupID),
                    base: 48 + extra)
            }
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

private struct FloatingContentMask: View {
    @ObservedObject var surface: PanelSurfaceState
    let shape: FloatingPanelShape

    var body: some View {
        GeometryReader { geometry in
            let frame = surface.transitionFrame ?? CGRect(origin: .zero, size: geometry.size)
            shape.fill(.white)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
        }
    }
}

private struct ObservedFloatingSurface: View {
    @ObservedObject var surface: PanelSurfaceState
    let material: DotistPanelMaterial
    let compact: Bool
    let transitioning: Bool
    let onRight: Bool
    let size: CGSize
    let reveal: CGFloat
    let color: DotistGroupColor
    let base: CGFloat

    var body: some View {
        let frame = surface.transitionFrame ?? CGRect(origin: .zero, size: size)
        FloatingSurface(material: material, compact: compact, transitioning: transitioning,
            onRight: onRight, size: frame.size, reveal: reveal, color: color, base: base,
            frameInsets: surface.value)
            .offset(x: frame.minX, y: frame.minY)
    }
}

