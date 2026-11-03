import AppKit
import SwiftUI

enum ComposerMetrics {
    static let rowHeight: CGFloat = 24
    static let barHeight: CGFloat = 52
    static let fontSize: CGFloat = 13
    static let calendarSize: CGFloat = 13
    /// One text-independent reference run per script. Group label and input share
    /// it, so descenders in the typed text never move the baseline.
    static func baselineSample(containing text: String) -> String {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) } ? "中文任务" : "Hx"
    }
    static func baselineSample(language: String) -> String {
        ["zh", "ja"].contains { language.hasPrefix($0) } ? "中文任务" : "Hx"
    }
    static func textOpticalOffset(font: NSFont?) -> CGFloat {
        guard let font else { return 0 }
        return TextLineGeometry(font: font, in: CGRect(x: 0, y: 0, width: 100, height: rowHeight)).lineRect.midY - rowHeight / 2
    }
}

/// Menu extracts text attributes but discards view offsets. Give that bridge a
/// native template image whose visible ink is centered in the complete row;
/// neither the primary font's line box nor a neighboring field positions it.
struct ComposerGroupLabel: View {
    @ObservedObject private var typography = DotistTypography.shared
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme
    let title: String
    let language: String
    /// The input's reference run (its placeholder), so both share one baseline.
    var sample = "中文任务"
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    private func image(font: NSFont) -> NSImage {
        let scale = max(1, displayScale)
        let key = "\(sample)|\(DotistDesign.fontCacheKey)|\(font.fontDescriptor)|\(title)|\(scale)|\(scheme)" as NSString
        if let image = Self.images.object(forKey: key) { return image }
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor(DotistDesign.muted)])
        // The group name and the typed task share one text baseline, taken from
        // the input's own line geometry; ink-centering would let the bold serif
        // sit off the regular face beside it.
        let inputFont = DotistDesign.nativeFont(ComposerMetrics.fontSize, language: language)
        let baseline = TextLineGeometry(font: inputFont, in: CGRect(x: 0, y: 0, width: 100, height: ComposerMetrics.rowHeight), sample: "Hx").baseline
        let size = CGSize(width: max(1, ceil(text.size().width)), height: ComposerMetrics.rowHeight)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(ceil(size.width * scale))),
            pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return NSImage(size: size) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        graphics.cgContext.scaleBy(x: scale, y: scale)
        // Bitmap contexts are y-up; the line box's bottom sits |descender| below its baseline.
        let y = ((size.height - baseline + font.descender) * scale).rounded() / scale
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { text.draw(at: CGPoint(x: 0, y: y)) }
        NSGraphicsContext.restoreGraphicsState()
        let image = bitmap.cgImage.map { NSImage(cgImage: $0, size: size) } ?? NSImage(size: size)
        image.isTemplate = true
        Self.images.setObject(image, forKey: key)
        return image
    }
    var body: some View {
        let font = DotistDesign.nativeFont(ComposerMetrics.fontSize, weight: .semibold, serif: true, language: language)
        Image(nsImage: image(font: font)).renderingMode(.template)
            .accessibilityLabel(Text(title))
            .frame(height: ComposerMetrics.rowHeight)
    }
}

struct ComposerCalendarIcon: View {
    var language = "en"
    var body: some View {
        OpticalSymbol(name: "calendar", size: ComposerMetrics.calendarSize)
            .frame(width: ComposerMetrics.rowHeight, height: ComposerMetrics.rowHeight)
    }
}

private final class ComposerInkCanvas: NSView {
    var background = NSColor.white
    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { background.setFill(); bounds.fill() }
}

/// AppKit owns the resting label, placeholder and active field editor. This
/// cell supplies one font-based line box; it never draws a second text run.
final class ComposerTextFieldCell: NSTextFieldCell, NSLayoutManagerDelegate {
    private let composerEditor = ComposerFieldEditor()
    var opticalSample = "中文任务"
    private var measurementKey = ""
    private var inkOffset: CGFloat = 0

    private func lineGeometry(in rect: CGRect) -> (rect: CGRect, baseline: CGFloat) {
        guard let font else { return (rect, rect.midY) }
        let scale = controlView?.window?.backingScaleFactor ?? 1
        let color = stringValue.isEmpty
            ? (placeholderAttributedString.flatMap { $0.length > 0 ? $0.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil } ?? NSColor(DotistDesign.faint))
            : (textColor ?? NSColor(DotistDesign.ink))
        let appearance = controlView?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let colorSpace = controlView?.window?.colorSpace ?? .sRGB
        let key = "\(font.hash)|\(opticalSample)|\(color.hash)|\(appearance.name.rawValue)|\(colorSpace.hash)|\(scale)"
        if key != measurementKey {
            measurementKey = key
            // One stock native label measures the frozen reference run.
            // The live editor uses this same primary-font line box below;
            // there is no second editor, paragraph/layout tree or visible painter.
            appearance.performAsCurrentDrawingAppearance {
                let width = min(2048, max(8, ceil((opticalSample as NSString).size(withAttributes: [.font: font]).width) + 8))
                let height = NSLayoutManager().defaultLineHeight(for: font)
                let canvas = ComposerInkCanvas(frame: CGRect(x: 0, y: 0, width: width, height: height + 16))
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                canvas.background = dark ? .black : .white
                canvas.appearance = appearance
                let label = NSTextField(frame: CGRect(x: 0, y: 0, width: width, height: height))
                label.isBordered = false; label.isBezeled = false; label.drawsBackground = false
                label.usesSingleLineMode = false; label.cell?.wraps = false; label.cell?.isScrollable = true
                label.maximumNumberOfLines = 1; label.lineBreakMode = .byClipping; label.font = font; label.textColor = color
                if stringValue.isEmpty {
                    label.placeholderAttributedString = NSAttributedString(string: opticalSample, attributes: [.font: font, .foregroundColor: color])
                } else { label.stringValue = opticalSample }
                canvas.addSubview(label)
                canvas.layoutSubtreeIfNeeded()
                func offset(at rasterScale: CGFloat) -> CGFloat? {
                    guard let raw = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(width * rasterScale)), pixelsHigh: Int(ceil(canvas.bounds.height * rasterScale)),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
                    let bitmap = raw.retagging(with: colorSpace) ?? raw
                    bitmap.size = canvas.bounds.size
                    canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                    var first = bitmap.pixelsHigh, last = -1
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                            let contrast = dark ? min(c.redComponent, c.greenComponent, c.blueComponent) : 1 - max(c.redComponent, c.greenComponent, c.blueComponent)
                            if contrast > 0.2 { first = min(first, y); last = max(last, y) }
                        }
                    }
                    guard last >= first else { return nil }
                    return NSLayoutManager().defaultBaselineOffset(for: font) - CGFloat(first + last + 1) / (2 * rasterScale)
                }
                let fallback = TextLineGeometry(font: font, in: .zero, sample: opticalSample).baseline
                let fine = offset(at: max(2, scale)) ?? fallback
                let coarse = offset(at: 1) ?? fine
                inkOffset = (coarse + fine) / 2
            }
        }
        let baseline = ((rect.midY + inkOffset) * scale).rounded() / scale
        let nativeBaseline = NSLayoutManager().defaultBaselineOffset(for: font)
        return (CGRect(x: rect.minX, y: baseline - nativeBaseline, width: rect.width,
                       height: NSLayoutManager().defaultLineHeight(for: font)), baseline)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>, lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let font else { return false }
        // Native static labels use the primary font's baseline. TextKit can
        // otherwise grow the first line for a fallback glyph. Use the same
        // font line box while retaining native glyph shaping and selection.
        let height = layoutManager.defaultLineHeight(for: font)
        lineFragmentRect.pointee.size.height = height
        lineFragmentUsedRect.pointee.size.height = height
        baselineOffset.pointee = layoutManager.defaultBaselineOffset(for: font)
        return true
    }

    override func fieldEditor(for view: NSView) -> NSTextView? {
        composerEditor.composer = view
        composerEditor.layoutManager?.delegate = self
        return composerEditor
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        guard font != nil else { return super.drawingRect(forBounds: rect) }
        let native = super.drawingRect(forBounds: rect)
        // AppKit may ask again while establishing the editor. Always resolve
        // the original control box, so drawing/title/edit requests are idempotent.
        let bounds = controlView.flatMap { $0.bounds.isEmpty ? nil : $0.bounds } ?? rect
        var result = lineGeometry(in: bounds).rect
        result.origin.x = native.origin.x
        result.size.width = native.width
        return result
    }

    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }

    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, event: event)
    }
}

/// AppKit sizes a caret from font descent metrics. Center that native-height
/// caret in the same line box as the glyphs, without changing its text baseline.
final class ComposerFieldEditor: NSTextView {
    weak var composer: NSView?
    private let composerStorage: NSTextStorage
    convenience init() { self.init(frame: .zero, textContainer: nil) }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let resolved: NSTextContainer
        if let container, let storage = container.layoutManager?.textStorage {
            resolved = container
            composerStorage = storage
        } else {
            let layout = NSLayoutManager()
            composerStorage = NSTextStorage()
            composerStorage.addLayoutManager(layout)
            resolved = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            layout.addTextContainer(resolved)
        }
        super.init(frame: frameRect, textContainer: resolved)
        isFieldEditor = true
        allowsUndo = true
        clipsToBounds = false
    }
    required init?(coder: NSCoder) { nil }
    func centeredCaretRect(_ rect: NSRect) -> NSRect {
        guard let composer else { return rect }
        var result = rect
        let bounds = convert(composer.bounds, from: composer)
        let sample = (composer as? NSTextField)?.cell as? ComposerTextFieldCell
        let geometry = TextLineGeometry(font: font ?? NSFont.systemFont(ofSize: ComposerMetrics.fontSize), in: bounds, sample: sample?.opticalSample ?? "中文任务")
        result.origin.y = geometry.inkBounds.midY - rect.height / 2
        return result
    }
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: centeredCaretRect(rect), color: color, turnedOn: flag)
    }
}

final class ComposerTextField: NSTextField {
    var rowHeight: CGFloat = ComposerMetrics.rowHeight
    var requestFocusWhenAttached: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { requestFocusWhenAttached?() }
    }
    private var referenceFont: NSFont?
    private var linePadding: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font ?? .systemFont(ofSize: ComposerMetrics.fontSize))) }
    func configure(font: NSFont, reference: String) {
        guard referenceFont != font else { return }
        if let cell = cell as? ComposerTextFieldCell {
            // A fixed sample: the baseline must not depend on whether the
            // placeholder or typed text has descenders, or the group label drifts.
            // One Latin reference run for every language: CJK glyphs hang below it by design.
            cell.opticalSample = "Hx"
        }
        referenceFont = font
        self.font = font
    }
    init() {
        super.init(frame: .zero)
        cell = ComposerTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        maximumNumberOfLines = 1
        // NSCell's single-line mode fixes its baseline to controlSize and
        // ignores font size. Use native font-based layout with no wrapping;
        // the field editor and delegates still own Return/Tab/IME commands.
        usesSingleLineMode = false
        cell?.wraps = false
        cell?.isScrollable = true
        lineBreakMode = .byClipping
        textColor = NSColor(DotistDesign.ink)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }
    override var alignmentRectInsets: NSEdgeInsets {
        let native = super.alignmentRectInsets
        // AppKit intersects its SimpleLabel with control bounds. Give the font
        // line box room above/below the visible row so a centered short run can
        // have a negative line origin without losing that displacement.
        return NSEdgeInsets(top: linePadding, left: native.left, bottom: linePadding, right: native.right)
    }
    override func alignmentRect(forFrame frame: NSRect) -> NSRect {
        let insets = alignmentRectInsets
        return NSRect(x: frame.minX + insets.left, y: frame.minY + insets.bottom,
                      width: frame.width - insets.left - insets.right, height: frame.height - insets.top - insets.bottom)
    }
    override func frame(forAlignmentRect rect: NSRect) -> NSRect {
        let insets = alignmentRectInsets
        return NSRect(x: rect.minX - insets.left, y: rect.minY - insets.bottom,
                      width: rect.width + insets.left + insets.right, height: rect.height + insets.top + insets.bottom)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alignmentRect(forFrame: bounds).contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: rowHeight)
    }
}

struct ComposerInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let label: String
    let font: NSFont
    let commit: () -> Void
    let navigate: (Int) -> Bool
    let complete: (Bool) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = ComposerTextField()
        field.delegate = context.coordinator
        field.requestFocusWhenAttached = { [weak field, weak coordinator = context.coordinator] in
            if let field { coordinator?.requestFocus(field) }
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.needsLayout = true
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor(DotistDesign.faint)])
        field.setAccessibilityLabel(label)
        (field as? ComposerTextField)?.configure(font: font, reference: text.isEmpty ? placeholder : text)
        if field.stringValue != text && (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = text
            if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (text as NSString).length, length: 0) }
        }
        context.coordinator.requestFocus(field)
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComposerInput
        init(_ parent: ComposerInput) { self.parent = parent }
        private var focusScheduled = false
        func requestFocus(_ field: NSTextField) {
            guard parent.focused, field.currentEditor() == nil, !focusScheduled else { return }
            focusScheduled = true
            // Wait for SwiftUI to remove mutually exclusive editors and attach
            // this field. Read the latest binding so withdrawn requests expire.
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self else { return }
                self.focusScheduled = false
                guard self.parent.focused, let field, let window = field.window,
                      field.currentEditor() == nil else { return }
                window.makeFirstResponder(field)
            }
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.focused = true
            if let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView {
                editor.insertionPointColor = NSColor(DotistDesign.accent)
                editor.allowsUndo = true
            }
        }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            if selector == #selector(NSResponder.moveDown(_:)) { return parent.navigate(1) }
            if selector == #selector(NSResponder.moveUp(_:)) { return parent.navigate(-1) }
            if selector == #selector(NSResponder.insertTab(_:)) { return parent.complete(true) }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if !parent.complete(false) { parent.commit() }
                return true
            }
            return false
        }
    }
}

/// A shared 24pt line box, used by the real bar and offscreen rendering tests.
struct ComposerLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 324, height: ComposerMetrics.rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let date = subviews[2].sizeThatFits(.unspecified).width
        let group = min(subviews[0].sizeThatFits(.unspecified).width, max(0, bounds.width - date - 70))
        let y = bounds.midY - ComposerMetrics.rowHeight / 2
        subviews[0].place(at: CGPoint(x: bounds.minX - 3, y: y), proposal: ProposedViewSize(width: group, height: ComposerMetrics.rowHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX + group + 8, y: y), proposal: ProposedViewSize(width: max(0, bounds.width - group - date - 16), height: ComposerMetrics.rowHeight))
        subviews[2].place(at: CGPoint(x: bounds.maxX - date, y: y), proposal: ProposedViewSize(width: date, height: ComposerMetrics.rowHeight))
    }
}
