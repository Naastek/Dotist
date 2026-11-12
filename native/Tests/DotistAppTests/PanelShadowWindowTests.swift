import AppKit
import DotistCore
import XCTest
@testable import DotistApp

@MainActor
final class PanelShadowWindowTests: XCTestCase {
    func testChildPlacementTranslationAndResize() {
        let parent = CGRect(x: 200, y: 300, width: 400, height: 500)
        let child = CGRect(x: 150, y: 250, width: 500, height: 600)
        let original = ChildFramePlacement(child: child, parent: parent)
        let movedParent = parent.offsetBy(dx: 30, dy: -20)
        XCTAssertEqual(original, ChildFramePlacement(child: child.offsetBy(dx: 30, dy: -20), parent: movedParent))
        var resizedParent = movedParent
        resizedParent.size.width += 1
        XCTAssertNotEqual(original, ChildFramePlacement(child: child.offsetBy(dx: 30, dy: -20), parent: resizedParent))
    }

    func testCombinedSilhouetteAndGrowingFrame() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-tabs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let panel = DotistPanel(contentRect: NSRect(x: 300, y: 200, width: 364, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" })
        defer { motion.stop(); panel.close() }
        let shadow = try XCTUnwrap(motion.shadowController)
        let originalFrame = shadow.window.frame
        let oldPath = try XCTUnwrap(shadow.window.contentView?.layer?.sublayers?.first?.shadowPath)
        let panelScreenX = oldPath.boundingBoxOfPath.maxX + originalFrame.minX
        shadow.setTabRects([CGRect(x: -120, y: 450, width: 120, height: 34)])
        XCTAssertEqual(shadow.window.frame.minX, panel.frame.minX - 120 - 48)
        let path = try XCTUnwrap(shadow.window.contentView?.layer?.sublayers?.first?.shadowPath)
        XCTAssertEqual(path.boundingBoxOfPath.maxX + shadow.window.frame.minX, panelScreenX, accuracy: 0.001)
        let x = panel.frame.minX - shadow.window.frame.minX
        let y = panel.frame.minY - shadow.window.frame.minY + 450
        XCTAssertTrue(path.contains(CGPoint(x: x - 60, y: y + 17)))
        XCTAssertTrue(path.contains(CGPoint(x: x + 50, y: y + 17)))
        for offset in stride(from: 1.0, through: 33.0, by: 1.0) {
            XCTAssertTrue(path.contains(CGPoint(x: x, y: y + offset)), "joint y=\(offset)")
        }
        let mask = try XCTUnwrap((shadow.window.contentView?.layer?.mask as? CAShapeLayer)?.path)
        XCTAssertFalse(mask.contains(CGPoint(x: x - 60, y: y + 17), using: .evenOdd))
        motion.toggleBubble(in: CGRect(x: 0, y: 0, width: 1600, height: 1000), animated: false)
        XCTAssertEqual(shadow.window.frame, PanelShadowController.frame(for: panel.frame))
    }
    func testOnlyPaintedVisibleOutwardTabsParticipate() {
        let panel = CGRect(x: 300, y: 200, width: 364, height: 620)
        let bounds = CGRect(x: 280, y: 600, width: 20, height: 74)
        let rows = [
            SideTabLayout(id: "a", groupID: nil, name: "a", rect: CGRect(x: 0, y: 40, width: 20, height: 34), fullWidth: 20, dragged: false, opacity: 1),
            SideTabLayout(id: "b", groupID: nil, name: "b", rect: CGRect(x: 0, y: 0, width: 20, height: 34), fullWidth: 20, dragged: false, opacity: 0)
        ]
        func tabs(_ painted: Bool, _ visible: Bool, _ inward: Bool) -> [CGRect] {
            SideTabGeometry.shadowRects(rows: rows, bounds: bounds, panel: panel, painted: painted, visible: visible, inward: inward)
        }
        XCTAssertEqual(tabs(true, true, false), [CGRect(x: -20, y: 440, width: 23, height: 34)])
        XCTAssertTrue(tabs(false, true, false).isEmpty)
        XCTAssertTrue(tabs(true, false, false).isEmpty)
        XCTAssertTrue(tabs(true, true, true).isEmpty)
    }
    func testShadowGeometryMaskAndStopWithoutOrderingWindows() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shadow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let panel = DotistPanel(contentRect: NSRect(x: 100, y: 200, width: 364, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let motion = PanelMotion(model: model, panel: panel, size: panel.frame.size, title: { "" })
        let shadow = try XCTUnwrap(motion.shadowController)
        XCTAssertEqual(shadow.window.frame, panel.frame.insetBy(dx: -48, dy: -48))
        XCTAssertTrue(shadow.window.ignoresMouseEvents)
        XCTAssertFalse(shadow.window.hasShadow)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertTrue(try XCTUnwrap(shadow.displayLink).isPaused)
        XCTAssertFalse(shadow.window.canBecomeKey)
        XCTAssertFalse(shadow.window.canBecomeMain)
        let layers = try XCTUnwrap(shadow.window.contentView?.layer?.sublayers)
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers[0].shadowRadius, 24)
        let dark = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        XCTAssertEqual(layers[0].shadowOpacity, dark ? 0.36 : 0.20, accuracy: 0.001)
        let mask = try XCTUnwrap(shadow.window.contentView?.layer?.mask as? CAShapeLayer)
        let path = try XCTUnwrap(mask.path)
        XCTAssertFalse(path.contains(CGPoint(x: 48 + panel.frame.width / 2, y: 48 + panel.frame.height / 2), using: .evenOdd))
        XCTAssertTrue(path.contains(CGPoint(x: 1, y: 1), using: .evenOdd))
        let width = Int(shadow.window.frame.width), height = Int(shadow.window.frame.height)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.addPath(path); bitmap.setFillColor(NSColor.white.cgColor); bitmap.drawPath(using: .eoFill)
        let bytes = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(bytes[(height / 2 * width + width / 2) * 4 + 3], 0)
        XCTAssertEqual(bytes[(width + 1) * 4 + 3], 255)
        panel.setFrame(NSRect(x: 210, y: 250, width: 400, height: 500), display: false)
        XCTAssertEqual(shadow.window.frame, panel.frame.insetBy(dx: -48, dy: -48))
        motion.stop()
        XCTAssertFalse(shadow.window.isVisible)
        XCTAssertFalse(panel.childWindows?.contains { $0 === shadow.window } ?? false)
        let stoppedFrame = shadow.window.frame
        panel.setFrameOrigin(NSPoint(x: 300, y: 300))
        shadow.synchronize()
        XCTAssertEqual(shadow.window.frame, stoppedFrame)
    }
    func testFloatingWindowActiveAppearanceSelector() {
        _ = NSApplication.shared
        let windows: [NSWindow] = [DotistPanel(), SideTabsPanel(), ViewsGlassWindow()]
        let selector = NSSelectorFromString("_hasActiveAppearance")
        for window in windows {
            window.isReleasedWhenClosed = false
            XCTAssertTrue(window.responds(to: selector))
            typealias Method = @convention(c) (AnyObject, Selector) -> Bool
            let method = unsafeBitCast(window.method(for: selector), to: Method.self)
            XCTAssertTrue(method(window, selector))
            window.close()
        }
    }

    func testViewsShadowGeometryAndTeardown() throws {
        _ = NSApplication.shared
        let parent = ViewsGlassWindow(contentRect: NSRect(x: 100, y: 200, width: 700, height: 500), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let shadow = ViewsShadowController(parent: parent)
        XCTAssertEqual(shadow.window.frame, PanelShadowController.frame(for: parent.frame))
        XCTAssertTrue(shadow.window.ignoresMouseEvents)
        XCTAssertFalse(shadow.window.canBecomeKey)
        XCTAssertFalse(shadow.window.canBecomeMain)
        let shape = ViewsShadowController.silhouette(size: parent.frame.size, accessible: false)
        let clearance = ExpandedReadingMaterial.opticalClearance
        XCTAssertEqual(shape.rect, CGRect(x: 48, y: 48, width: parent.frame.width, height: parent.frame.height).insetBy(dx: clearance, dy: clearance))
        XCTAssertEqual(shape.radius, DotistDesign.windowCornerRadius - clearance)
        let accessible = ViewsShadowController.silhouette(size: parent.frame.size, accessible: true)
        XCTAssertEqual(accessible.rect, CGRect(x: 48, y: 48, width: parent.frame.width, height: parent.frame.height))
        XCTAssertEqual(accessible.radius, DotistDesign.windowCornerRadius)
        let layer = try XCTUnwrap(shadow.window.contentView?.layer?.sublayers?.first)
        let actual = ViewsShadowController.silhouette(size: parent.frame.size, accessible: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        XCTAssertEqual(try XCTUnwrap(layer.shadowPath).boundingBoxOfPath, actual.rect)
        parent.setFrame(NSRect(x: 200, y: 300, width: 800, height: 600), display: false)
        XCTAssertEqual(shadow.window.frame, PanelShadowController.frame(for: parent.frame))
        parent.close()
        XCTAssertFalse(parent.childWindows?.contains { $0 === shadow.window } ?? false)
    }

    func testShadowlessWindowDoesNotStartRefreshDriver() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        let view = ShadowInvalidationView(frame: .zero)
        window.contentView = view
        view.refresh()
        XCTAssertFalse(view.hasRefreshDriver)
        view.stop()
        window.close()
    }

}
