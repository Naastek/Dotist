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
                let window = NSWindow(contentRect: button.bounds, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = button
                defer { window.contentView = nil }
                var samples: [Data] = []
                var backgroundLevels: [CGFloat] = []
                var focusPixels: [[CGFloat]] = []
                for phase in 0...4 {
                    button.isEnabled = phase != 3
                    button.hovered = (1...3).contains(phase)
                    if phase == 4 { XCTAssertTrue(window.makeFirstResponder(button)) }
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
                    if symbol == "plus" {
                        // x=4pt 位于横笔画之外、柔边反馈内部，独立验证背景方向。
                        let pixel = try XCTUnwrap(rep.colorAt(x: 8, y: 22)?.usingColorSpace(.deviceRGB))
                        backgroundLevels.append(pixel.redComponent)
                        focusPixels.append(try [4, 39].map { y in
                            try XCTUnwrap(rep.colorAt(x: 22, y: y)?.usingColorSpace(.deviceRGB)).redComponent
                        })
                    }
                    try data.write(to: output.appendingPathComponent("\(dark)-\(symbol)-\(phase).png"))
                    XCTAssertEqual(button.bounds.size, NSSize(width: 22, height: 22))
                }
                if symbol == "plus" {
                    XCTAssertEqual(backgroundLevels[3], backgroundLevels[0], accuracy: 0.005, "禁用不绘制背景")
                    XCTAssertEqual(backgroundLevels[4], backgroundLevels[0], accuracy: 0.005, "仅键盘焦点不点亮背景")
                    XCTAssertTrue(zip(focusPixels[4], focusPixels[0]).contains { abs($0 - $1) > 0.02 },
                                  "键盘焦点必须在按钮边缘留下短线像素")
                    if dark {
                        XCTAssertGreaterThan(backgroundLevels[1], backgroundLevels[0])
                        XCTAssertGreaterThan(backgroundLevels[2], backgroundLevels[1])
                    } else {
                        XCTAssertLessThan(backgroundLevels[1], backgroundLevels[0])
                        XCTAssertLessThan(backgroundLevels[2], backgroundLevels[1])
                    }
                }
                XCTAssertNotEqual(samples[0], samples[1])
                XCTAssertNotEqual(samples[1], samples[2])
            }
        }
    }
}
