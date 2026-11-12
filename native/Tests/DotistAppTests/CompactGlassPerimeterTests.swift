import AppKit
import SwiftUI
import XCTest
@testable import DotistApp

/// The custom edge light must exist where the slab catches light, and must never
/// close into a line around the whole shape: a closed rim reads as an outline,
/// whatever its colour. (The former continuous white perimeter compensated for
/// inactive glass losing its edge; glass now always has active appearance.)
@MainActor
final class CompactGlassPerimeterTests: XCTestCase {
    func testCompactEdgeLightIsPartialAndNeverAClosedOutline() throws {
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(48), 96, 144, 240, 440] {
                for scale in [CGFloat(1), 2] {
                    let size = CGSize(width: width, height: 48)
                    let image = try render(GlassEdge(cornerRadius: 24, compact: true, scheme: scheme)
                        .frame(width: width, height: 48), size: size, scale: scale)
                    let path = RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .path(in: CGRect(origin: .zero, size: size)).cgPath
                    // The neighborhood includes the inward stroke and tolerates
                    // antialiasing at 1x without relying on one edge pixel.
                    var peaks: [CGFloat] = []
                    for point in perimeterPoints(path) {
                        var peak: CGFloat = 0
                        let reach = Int(ceil(scale * 1.5))
                        for dy in -reach...reach {
                            for dx in -reach...reach {
                                let x = Int(point.x * scale) + dx
                                let y = Int(point.y * scale) + dy
                                guard (0..<image.pixelsWide).contains(x), (0..<image.pixelsHigh).contains(y) else { continue }
                                let pixel = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                                // Premultiplied white contribution: a black edge
                                // cannot satisfy the continuity requirement.
                                peak = max(peak, min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) * pixel.alphaComponent)
                            }
                        }
                        peaks.append(peak)
                    }
                    let context = "\(scheme), width \(width), scale \(scale)"
                    XCTAssertGreaterThanOrEqual(peaks.max() ?? 0, 0.05, "The lit edge needs a visible highlight: \(context)")
                    XCTAssertLessThanOrEqual(peaks.min() ?? 1, 0.02, "The highlight must fade out somewhere on the perimeter: \(context)")
                    if width >= 144 {
                        // The middle of both straight edges carries no light at all, so the
                        // lit ends can never join into a line around the shape.
                        for row in [0, Int(48 * scale) - 1] {
                            var edge: CGFloat = 0
                            for dy in 0...Int(ceil(scale * 2)) {
                                let y = row == 0 ? dy : row - dy
                                let pixel = try XCTUnwrap(image.colorAt(x: Int(width * scale / 2), y: y)?.usingColorSpace(.sRGB))
                                edge = max(edge, min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) * pixel.alphaComponent)
                            }
                            XCTAssertLessThanOrEqual(edge, 0.02, "Edge light at the middle of a straight edge: \(context)")
                        }
                    }
                    XCTAssertLessThan(try XCTUnwrap(image.colorAt(x: Int(width * scale / 2), y: Int(24 * scale))).alphaComponent, 0.01,
                        "The edge light must leave the interior clear")
                }
            }
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, scale: CGFloat) throws -> NSBitmapImageRep {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.render { _, draw in draw(context) }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
    }

    private func perimeterPoints(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        var current = CGPoint.zero, start = CGPoint.zero
        path.applyWithBlock { element in
            let e = element.pointee
            let from = current
            switch e.type {
            case .moveToPoint:
                current = e.points[0]; start = current; points.append(current)
            case .addLineToPoint, .closeSubpath:
                let end = e.type == .closeSubpath ? start : e.points[0]
                for step in 1...32 {
                    let t = CGFloat(step) / 32
                    points.append(CGPoint(x: from.x + (end.x - from.x) * t, y: from.y + (end.y - from.y) * t))
                }
                current = end
            case .addCurveToPoint:
                let a = e.points[0], b = e.points[1], end = e.points[2]
                for step in 1...32 {
                    let t = CGFloat(step) / 32, u = 1 - t
                    points.append(CGPoint(x: u*u*u*from.x + 3*u*u*t*a.x + 3*u*t*t*b.x + t*t*t*end.x,
                        y: u*u*u*from.y + 3*u*u*t*a.y + 3*u*t*t*b.y + t*t*t*end.y))
                }
                current = end
            case .addQuadCurveToPoint:
                let a = e.points[0], end = e.points[1]
                for step in 1...32 {
                    let t = CGFloat(step) / 32, u = 1 - t
                    points.append(CGPoint(x: u*u*from.x + 2*u*t*a.x + t*t*end.x,
                        y: u*u*from.y + 2*u*t*a.y + t*t*end.y))
                }
                current = end
            @unknown default: break
            }
        }
        return points
    }
}
