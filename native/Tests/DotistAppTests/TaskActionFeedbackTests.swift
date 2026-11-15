import AppKit
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TaskActionFeedbackTests: XCTestCase {
    func testHoverAndPressPaintDistinctFeedbackWithinUnchangedButtonBounds() throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTIST_ACTION_EVIDENCE"] ?? "/tmp/dotist-action-feedback")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            for destructive in [false, true] {
                var samples: [Data] = []
                var baselineEdge: NSColor?
                for phase in 0...2 {
                    let view = TaskRowActionHighlight(active: phase > 0, pressed: phase == 2, destructive: destructive, dark: dark)
                        .frame(width: 22, height: 22).padding(4)
                        .background(dark ? Color.black : Color.gray)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let cg = try XCTUnwrap(renderer.cgImage)
                    XCTAssertEqual(cg.width, 60)
                    XCTAssertEqual(cg.height, 60)
                    let rep = NSBitmapImageRep(cgImage: cg)
                    let bytes = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    samples.append(bytes)
                    if phase == 0 { baselineEdge = try XCTUnwrap(rep.colorAt(x: 0, y: 0)) }
                    try bytes.write(to: output.appendingPathComponent("\(dark ? "dark" : "light")-\(destructive ? "delete" : "normal")-\(phase).png"))
                    // Decorative paint stays inside the original 22pt hit target.
                    for x in [0, 59] { for y in 0..<60 {
                        let edge = try XCTUnwrap(rep.colorAt(x: x, y: y))
                        let expected = try XCTUnwrap(baselineEdge)
                        XCTAssertEqual(edge.redComponent, expected.redComponent)
                        XCTAssertEqual(edge.greenComponent, expected.greenComponent)
                        XCTAssertEqual(edge.blueComponent, expected.blueComponent)
                    } }
                }
                XCTAssertNotEqual(samples[0], samples[1])
                XCTAssertNotEqual(samples[1], samples[2])
            }
        }
    }
}

extension TaskActionFeedbackTests {
    func testAccessibilityActionSurfaceRemainsOpaqueAtEveryActionCount() throws {
        for dark in [false, true] {
            for width in [22.0, 45.0, 68.0] {
                do {
                    let view = TaskRowActionBacking(color: .none, scheme: dark ? .dark : .light, opaque: true).frame(width: width, height: 22)
                    let renderer = ImageRenderer(content: view)
                    let image = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                    XCTAssertEqual(try XCTUnwrap(image.colorAt(x: Int(width / 2), y: 11)).alphaComponent, 1, accuracy: 0.01)
                }
            }
        }
    }
}
