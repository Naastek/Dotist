import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class PanelShadowTests: XCTestCase {
    func testRenderedShadowExtendsOutsideBothShapesAndLeavesTheGlassInteriorTransparent() throws {
        for (compact, width, reveal, onRight) in [(false, 364.0, 0.0, true), (true, 48, 0, true),
                                                  (true, 280, 0, true), (true, 280, 0, false),
                                                  (true, 280, 0.5, true), (true, 280, 1, true)] {
            for scheme in [ColorScheme.light, .dark] {
                let state = PanelShadowState()
                state.compact = compact
                state.reveal = reveal
                state.onRight = onRight
                let size = NSSize(width: width, height: compact ? 48 : 620)
                let renderer = ImageRenderer(content: PanelShadowView(state: state)
                    .frame(width: size.width + 96, height: size.height + 96)
                    .environment(\.colorScheme, scheme))
                renderer.scale = 1
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                func alpha(_ x: Int, _ y: Int) throws -> CGFloat { try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent }
                let surfaceWidth = compact ? 48 + (width - 48) * reveal : width
                let surfaceMinX = 48 + (onRight ? width - surfaceWidth : 0)
                let centerX = Int(surfaceMinX + surfaceWidth / 2)
                XCTAssertLessThan(try alpha(centerX, Int(48 + size.height / 2)), 0.01, "The shadow must not darken the glass interior")
                XCTAssertGreaterThan(try alpha(centerX, Int(48 + size.height + 4)), 0.04, "The lower shadow must survive the window boundary")
                XCTAssertGreaterThan(try alpha(Int(surfaceMinX - 4), Int(48 + size.height / 2)), 0.01)
                XCTAssertLessThan(try alpha(centerX, Int(size.height + 95)), 0.01, "The transparent margin must contain the shadow's falloff")
                if compact && width == 280 && reveal == 0 {
                    let unusedX = onRight ? 100 : 280
                    XCTAssertLessThan(try alpha(unusedX, 72), 0.01, "The shadow must follow the revealed surface, not the full hover window")
                }
            }
        }
    }

    func testShadowHasTransparentMarginAndFollowsThePanelWithoutChangingItsHitArea() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-shadow-wJ3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let original = NSRect(x: 200, y: 200, width: 364, height: 620)
        let panel = DotistPanel(contentRect: original, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let motion = PanelMotion(model: model, panel: panel, size: original.size, title: { model.bubbleTitle })
        defer { motion.stop(); panel.close() }
        motion.refreshShadow()
        let shadow = try XCTUnwrap(panel.childWindows?.first)
        XCTAssertTrue(panel.hasShadow)
        XCTAssertTrue(shadow.ignoresMouseEvents)
        XCTAssertFalse(shadow.hasShadow)
        XCTAssertFalse(shadow.canBecomeKey)
        XCTAssertFalse(shadow.canBecomeMain)
        XCTAssertTrue(shadow.frame.contains(panel.frame))
        XCTAssertGreaterThanOrEqual(panel.frame.minX - shadow.frame.minX, 40)
        XCTAssertEqual(panel.frame, original)

        for frame in [NSRect(x: 300, y: 250, width: 400, height: 500),
                      NSRect(x: 410, y: 380, width: 48, height: 48),
                      NSRect(x: 178, y: 380, width: 280, height: 48)] {
            panel.setFrame(frame, display: true)
            XCTAssertEqual(shadow.frame.midX, panel.frame.midX, accuracy: 0.1)
            XCTAssertEqual(shadow.frame.midY, panel.frame.midY, accuracy: 0.1)
            XCTAssertEqual(shadow.frame.width - panel.frame.width, 96, accuracy: 0.1)
            XCTAssertEqual(shadow.frame.height - panel.frame.height, 96, accuracy: 0.1)
        }
        motion.stop()
        XCTAssertNil(shadow.parent)
        XCTAssertTrue(panel.childWindows?.isEmpty ?? true)
    }
}
