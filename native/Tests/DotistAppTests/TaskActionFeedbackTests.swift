import AppKit
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TaskActionFeedbackTests: XCTestCase {
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
