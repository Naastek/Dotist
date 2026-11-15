import AppKit
import XCTest
@testable import DotistApp

@MainActor
final class NativeActionPaintTests: XCTestCase {
    func testLiveNativePaintDistinguishesStatesWithoutChangingHitArea() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: "/tmp/dotist-native-action-paint")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            for symbol in ["plus", "calendar", "xmark"] {
                let button = TaskNativeAction.Button(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
                button.actionSymbol = symbol
                button.destructive = symbol == "xmark"
                button.eligible = true
                button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                var samples: [Data] = []
                for phase in 0...2 {
                    button.hovered = phase > 0
                    button.highlight(phase == 2)
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 44,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    let transform = NSAffineTransform()
                    transform.scale(by: 2)
                    // 模拟真实 AppKit 绘制上下文的翻转，不能只缩放后直接调用 draw。
                    if button.isFlipped {
                        transform.translateX(by: 0, yBy: button.bounds.height)
                        transform.scaleX(by: 1, yBy: -1)
                    }
                    transform.concat()
                    button.effectiveAppearance.performAsCurrentDrawingAppearance {
                        (dark ? NSColor.darkGray : NSColor.white).setFill()
                        button.bounds.fill()
                        button.draw(button.bounds)
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    samples.append(data)
                    try data.write(to: output.appendingPathComponent("\(dark)-\(symbol)-\(phase).png"))
                    XCTAssertEqual(button.bounds.size, NSSize(width: 22, height: 22))
                }
                XCTAssertNotEqual(samples[0], samples[1])
                XCTAssertNotEqual(samples[1], samples[2])
            }
        }
    }
}
