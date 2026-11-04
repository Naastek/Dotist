import AppKit
import DotistCore
import XCTest
@testable import DotistApp

@MainActor
final class PanelCollectionBehaviorTests: XCTestCase {
    func testTaskPanelsStayStationaryAndSideTabsInheritSpaceBehavior() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-stationary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let controller = GroupPanelController(model: model, groupID: "work",
            near: NSRect(x: 100, y: 100, width: 364, height: 620),
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, didClose: { _ in })
        let panel = try XCTUnwrap(controller.window as? DotistPanel)
        defer { controller.close() }
        let required: NSWindow.CollectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertTrue(panel.collectionBehavior.isSuperset(of: required))
        XCTAssertFalse(panel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(panel.collectionBehavior.contains(.managed))
        let level = panel.level
        let tabs = SideTabsController(parent: panel, model: model, state: controller.state, motion: controller.motion)
        defer { tabs.stop() }
        let child = try XCTUnwrap(panel.childWindows?.first { $0.identifier?.rawValue == "dotist.side-tabs" })
        // AppKit adds .ignoresCycle when the child adopts a floating level.
        // That independent cycling default must not weaken the space contract.
        XCTAssertEqual(child.collectionBehavior.subtracting(.ignoresCycle), panel.collectionBehavior.subtracting(.ignoresCycle))
        XCTAssertTrue(child.collectionBehavior.contains(.stationary))
        tabs.synchronize(mouse: NSPoint(x: -10_000, y: -10_000))
        XCTAssertEqual(child.collectionBehavior.subtracting(.ignoresCycle), panel.collectionBehavior.subtracting(.ignoresCycle))
        XCTAssertEqual(panel.level, level)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(child.isVisible)

        // Launching the app delegate also installs global shortcuts and opens
        // windows. Check its actual assignment without those desktop side effects.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/DotistApp/DotistApp.swift"), encoding: .utf8)
        let assignment = try XCTUnwrap(source.split(separator: "\n").first { $0.contains("panel.collectionBehavior =") })
        for option in [".stationary", ".canJoinAllSpaces", ".fullScreenAuxiliary", ".fullScreenDisallowsTiling"] {
            XCTAssertTrue(assignment.contains(option), "Main panel must retain \(option)")
        }
    }
}
