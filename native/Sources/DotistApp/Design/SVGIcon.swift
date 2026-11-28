import CoreGraphics
import Foundation
import SwiftUI

/// Parsed geometric SVG document for monochrome template icons loaded from
/// bundled `.svg` resources. Supports `<path>`, `<circle>`, `<rect>`, `<line>`,
/// `<polyline>`, and `<polygon>` with viewBox scaling and `currentColor` fills
/// or strokes so icons inherit SwiftUI foreground styling across appearances.
struct SVGIconDocument {
    struct Element {
        let path: CGPath
        let fills: Bool
        let evenOdd: Bool
        let strokes: Bool
        let lineWidth: CGFloat
        let lineCap: CGLineCap
        let lineJoin: CGLineJoin
    }

    let viewBox: CGRect
    let elements: [Element]

    private static var cache: [String: SVGIconDocument] = [:]
    private static let lock = NSLock()

    static func load(named name: String) -> SVGIconDocument? {
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let url = AppResources.url(forResource: name, withExtension: "svg"),
              let data = try? Data(contentsOf: url),
              let parsed = parse(data: data) else {
            return nil
        }

        lock.lock()
        cache[name] = parsed
        lock.unlock()
        return parsed
    }

    static func parse(data: Data) -> SVGIconDocument? {
        let delegate = SVGXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.elements.isEmpty else { return nil }
        return SVGIconDocument(viewBox: delegate.viewBox, elements: delegate.elements)
    }
}

struct SVGIconView: View {
    let name: String
    var size: CGFloat = 15

    var body: some View {
        let document = SVGIconDocument.load(named: name)
        ZStack {
            if let document {
                let scaleX = document.viewBox.width > 0 ? size / document.viewBox.width : 1
                let scaleY = document.viewBox.height > 0 ? size / document.viewBox.height : 1
                let uniformScale = min(scaleX, scaleY)
                let offsetX = (size - document.viewBox.width * uniformScale) / 2 - document.viewBox.minX * uniformScale
                let offsetY = (size - document.viewBox.height * uniformScale) / 2 - document.viewBox.minY * uniformScale
                let transform = CGAffineTransform(translationX: offsetX, y: offsetY)
                    .scaledBy(x: uniformScale, y: uniformScale)

                ForEach(Array(document.elements.enumerated()), id: \.offset) { _, element in
                    let swiftPath = Path(element.path).applying(transform)
                    if element.fills {
                        swiftPath.fill(style: FillStyle(eoFill: element.evenOdd))
                    }
                    if element.strokes {
                        swiftPath.stroke(
                            style: StrokeStyle(
                                lineWidth: element.lineWidth * uniformScale,
                                lineCap: element.lineCap,
                                lineJoin: element.lineJoin
                            )
                        )
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - XML & Path Parsing

private final class SVGXMLParserDelegate: NSObject, XMLParserDelegate {
    private struct InheritedStyle {
        var fill: String = "none"
        var stroke: String = "none"
        var strokeWidth: CGFloat = 1.4
        var lineCap: CGLineCap = .round
        var lineJoin: CGLineJoin = .round
        var evenOdd: Bool = false
    }

    var viewBox = CGRect(x: 0, y: 0, width: 16, height: 16)
    var elements: [SVGIconDocument.Element] = []
    private var rootStyle = InheritedStyle()

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        switch elementName {
        case "svg":
            if let box = attributes["viewBox"] {
                let values = parseNumbers(box)
                if values.count == 4, values[2] > 0, values[3] > 0 {
                    viewBox = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                }
            } else if let w = attributes["width"].flatMap(Double.init),
                      let h = attributes["height"].flatMap(Double.init),
                      w > 0, h > 0 {
                viewBox = CGRect(x: 0, y: 0, width: w, height: h)
            }
            rootStyle = mergedStyle(base: rootStyle, attributes: attributes)

        case "path":
            guard let d = attributes["d"], let path = SVGPathParser.parse(d) else { return }
            append(path: path, attributes: attributes)

        case "circle":
            let cx = CGFloat(Double(attributes["cx"] ?? "0") ?? 0)
            let cy = CGFloat(Double(attributes["cy"] ?? "0") ?? 0)
            guard let r = Double(attributes["r"] ?? ""), r > 0 else { return }
            let radius = CGFloat(r)
            let path = CGPath(ellipseIn: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2), transform: nil)
            append(path: path, attributes: attributes)

        case "ellipse":
            let cx = CGFloat(Double(attributes["cx"] ?? "0") ?? 0)
            let cy = CGFloat(Double(attributes["cy"] ?? "0") ?? 0)
            guard let rx = Double(attributes["rx"] ?? ""), let ry = Double(attributes["ry"] ?? ""), rx > 0, ry > 0 else { return }
            let path = CGPath(ellipseIn: CGRect(x: cx - CGFloat(rx), y: cy - CGFloat(ry), width: CGFloat(rx) * 2, height: CGFloat(ry) * 2), transform: nil)
            append(path: path, attributes: attributes)

        case "rect":
            let x = CGFloat(Double(attributes["x"] ?? "0") ?? 0)
            let y = CGFloat(Double(attributes["y"] ?? "0") ?? 0)
            guard let w = Double(attributes["width"] ?? ""), let h = Double(attributes["height"] ?? ""), w > 0, h > 0 else { return }
            let rx = CGFloat(Double(attributes["rx"] ?? attributes["ry"] ?? "0") ?? 0)
            let ry = CGFloat(Double(attributes["ry"] ?? attributes["rx"] ?? "0") ?? 0)
            let rect = CGRect(x: x, y: y, width: CGFloat(w), height: CGFloat(h))
            let cornerX = min(rx, rect.width / 2)
            let cornerY = min(ry, rect.height / 2)
            let path = (cornerX > 0 || cornerY > 0)
                ? CGPath(roundedRect: rect, cornerWidth: cornerX, cornerHeight: cornerY, transform: nil)
                : CGPath(rect: rect, transform: nil)
            append(path: path, attributes: attributes)

        case "line":
            let x1 = CGFloat(Double(attributes["x1"] ?? "0") ?? 0)
            let y1 = CGFloat(Double(attributes["y1"] ?? "0") ?? 0)
            let x2 = CGFloat(Double(attributes["x2"] ?? "0") ?? 0)
            let y2 = CGFloat(Double(attributes["y2"] ?? "0") ?? 0)
            let mutable = CGMutablePath()
            mutable.move(to: CGPoint(x: x1, y: y1))
            mutable.addLine(to: CGPoint(x: x2, y: y2))
            append(path: mutable, attributes: attributes)

        case "polyline", "polygon":
            let values = parseNumbers(attributes["points"] ?? "")
            guard values.count >= 4 else { return }
            let mutable = CGMutablePath()
            mutable.move(to: CGPoint(x: values[0], y: values[1]))
            var index = 2
            while index + 1 < values.count {
                mutable.addLine(to: CGPoint(x: values[index], y: values[index + 1]))
                index += 2
            }
            if elementName == "polygon" { mutable.closeSubpath() }
            append(path: mutable, attributes: attributes)

        default:
            break
        }
    }

    private func append(path: CGPath, attributes: [String: String]) {
        let style = mergedStyle(base: rootStyle, attributes: attributes)
        let fills = style.fill != "none"
        let strokes = style.stroke != "none" && style.strokeWidth > 0
        guard fills || strokes else { return }
        elements.append(
            SVGIconDocument.Element(
                path: path,
                fills: fills,
                evenOdd: style.evenOdd,
                strokes: strokes,
                lineWidth: style.strokeWidth,
                lineCap: style.lineCap,
                lineJoin: style.lineJoin
            )
        )
    }

    private func mergedStyle(base: InheritedStyle, attributes: [String: String]) -> InheritedStyle {
        var style = base
        if let fill = attributes["fill"] { style.fill = fill.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if let stroke = attributes["stroke"] { style.stroke = stroke.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if let width = attributes["stroke-width"].flatMap(Double.init) { style.strokeWidth = CGFloat(width) }
        if let cap = attributes["stroke-linecap"]?.lowercased() {
            switch cap {
            case "butt": style.lineCap = .butt
            case "square": style.lineCap = .square
            default: style.lineCap = .round
            }
        }
        if let join = attributes["stroke-linejoin"]?.lowercased() {
            switch join {
            case "miter": style.lineJoin = .miter
            case "bevel": style.lineJoin = .bevel
            default: style.lineJoin = .round
            }
        }
        if let rule = attributes["fill-rule"]?.lowercased() {
            style.evenOdd = (rule == "evenodd")
        }
        return style
    }

    private func parseNumbers(_ input: String) -> [CGFloat] {
        var numbers: [CGFloat] = []
        var scanner = SVGPathScanner(input)
        while let value = scanner.nextNumber() {
            numbers.append(value)
        }
        return numbers
    }
}

private enum SVGPathParser {
    static func parse(_ data: String) -> CGPath? {
        let path = CGMutablePath()
        var scanner = SVGPathScanner(data)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "

        while let command = scanner.nextCommand(defaultingTo: implicitFollowUp(for: lastCommand)) {
            let relative = command.isLowercase
            switch command {
            case "M", "m":
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let point = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.move(to: point)
                current = point
                subpathStart = point
                lastControl = nil

            case "L", "l":
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let point = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addLine(to: point)
                current = point
                lastControl = nil

            case "H", "h":
                guard let x = scanner.nextNumber() else { break }
                let point = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: point)
                current = point
                lastControl = nil

            case "V", "v":
                guard let y = scanner.nextNumber() else { break }
                let point = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: point)
                current = point
                lastControl = nil

            case "C", "c":
                guard let x1 = scanner.nextNumber(), let y1 = scanner.nextNumber(),
                      let x2 = scanner.nextNumber(), let y2 = scanner.nextNumber(),
                      let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let c1 = relative ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let c2 = relative ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastControl = c2

            case "S", "s":
                guard let x2 = scanner.nextNumber(), let y2 = scanner.nextNumber(),
                      let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let c1: CGPoint
                if "CcSs".contains(lastCommand), let previous = lastControl {
                    c1 = CGPoint(x: 2 * current.x - previous.x, y: 2 * current.y - previous.y)
                } else {
                    c1 = current
                }
                let c2 = relative ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastControl = c2

            case "Q", "q":
                guard let x1 = scanner.nextNumber(), let y1 = scanner.nextNumber(),
                      let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let control = relative ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addQuadCurve(to: end, control: control)
                current = end
                lastControl = control

            case "T", "t":
                guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let control: CGPoint
                if "QqTt".contains(lastCommand), let previous = lastControl {
                    control = CGPoint(x: 2 * current.x - previous.x, y: 2 * current.y - previous.y)
                } else {
                    control = current
                }
                let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addQuadCurve(to: end, control: control)
                current = end
                lastControl = control

            case "A", "a":
                guard let rx = scanner.nextNumber(), let ry = scanner.nextNumber(),
                      let rotation = scanner.nextNumber(),
                      let largeArc = scanner.nextFlag(), let sweep = scanner.nextFlag(),
                      let x = scanner.nextNumber(), let y = scanner.nextNumber() else { break }
                let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                addSVGArc(to: path, from: current, to: end, rx: rx, ry: ry, rotationDegrees: rotation, largeArc: largeArc, sweep: sweep)
                current = end
                lastControl = nil

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
                lastControl = nil

            default:
                return nil
            }
            lastCommand = command
        }

        return path.isEmpty ? nil : path
    }

    private static func implicitFollowUp(for command: Character) -> Character? {
        switch command {
        case "M": return "L"
        case "m": return "l"
        case "Z", "z", " ": return nil
        default: return command
        }
    }

    /// Standard W3C SVG 1.1 F.6.5 endpoint-to-center arc conversion, approximated
    /// with cubic Bézier segments of at most 90 degrees.
    private static func addSVGArc(
        to path: CGMutablePath,
        from start: CGPoint,
        to end: CGPoint,
        rx rawRx: CGFloat,
        ry rawRy: CGFloat,
        rotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        if start == end { return }
        var rx = abs(rawRx)
        var ry = abs(rawRy)
        guard rx > 1e-6, ry > 1e-6 else {
            path.addLine(to: end)
            return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let dx2 = (start.x - end.x) / 2
        let dy2 = (start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        let rxSq = rx * rx
        let rySq = ry * ry
        let x1pSq = x1p * x1p
        let y1pSq = y1p * y1p

        let numerator = max(0, rxSq * rySq - rxSq * y1pSq - rySq * x1pSq)
        let denominator = rxSq * y1pSq + rySq * x1pSq
        let factor = (largeArc == sweep ? -1.0 : 1.0) * sqrt(denominator > 0 ? numerator / denominator : 0)

        let cxp = factor * (rx * y1p / ry)
        let cyp = factor * (-ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func vectorAngle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = hypot(ux, uy) * hypot(vx, vy)
            guard length > 0 else { return 0 }
            let clamped = max(-1, min(1, dot / length))
            let angle = acos(clamped)
            return (ux * vy - uy * vx) < 0 ? -angle : angle
        }

        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry

        let startAngle = vectorAngle(1, 0, ux, uy)
        var deltaAngle = vectorAngle(ux, uy, vx, vy)
        if !sweep && deltaAngle > 0 { deltaAngle -= 2 * .pi }
        if sweep && deltaAngle < 0 { deltaAngle += 2 * .pi }

        let segments = max(1, Int(ceil(abs(deltaAngle) / (.pi / 2))))
        let step = deltaAngle / CGFloat(segments)

        for index in 0..<segments {
            let a1 = startAngle + CGFloat(index) * step
            let a2 = a1 + step
            let alpha = (4.0 / 3.0) * tan(step / 4.0)

            let p1x = cos(a1), p1y = sin(a1)
            let p2x = cos(a2), p2y = sin(a2)

            let c1x = p1x - alpha * p1y
            let c1y = p1y + alpha * p1x
            let c2x = p2x + alpha * p2y
            let c2y = p2y - alpha * p2x

            func mapPoint(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
                CGPoint(
                    x: cosPhi * (px * rx) - sinPhi * (py * ry) + cx,
                    y: sinPhi * (px * rx) + cosPhi * (py * ry) + cy
                )
            }

            path.addCurve(to: mapPoint(p2x, p2y), control1: mapPoint(c1x, c1y), control2: mapPoint(c2x, c2y))
        }
    }
}

private struct SVGPathScanner {
    private let scalars: [UnicodeScalar]
    private var index = 0

    init(_ string: String) {
        scalars = Array(string.unicodeScalars)
    }

    private mutating func skipSeparators() {
        while index < scalars.count {
            let ch = scalars[index]
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "," {
                index += 1
            } else {
                break
            }
        }
    }

    mutating func nextCommand(defaultingTo fallback: Character?) -> Character? {
        skipSeparators()
        guard index < scalars.count else { return nil }
        let ch = Character(scalars[index])
        if ch.isLetter {
            index += 1
            return ch
        }
        return fallback
    }

    mutating func nextFlag() -> Bool? {
        skipSeparators()
        guard index < scalars.count else { return nil }
        let ch = scalars[index]
        if ch == "0" { index += 1; return false }
        if ch == "1" { index += 1; return true }
        return nil
    }

    mutating func nextNumber() -> CGFloat? {
        skipSeparators()
        guard index < scalars.count else { return nil }
        let start = index
        if scalars[index] == "+" || scalars[index] == "-" { index += 1 }
        var hasDigits = false
        while index < scalars.count && scalars[index].value >= 48 && scalars[index].value <= 57 {
            hasDigits = true
            index += 1
        }
        if index < scalars.count && scalars[index] == "." {
            index += 1
            while index < scalars.count && scalars[index].value >= 48 && scalars[index].value <= 57 {
                hasDigits = true
                index += 1
            }
        }
        guard hasDigits else {
            index = start
            return nil
        }
        if index < scalars.count && (scalars[index] == "e" || scalars[index] == "E") {
            let expStart = index
            index += 1
            if index < scalars.count && (scalars[index] == "+" || scalars[index] == "-") { index += 1 }
            var expDigits = false
            while index < scalars.count && scalars[index].value >= 48 && scalars[index].value <= 57 {
                expDigits = true
                index += 1
            }
            if !expDigits { index = expStart }
        }
        let token = String(String.UnicodeScalarView(scalars[start..<index]))
        guard let value = Double(token) else { return nil }
        return CGFloat(value)
    }
}
