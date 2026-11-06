import AppKit
import CoreText
import DotistCore
import SwiftUI

/// Informational bubble labels use the bounds of the final, possibly truncated
/// native glyph runs. Centering SwiftUI line boxes (and calibrating them with
/// ImageRenderer) leaves a different ink axis in a window-backed NSHostingView.
private struct BubbleText: NSViewRepresentable {
    let lines: [NSAttributedString]
    var centered = false
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> BubbleTextView { BubbleTextView() }
    func updateNSView(_ view: BubbleTextView, context: Context) {
        view.lines = lines
        view.centered = centered
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.needsDisplay = true
    }
}

private final class BubbleTextView: NSView {
    var lines: [NSAttributedString] = []
    var centered = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        context.textPosition = .zero
        let runs = lines.compactMap { text -> (CTLine, CGRect)? in
            guard text.length > 0 else { return nil }
            let full = CTLineCreateWithAttributedString(text)
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: text.attributes(at: 0, effectiveRange: nil)))
            let line = CTLineGetTypographicBounds(full, nil, nil, nil) > bounds.width
                ? CTLineCreateTruncatedLine(full, bounds.width, .end, token) ?? token : full
            let ink = CTLineGetImageBounds(line, context)
            return ink.isEmpty || ink.isNull ? nil : (line, ink)
        }
        // Space actual ink, rather than font ascender/descender boxes. This also
        // keeps mixed serif group / sans date metadata on a common visual axis.
        let gap: CGFloat = 6
        let height = runs.reduce(CGFloat(0)) { $0 + $1.1.height } + CGFloat(max(0, runs.count - 1)) * gap
        var top = bounds.midY + height / 2
        for (line, ink) in runs {
            context.textPosition = CGPoint(x: centered ? bounds.midX - ink.midX : 0, y: top - ink.maxY)
            CTLineDraw(line, context)
            top -= ink.height + gap
        }
    }
}

struct FloatingBubble: View {
    @ObservedObject private var typography = DotistTypography.shared
    @ObservedObject var model: AppModel
    @ObservedObject var motion: PanelMotion
    let details: BubbleContent
    let groupName: String?
    let contextMenu: (NSEvent, NSView) -> Void
    let width: CGFloat
    let reveal: CGFloat
    var extra: CGFloat = 0
    var filter: [String] = []

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, serif: Bool = false, color: Color) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: DotistDesign.nativeFont(size, weight: weight, serif: serif, language: model.language),
            .foregroundColor: NSColor(color)
        ])
    }

    private var textLines: [NSAttributedString] {
        let title = label(details.title, size: 13, weight: .medium, color: DotistDesign.ink)
        guard !details.subtitle.isEmpty else { return [title] }
        let metadata = NSMutableAttributedString(string: "")
        if let group = details.group { metadata.append(label(group, size: 12, weight: .semibold, serif: true, color: DotistDesign.muted)) }
        if details.group != nil && details.due != nil { metadata.append(label(" · ", size: 12, color: DotistDesign.muted)) }
        if let due = details.due { metadata.append(label(due, size: 12, color: DotistDesign.muted)) }
        return [title, metadata]
    }

    var body: some View {
        Button(action: motion.toggleBubble) {
            ZStack(alignment: motion.bubbleOnRight ? .trailing : .leading) {
                BubbleText(lines: textLines)
                    .frame(width: max(0, width - 78 - extra), height: 48, alignment: .leading)
                    .padding(motion.bubbleOnRight ? .leading : .trailing, 12)
                    .padding(motion.bubbleOnRight ? .trailing : .leading, 18 + extra)
                    .offset(x: (1 - reveal) * max(0, width - 48) * (motion.bubbleOnRight ? 1 : -1))
                    .frame(width: max(0, width - 48), height: 48)
                    .clipped()
                    .opacity(Double(reveal))
                    .frame(width: width, height: 48, alignment: motion.bubbleOnRight ? .leading : .trailing)
                    .accessibilityHidden(true)
                if !filter.isEmpty, extra > 0 {
                    // One line per condition, the block centered on the ball's axis.
                    BubbleText(lines: filter.map { label($0, size: 12, color: DotistDesign.muted) })
                        .frame(width: max(0, extra - 16), height: 48, alignment: .leading)
                        .padding(motion.bubbleOnRight ? .trailing : .leading, 52)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                ZStack {
                    BubbleText(lines: [label("\(details.remaining)", size: 20, weight: .semibold, color: DotistDesign.ink)], centered: true)
                }.frame(width: 48, height: 48).contentShape(Circle())
            }.frame(width: width, height: 48, alignment: motion.bubbleOnRight ? .trailing : .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DotistFocusRing())
        .overlay {
            if motion.environment.pointerEventsEnabled {
                // Also gate retained callbacks: removing a hosting view can
                // deliver a tracking exit from its old AppKit pointer overlay.
                BubblePointer(action: {
                    if motion.environment.pointerEventsEnabled { motion.toggleBubble() }
                }, drag: {
                    if motion.environment.pointerEventsEnabled { motion.beginBubbleDrag() }
                }, hover: { active in
                    if motion.environment.pointerEventsEnabled { motion.setHover(active) }
                }, contextMenu: { event, view in
                    if motion.environment.pointerEventsEnabled { contextMenu(event, view) }
                }, dragEnd: {
                    if motion.environment.pointerEventsEnabled { motion.finishBubbleMove() }
                }).accessibilityHidden(true)
            }
        }
        .accessibilityLabel(Text(groupName.map { model.text("展开分组 {name}").replacingOccurrences(of: "{name}", with: $0) } ?? (details.remaining > 0 ? model.text("还有 {n} 件，点击展开").replacingOccurrences(of: "{n}", with: "\(details.remaining)") : model.text("全部完成，点击展开"))))
    }
}
