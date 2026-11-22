import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class RovingTaskFocusTests: XCTestCase {
    func testOnlyOneRowIsFocusableAtATimeAcrossInitialLoadNavigationAndRemoval() {
        let controller = TaskSelectionController()
        let ids = (0..<150).map { "task-\($0)" }
        let rows = ids.map { controller.row($0) }

        // Only the first row is initially focusable (Tab entry point).
        XCTAssertEqual(controller.focusTargetID, ids[0])
        XCTAssertEqual(rows.filter(\.focusable).map(\.id), [ids[0]])

        // Arrow navigation / off-viewport jump moves focusable cleanly to target row.
        controller.row(ids[120]).focusRequest.send()
        XCTAssertEqual(controller.focusTargetID, ids[120])
        XCTAssertEqual(rows.filter(\.focusable).map(\.id), [ids[120]])

        // Moving to adjacent row keeps exactly one focusable row.
        controller.row(ids[121]).focusRequest.send()
        XCTAssertEqual(controller.focusTargetID, ids[121])
        XCTAssertEqual(rows.filter(\.focusable).map(\.id), [ids[121]])

        // Removing the focused row from the visible order promotes the first visible row.
        let remaining = ids.filter { $0 != ids[121] }
        controller.ensureValidFocusTarget(in: remaining)
        XCTAssertEqual(controller.focusTargetID, remaining[0])
        XCTAssertEqual(rows.filter(\.focusable).map(\.id), [remaining[0]])

        // Empty list clears focus target cleanly without crashing.
        controller.ensureValidFocusTarget(in: [])
        XCTAssertNil(controller.focusTargetID)
        XCTAssertTrue(rows.allSatisfy { !$0.focusable })
    }

    func testOffViewportFocusRequestScrollsAndPromotesTargetRow() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-roving-nav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try TaskStore(databasePath: dir.appendingPathComponent("tasks.sqlite").path)
        var ids: [String] = []
        for i in 0..<60 {
            ids.append(try store.addTask(title: "row \(i)", category: DotistGroup.inboxID).id)
        }
        let model = try AppModel(store: store)
        let selection = TaskSelectionController()
        let view = MainWindow(model: model, state: TaskPanelState(), showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, selection: selection)
            .frame(width: 364, height: 320)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 364, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))

        // Initially only the first row is focusable.
        XCTAssertEqual(ids.filter { selection.row($0).focusable }.count, 1)

        // Jump to an off-viewport row (#50).
        let target = ids[50]
        var navigated: [String] = []
        let token = selection.navigation.sink { navigated.append($0) }
        defer { token.cancel() }
        selection.row(target).focusRequest.send()
        selection.navigation.send(target)
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(selection.focusTargetID, target)
        XCTAssertEqual(ids.filter { selection.row($0).focusable }, [target])
        XCTAssertEqual(navigated, [target])
    }
}
