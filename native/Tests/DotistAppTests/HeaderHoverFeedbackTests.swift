import AppKit
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class HeaderHoverFeedbackTests: XCTestCase {
    func testRenderedBackgroundStatesAndWideCoverage() throws {
        for dark in [false, true] {
            for width in [24.0, 84.0] {
                var levels: [CGFloat] = []
                for phase in 0...3 {
                    let view = HeaderHoverFeedback(hovered: phase > 0, pressed: phase == 2)
                        .frame(width: width, height: 24)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.isEnabled, phase != 3)
                        .background(dark ? Color.black : Color.white)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                    let center = try XCTUnwrap(image.colorAt(x: Int(width), y: 24)?.usingColorSpace(.deviceRGB))
                    levels.append(center.redComponent)
                    if phase == 1 && width == 84 {
                        // 左侧图标及右侧文字区域都须有反馈，不能局限在中心24pt。
                        for x in [28, 140] {
                            let pixel = try XCTUnwrap(image.colorAt(x: x, y: 24)?.usingColorSpace(.deviceRGB))
                            if dark { XCTAssertGreaterThan(pixel.redComponent, 0.01) }
                            else { XCTAssertLessThan(pixel.redComponent, 0.99) }
                        }
                    }
                }
                XCTAssertEqual(levels[3], levels[0], accuracy: 0.005, "禁用背景与静止一致")
                if dark {
                    XCTAssertGreaterThan(levels[1], levels[0])
                    XCTAssertGreaterThan(levels[2], levels[1])
                } else {
                    XCTAssertLessThan(levels[1], levels[0])
                    XCTAssertLessThan(levels[2], levels[1])
                }
            }
        }
    }
}
