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
    private static func measure<V: View>(_ view: V, key: String, width: CGFloat = 64) -> Measurement {
        if let result = table[key] { return result }
        let renderer = ImageRenderer(content: view.foregroundStyle(.white).fixedSize().frame(width: width, height: 64))
        renderer.scale = 4
        let offset = renderer.cgImage.flatMap { inkBounds(of: $0) }.map { $0.midY / 4 - 32 } ?? 0
        let result = Measurement(inkOffset: offset)
        table[key] = result
        return result
    }
    static func text(_ font: NSFont, script: Script) -> Measurement { text(font, sample: script.sample) }
    static func text(_ font: NSFont, sample: String) -> Measurement {
        let cascade = (font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor] ?? []).map { String(describing: $0.object(forKey: .family)) }.joined(separator: ",")
        let width = min(320, max(8, ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 4))
        return measure(Text(sample).font(Font(font)), key: "text|\(font.fontName)|\(font.pointSize)|\(String(describing: font.fontDescriptor.object(forKey: .traits)))|\(cascade)|\(sample)", width: width)
    }
    static func symbol(_ name: String, size: CGFloat, weight: Font.Weight = .regular) -> Measurement {
        measure(Image(systemName: name).font(.system(size: size, weight: weight)).imageScale(.medium),
                key: "symbol|\(name)|\(size)|\(weight)")
    }
}

/// The visual correction stays inside the original layout and hit-test box.
struct OpticalText: View {
    let title: String
    var size: CGFloat = 13
    var weight: NSFont.Weight = .regular
    var serif = false
    var language = "en"
    var body: some View {
        let font = DotistDesign.nativeFont(size, weight: weight, serif: serif, language: language)
        Text(title).font(Font(font))
            .offset(y: OpticalMetrics.text(font, sample: title.isEmpty ? " " : title).correction)
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
            OpticalSymbol(name: "magnifyingglass", size: iconSize).foregroundStyle(DotistDesign.faint).frame(width: 20, height: 24)
            OpticalInput(text: $text, placeholder: placeholder, font: DotistDesign.nativeFont(size, language: language), focusOnAppear: focusOnAppear, identifier: identifier, commit: commit, navigate: navigate, cancel: cancel).frame(height: max(24, size * 1.5))
        }
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
