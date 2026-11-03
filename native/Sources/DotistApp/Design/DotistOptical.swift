import AppKit
import CoreText
import SwiftUI

extension VerticalAlignment {
    private enum OpticalCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }
    static let opticalCenter = VerticalAlignment(OpticalCenter.self)
}

/// All measurements use the midpoint of the first/last occupied pixel rows,
/// rather than an alpha-weighted centroid (which moves with a symbol's shape).
/// Values are generated on this OS with the registered font, at 4 pixels/pt.
/// The cache is the calibration table: family, size, weight, script or symbol.
@MainActor enum OpticalMetrics {
    enum Script: String, CaseIterable {
        case cjk, latin, digits
        var sample: String {
            switch self {
            case .cjk: return "中文任务"
            case .latin: return "Inbox"
            case .digits: return "0123456789"
            }
        }
        static func forText(_ text: String) -> Script {
            if text.unicodeScalars.contains(where: { $0.value >= 0x2e80 }) { return .cjk }
            if !text.isEmpty && text.allSatisfy({ $0.isNumber || "/:-. ".contains($0) }) { return .digits }
            return .latin
        }
    }
    struct Measurement {
        let inkOffset: CGFloat
        var correction: CGFloat { -inkOffset }
    }
    private static var table: [String: Measurement] = [:]
    static func reset() { table.removeAll() }

    static func inkBounds(of image: CGImage, threshold: UInt8 = 24) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > threshold {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
    private static func measure<V: View>(_ view: V, key: String, width: CGFloat = 64, scale: CGFloat = 4) -> Measurement {
        if let result = table[key] { return result }
        let renderer = ImageRenderer(content: view.foregroundStyle(.white).fixedSize().frame(width: width, height: 64))
        renderer.scale = scale
        let offset = renderer.cgImage.flatMap { inkBounds(of: $0) }.map { $0.midY / scale - 32 } ?? 0
        let result = Measurement(inkOffset: offset)
        table[key] = result
        return result
    }
    static func text(_ font: NSFont, script: Script) -> Measurement { text(font, sample: script.sample) }
    private static func textKey(_ font: NSFont, sample: String) -> String {
        let cascade = (font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor] ?? []).map { String(describing: $0.object(forKey: .family)) }.joined(separator: ",")
        return "\(DotistDesign.fontCacheKey)|\(font.fontName)|\(font.pointSize)|\(String(describing: CTFontCopyVariation(font as CTFont)))|\(String(describing: font.fontDescriptor.object(forKey: .traits)))|\(cascade)|\(sample)"
    }
    static func text(_ font: NSFont, sample: String) -> Measurement {
        let width = min(320, max(8, ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 4))
        return measure(Text(sample).font(Font(font)), key: "text|\(textKey(font, sample: sample))", width: width)
    }
    static func attributedBaseline(_ font: NSFont, sample: String) -> CGFloat {
        // A 2x native borderless Menu baseline sweep measured bundled serif
        // labels up to 0.75pt high, while the system serif was already centered.
        // Its line box rounds differently: a shared adjustment regresses it.
        // Keep the bridge calibration with the actual font, including fallbacks;
        // ordinary SwiftUI text remeasures the resulting line box below.
        let menuAdjustment: CGFloat = ["Newsreader", "Source Serif 4"].contains(font.familyName ?? "") ? -0.25 : 0
        return text(font, sample: sample).inkOffset + menuAdjustment
    }
    static func baselineText(_ font: NSFont, sample: String, baseline: CGFloat) -> Measurement {
        let width = min(320, max(8, ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 4))
        // SwiftUI can expand the line box for an attributed baseline. Measure
        // that box again; native Menu consumes the attribute and ignores this
        // residual view correction. Both rendering paths keep their ink axis.
        return measure(Text(sample).font(Font(font)).baselineOffset(baseline),
                       key: "baseline|2|\(baseline)|\(textKey(font, sample: sample))", width: width, scale: 2)
    }
    static func symbol(_ name: String, size: CGFloat, weight: Font.Weight = .regular) -> Measurement {
        measure(Image(systemName: name).font(.system(size: size, weight: weight)).imageScale(.medium),
                key: "symbol|\(name)|\(size)|\(weight)")
    }
}

/// The visual correction stays inside the original layout and hit-test box.
struct OpticalText: View {
    @ObservedObject private var typography = DotistTypography.shared
    let title: String
    var size: CGFloat = 13
    var weight: NSFont.Weight = .regular
    var serif = false
    var language = "en"
    var body: some View {
        let font = DotistDesign.nativeFont(size, weight: weight, serif: serif, language: language)
        let sample = title.isEmpty ? " " : title
        let baseline = OpticalMetrics.attributedBaseline(font, sample: sample)
        // Keep the residual on the 2x pixel grid; fractional pixel transforms
        // otherwise move faint text's thresholded ink edge by another pixel.
        let residual = (OpticalMetrics.baselineText(font, sample: sample, baseline: baseline).correction * 2).rounded(.down) / 2
        Text(title).font(Font(font))
            // Native Menu extracts an attributed title and discards view offsets.
            // A baseline attribute survives both that bridge and SwiftUI rendering.
            .baselineOffset(baseline)
            .offset(y: residual)
            .alignmentGuide(.opticalCenter) { $0[VerticalAlignment.center] }
    }
}

struct OpticalSymbol: View {
    let name: String
    var size: CGFloat = 11
    var weight: Font.Weight = .regular
    var body: some View {
        Image(systemName: name).font(.system(size: size, weight: weight)).imageScale(.medium)
            .offset(y: OpticalMetrics.symbol(name, size: size, weight: weight).correction)
            .alignmentGuide(.opticalCenter) { $0[VerticalAlignment.center] }
    }
}

/// A group title and its disclosure share one native drawing surface. The
/// complete title (including fallback glyphs) is rasterized at the window's
/// backing scale, then both cropped ink boxes are placed on the same axis.
/// This deliberately bypasses OpticalText's attributed Menu baseline and the
/// ImageRenderer calibration: neither describes a window-hosted header.
struct GroupHeaderInkLabel: NSViewRepresentable {
    @ObservedObject private var typography = DotistTypography.shared
    let title: String
    let language: String
    let collapsed: Bool
    let showsChevron: Bool
    let empty: Bool
    var disclosureProgress: CGFloat? = nil

    func makeNSView(context: Context) -> GroupHeaderInkView { GroupHeaderInkView() }
    func updateNSView(_ view: GroupHeaderInkView, context: Context) {
        view.configure(title: title, font: DotistDesign.nativeFont(15, weight: .semibold, serif: true, language: language),
                       symbol: collapsed ? "chevron.right" : "chevron.down", showsChevron: showsChevron,
                       titleColor: NSColor(empty ? DotistDesign.faint : DotistDesign.ink), disclosureProgress: disclosureProgress)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GroupHeaderInkView, context: Context) -> CGSize? {
        let ideal = nsView.intrinsicContentSize
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
    }
}

final class GroupHeaderInkView: NSView {
    struct InkRaster {
        let image: CGImage
        let size: CGSize
        var alignmentRect: CGRect
    }
    private var title = ""
    private var titleFont = NSFont.systemFont(ofSize: 15)
    private var symbol = "chevron.right"
    private var showsChevron = true
    private var titleColor = NSColor.labelColor
    private var titleImage: InkRaster?
    private var symbolImages: [String: InkRaster] = [:]
    private var symbolImage: InkRaster? { symbolImages["chevron.right"] }
    private(set) var disclosureProgress: CGFloat = 0
    private var rotationKey = ""
    private var rotatedSymbol: InkRaster?
    // Both directions share a slot, including while the arrow is hidden. A
    // direction change cannot take width from the already laid-out title.
    private var symbolSlotWidth: CGFloat { symbolImages.values.map { ceil(hypot($0.size.width, $0.size.height)) }.max() ?? 0 }
    private var rasterScale: CGFloat = 0
    private var rasterColorSpace: NSColorSpace?
    // These are also useful to isolate the two glyph masks in native captures.
    private(set) var titleInkFrame = CGRect.zero
    private(set) var symbolInkFrame = CGRect.zero
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(title: String, font: NSFont, symbol: String, showsChevron: Bool, titleColor: NSColor, disclosureProgress: CGFloat? = nil) {
        let changed = self.title != title || titleFont != font || self.titleColor != titleColor
        self.title = title; titleFont = font; self.symbol = symbol
        self.showsChevron = showsChevron; self.titleColor = titleColor
        self.disclosureProgress = disclosureProgress ?? (symbol == "chevron.down" ? 1 : 0)
        if changed { invalidateRasters() }
        needsDisplay = true
    }
    private func invalidateRasters() {
        rasterScale = 0
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateRasters()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateRasters()
    }
    override var intrinsicContentSize: NSSize {
        prepareRasters()
        // Cropped ink can be narrower at the window backing scale than in a
        // later drawing context. Reserve the complete line advance, rounded to
        // points, so a short title never enters truncation during that change.
        let advance = (title as NSString).size(withAttributes: [.font: titleFont]).width
        let titleWidth = ceil(max(advance, titleImage?.size.width ?? 0))
        return NSSize(width: titleWidth + 6 + symbolSlotWidth, height: 30)
    }
    private func prepareRasters(scale requestedScale: CGFloat? = nil) {
        let scale = requestedScale ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let colorSpace = window?.colorSpace ?? .sRGB
        guard rasterScale != scale || rasterColorSpace != colorSpace else { return }
        rasterScale = scale; rasterColorSpace = colorSpace
        rotationKey = ""
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let text = NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: titleColor])
            titleImage = Self.inkImage(size: text.size(), scale: scale, colorSpace: colorSpace) { text.draw(at: $0) }
            symbolImages.removeAll(keepingCapacity: true)
            for name in ["chevron.right", "chevron.down"] {
                let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
                symbolImages[name] = image.flatMap { image in
                    Self.inkImage(size: image.size, scale: scale, colorSpace: colorSpace) { point in
                        // Draw the symbol as a mask, then color the occupied pixels.
                        image.draw(at: point, from: .zero, operation: .sourceOver, fraction: 1)
                        NSColor(DotistDesign.faint).setFill()
                        NSRect(origin: point, size: image.size).fill(using: .sourceIn)
                    }
                }
            }
        }
    }
    /// Crop the actual native raster, rather than using an advance width,
    /// ascender, cap height, script sample, or alpha-weighted centroid.
    static func inkImage(size: CGSize, scale: CGFloat, colorSpace: NSColorSpace = .sRGB, draw: (CGPoint) -> Void) -> InkRaster? {
        let padding: CGFloat = 4
        let width = max(1, Int(ceil((size.width + padding * 2) * scale)))
        let height = max(1, Int(ceil((size.height + padding * 2) * scale)))
        guard let raw = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let bitmap = raw.retagging(with: colorSpace) ?? raw
        guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        graphics.cgContext.scaleBy(x: scale, y: scale)
        draw(CGPoint(x: padding, y: padding))
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        var left = width, right = -1, top = height, bottom = -1
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for y in 0..<height {
            for x in 0..<width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 24.0 / 255 else { continue }
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left,
              let cropped = bitmap.cgImage?.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else { return nil }
        let size = CGSize(width: CGFloat(cropped.width) / scale, height: CGFloat(cropped.height) / scale)
        var image = InkRaster(image: cropped, size: size, alignmentRect: CGRect(origin: .zero, size: size))
        // Measure the final native image draw over an opaque backdrop. The
        // transparent source's edges can differ after native color compositing.
        // Preserve every antialiased pixel; only the alignment rect changes.
        if let rawOpaque = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cropped.width, pixelsHigh: cropped.height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            let opaque = rawOpaque.retagging(with: colorSpace) ?? rawOpaque
            guard let graphics = NSGraphicsContext(bitmapImageRep: opaque) else { return image }
            NSGraphicsContext.saveGraphicsState()
            let context = graphics.cgContext
            context.translateBy(x: 0, y: CGFloat(cropped.height))
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let bounds = CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height)
            (dark ? NSColor.black : NSColor.white).setFill()
            bounds.fill()
            drawInkImage(image, in: bounds)
            NSGraphicsContext.restoreGraphicsState()
            var x0 = cropped.width, x1 = -1, y0 = cropped.height, y1 = -1
            for y in 0..<cropped.height {
                for x in 0..<cropped.width {
                    guard let c = opaque.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let contrast = dark ? min(c.redComponent, c.greenComponent, c.blueComponent) : 1 - max(c.redComponent, c.greenComponent, c.blueComponent)
                    if contrast > 0.2 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
                }
            }
            if x1 >= x0 {
                image.alignmentRect = CGRect(x: CGFloat(x0) / scale, y: CGFloat(cropped.height - y1 - 1) / scale,
                                             width: CGFloat(x1 - x0 + 1) / scale, height: CGFloat(y1 - y0 + 1) / scale)
            }
        }
        return image
    }
    static func drawInkImage(_ image: InkRaster, in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image.image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
    override func draw(_ dirtyRect: NSRect) {
        // cacheDisplay/PDF/bitmap contexts may differ from the screen backing.
        let transform = NSGraphicsContext.current?.cgContext.ctm
        let scale = transform.map { hypot($0.a, $0.b) } ?? window?.backingScaleFactor ?? 1
        prepareRasters(scale: max(1, scale))
        guard let titleImage else { return }
        let available = max(0, bounds.width - symbolSlotWidth - 6)
        // Preserve the single-line tail truncation of the SwiftUI title.
        let displayedTitle: InkRaster
        if titleImage.size.width > available, available > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: titleColor, .paragraphStyle: paragraph])
            let size = CGSize(width: available, height: NSLayoutManager().defaultLineHeight(for: titleFont))
            displayedTitle = Self.inkImage(size: size, scale: rasterScale, colorSpace: window?.colorSpace ?? .sRGB) { point in
                text.draw(with: CGRect(origin: point, size: size), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            } ?? titleImage
        } else { displayedTitle = titleImage }
        func frames(_ image: InkRaster, x: CGFloat, center: CGFloat, upperTie: Bool = false) -> (drawing: CGRect, ink: CGRect) {
            let ink = image.alignmentRect
            let top = image.size.height - ink.maxY
            let pixels = (center - ink.height / 2 - top) * rasterScale
            let y = (upperTie ? ceil(pixels - 0.5) : pixels.rounded()) / rasterScale
            let drawing = CGRect(origin: CGPoint(x: x - ink.minX, y: y), size: image.size)
            return (drawing, CGRect(x: x, y: y + top, width: ink.width, height: ink.height))
        }
        let titleFrames = frames(displayedTitle, x: 0, center: bounds.midY)
        titleInkFrame = titleFrames.ink
        Self.drawInkImage(displayedTitle, in: titleFrames.drawing)
        guard let symbolImage else { return }
        let key = "\(rasterScale)|\(disclosureProgress)"
        if key != rotationKey {
            rotationKey = key
            let extent = symbolSlotWidth
            let angle = disclosureProgress * .pi / 2
            rotatedSymbol = Self.inkImage(size: CGSize(width: extent, height: extent), scale: rasterScale,
                                          colorSpace: window?.colorSpace ?? .sRGB) { origin in
                guard let context = NSGraphicsContext.current?.cgContext else { return }
                context.saveGState()
                context.translateBy(x: origin.x + extent / 2, y: origin.y + extent / 2)
                context.rotate(by: -angle)
                NSImage(cgImage: symbolImage.image, size: symbolImage.size)
                    .draw(in: CGRect(x: -symbolImage.size.width / 2, y: -symbolImage.size.height / 2,
                                     width: symbolImage.size.width, height: symbolImage.size.height))
                context.restoreGState()
            }
        }
        guard let rotatedSymbol else { return }
        // A rotated chevron's triangular ink does not have the same center as
        // its rotated rectangle. Center the final raster at every angle.
        let symbolX = ((titleInkFrame.maxX + 6 + (symbolSlotWidth - rotatedSymbol.alignmentRect.width) / 2) * rasterScale).rounded() / rasterScale
        let symbolFrames = frames(rotatedSymbol, x: symbolX, center: titleInkFrame.midY, upperTie: true)
        symbolInkFrame = symbolFrames.ink
        if showsChevron { Self.drawInkImage(rotatedSymbol, in: symbolFrames.drawing) }
    }
}

struct IconTextRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content
    var body: some View { HStack(alignment: .opticalCenter, spacing: spacing, content: content) }
}

struct DisclosureRow: View {
    let title: String
    let expanded: Bool
    let language: String
    var body: some View {
        IconTextRow {
            OpticalSymbol(name: expanded ? "chevron.down" : "chevron.right", size: 9, weight: .semibold)
                .frame(width: 18, height: 20)
            OpticalText(title: title, size: 12, language: language)
        }.foregroundStyle(DotistDesign.faint).frame(height: 28).contentShape(Rectangle())
    }
}

/// Native text geometry, in flipped (top-down) coordinates. A representative
/// run fixes the baseline while editing: typing punctuation/descenders must
/// never reposition the line. CoreText supplies fallback-run image bounds.
struct TextLineGeometry {
    let lineRect: CGRect
    let baseline: CGFloat
    let inkBounds: CGRect
    init(font: NSFont, in rect: CGRect, sample: String = "中文任务") {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample, attributes: [.font: font]))
        let measured = CTLineGetImageBounds(line, nil)
        let ink = measured.isNull || measured.isEmpty ? CGRect(x: 0, y: font.descender, width: 0, height: font.ascender - font.descender) : measured
        let height = NSLayoutManager().defaultLineHeight(for: font)
        // CT bounds are y-up relative to the baseline; AppKit view bounds are y-down.
        baseline = rect.midY + ink.midY
        lineRect = CGRect(x: rect.minX, y: baseline - NSLayoutManager().defaultBaselineOffset(for: font), width: rect.width, height: height)
        inkBounds = CGRect(x: rect.minX + ink.minX, y: baseline - ink.maxY, width: ink.width, height: ink.height)
    }
}

/// Shared native field for search and manager rename controls. Focus, selection,
/// IME and undo remain native; the same cell also serves Composer and Quick Add.
struct OpticalInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    var focusOnAppear = false
    var identifier: String? = nil
    var commit: () -> Void = {}
    var navigate: (Int) -> Bool = { _ in false }
    var cancel: (() -> Void)?
    var blur: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ComposerTextField {
        let field = ComposerTextField()
        field.delegate = context.coordinator
        if focusOnAppear { DispatchQueue.main.async { field.window?.makeFirstResponder(field) } }
        return field
    }
    func updateNSView(_ field: ComposerTextField, context: Context) {
        context.coordinator.parent = self
        field.configure(font: font, reference: text.isEmpty ? placeholder : text)
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: NSColor(DotistDesign.faint)])
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier(identifier)
        if field.stringValue != text && (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OpticalInput
        init(_ parent: OpticalInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func controlTextDidEndEditing(_ notification: Notification) { parent.blur() }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if selector == #selector(NSResponder.moveUp(_:)) { return parent.navigate(-1) }
            if selector == #selector(NSResponder.moveDown(_:)) { return parent.navigate(1) }
            if selector == #selector(NSResponder.cancelOperation(_:)), let cancel = parent.cancel { cancel(); return true }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.commit(); return true
        }
    }
}

struct SearchRow: View {
    @ObservedObject private var typography = DotistTypography.shared
    @Binding var text: String
    let placeholder: String
    let language: String
    var size: CGFloat = 13
    var iconSize: CGFloat = 12
    var focusOnAppear = false
    var identifier: String? = nil
    var commit: () -> Void = {}
    var navigate: (Int) -> Bool = { _ in false }
    var cancel: (() -> Void)?
    var body: some View {
        IconTextRow(spacing: 12) {
            NativeSearchIcon(size: iconSize).frame(width: 20, height: 24)
            OpticalInput(text: $text, placeholder: placeholder, font: DotistDesign.nativeFont(size, language: language), focusOnAppear: focusOnAppear, identifier: identifier, commit: commit, navigate: navigate, cancel: cancel).frame(height: max(24, size * 1.5))
        }
    }
}

/// Search's native field uses the upper pixel when its ink has odd height.
/// Rasterize its companion glyph in the same native context and use that same
/// edge rule, rather than importing an ImageRenderer offset into a window.
private struct NativeSearchIcon: NSViewRepresentable {
    let size: CGFloat
    func makeNSView(context: Context) -> NativeSearchIconView { NativeSearchIconView() }
    func updateNSView(_ view: NativeSearchIconView, context: Context) { view.pointSize = size }
}

private final class NativeSearchIconView: NSView {
    var pointSize: CGFloat = 12 {
        didSet { if pointSize != oldValue { raster = nil; needsDisplay = true } }
    }
    private var raster: GroupHeaderInkView.InkRaster?
    private var rasterScale: CGFloat = 0
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        raster = nil; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let transform = NSGraphicsContext.current?.cgContext.ctm
        let scale = transform.map { hypot($0.a, $0.b) } ?? window?.backingScaleFactor ?? 1
        if raster == nil || rasterScale != scale {
            rasterScale = scale
            if let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)) {
                raster = GroupHeaderInkView.inkImage(size: symbol.size, scale: scale) { point in
                    symbol.draw(at: point, from: .zero, operation: .sourceOver, fraction: 1)
                    NSColor(DotistDesign.faint).setFill()
                    NSRect(origin: point, size: symbol.size).fill(using: .sourceIn)
                }
            }
        }
        guard let raster else { return }
        let ink = raster.alignmentRect
        let top = raster.size.height - ink.maxY
        let y = floor((bounds.midY - ink.height / 2 - top) * scale) / scale
        GroupHeaderInkView.drawInkImage(raster, in: CGRect(x: bounds.midX - raster.size.width / 2, y: y, width: raster.size.width, height: raster.size.height))
    }
}

/// The label determines the whole row height. GeometryReader in the track then
/// receives that measured height, including wrapped titles and extra metadata.
struct GanttRowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(600, proposal.width ?? 600)
        let label = subviews[0].sizeThatFits(.init(width: 220, height: nil))
        return CGSize(width: width, height: max(56, label.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let label = subviews[0].sizeThatFits(.init(width: 220, height: nil))
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY - label.height / 2), proposal: .init(width: 220, height: label.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + 220, y: bounds.minY), proposal: .init(width: max(0, bounds.width - 220), height: bounds.height))
    }
}

/// Keep the live accessibility policy and uptime clock together. Debug fixtures
/// can freeze layout time without changing the desktop's accessibility settings.
@MainActor
enum LayoutMotionInputs {
    #if DEBUG
    struct Override {
        var now: @MainActor () -> TimeInterval
        var reduceMotion: Bool
    }
    static var testOverride: Override?
    #endif

    static var now: TimeInterval {
        #if DEBUG
        if let testOverride { return testOverride.now() }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }
    static func shouldReduceMotion(_ environmentValue: Bool) -> Bool {
        #if DEBUG
        if let testOverride { return testOverride.reduceMotion }
        #endif
        return environmentValue || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// A run-loop clock also advances in unordered hosting windows. Retarget from
/// the presented fraction, so rapid reversals never restart at an endpoint.
@MainActor
final class DisclosureMotion: ObservableObject {
    #if DEBUG
    struct Sample {
        let id: ObjectIdentifier
        let event: String
        let uptime: TimeInterval
        let fraction: CGFloat
        let target: CGFloat
        let animating: Bool
    }
    static var trace: ((Sample) -> Void)?
    private func record(_ event: String, target: CGFloat) {
        Self.trace?(Sample(id: ObjectIdentifier(self), event: event, uptime: ProcessInfo.processInfo.systemUptime,
                           fraction: fraction, target: target, animating: timer != nil))
    }
    #endif
    @Published private(set) var fraction: CGFloat
    private var timer: Timer?
    init(expanded: Bool) { fraction = expanded ? 1 : 0 }
    func setExpanded(_ expanded: Bool, reduceMotion: Bool) {
        let target: CGFloat = expanded ? 1 : 0
        #if DEBUG
        record("retarget", target: target)
        #endif
        timer?.invalidate(); timer = nil
        guard !reduceMotion, abs(target - fraction) > 0.001 else {
            fraction = target
            #if DEBUG
            record("snap", target: target)
            #endif
            return
        }
        let start = fraction
        let began = LayoutMotionInputs.now
        let duration = 0.22 * Double(abs(target - start))
        let clock = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, (LayoutMotionInputs.now - began) / duration)
                let eased = t * t * (3 - 2 * t)
                var transaction = Transaction(); transaction.animation = nil
                withTransaction(transaction) { self.fraction = start + (target - start) * eased }
                if t >= 1 { timer.invalidate(); self.timer = nil }
                #if DEBUG
                self.record(t >= 1 ? "finish" : "tick", target: target)
                #endif
            }
        }
        timer = clock
        #if DEBUG
        record("start", target: target)
        #endif
        RunLoop.main.add(clock, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
}

/// Measure real rows at their complete intrinsic height, then reveal that
/// height. An opacity-only removal lets the intrinsic stack jump immediately.
private struct DisclosureLayout: Layout {
    let fraction: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(.init(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * fraction)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: .init(width: bounds.width, height: nil))
    }
}

struct CollapsibleTaskSection<Content: View>: View {
    let expanded: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motion: DisclosureMotion
    init(expanded: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.expanded = expanded; self.content = content
        _motion = StateObject(wrappedValue: DisclosureMotion(expanded: expanded))
    }
    var body: some View {
        let interactive = expanded && motion.fraction == 1
        // Keep lifecycle identity even at zero height. A conditional Group
        // re-fires onAppear when rows return and would snap an opening to 1.
        VStack(alignment: .leading, spacing: 0) {
            if motion.fraction > 0 {
                DisclosureLayout(fraction: motion.fraction) { content() }
                    .clipped().opacity(Double(motion.fraction))
                    .allowsHitTesting(interactive).accessibilityHidden(!interactive)
            }
        }
        // Rendered transition rows are not interaction geometry: this key also
        // drives keyboard selection, drag targeting and native mouse guards.
        .transformPreference(TaskListRowFrame.Key.self) { frames in
            if !interactive { frames.removeAll() }
        }
        .onAppear { motion.setExpanded(expanded, reduceMotion: true) }
        .onChange(of: expanded) { value in motion.setExpanded(value, reduceMotion: LayoutMotionInputs.shouldReduceMotion(reduceMotion)) }
        .onChange(of: reduceMotion) { value in if value { motion.setExpanded(expanded, reduceMotion: true) } }
        .onDisappear { motion.stop() }
    }
}
