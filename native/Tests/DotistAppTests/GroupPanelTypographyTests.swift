import AppKit
import CoreText
import Combine
import DotistCore
import XCTest
import SwiftUI
@testable import DotistApp

@MainActor
final class GroupPanelTypographyTests: XCTestCase {
    func testRegisteredFontFamiliesAndMixedChineseRetainTheRequestedStyle() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repo.appendingPathComponent(".cache/native-migration/fonts")
        let names = ["SourceSans3", "SourceSerif4", "NotoSansSC", "NotoSansTC", "NotoSansJP", "NotoSerifSC", "NotoSerifTC", "NotoSerifJP"]
        guard names.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0).ttf").path) }) else {
            throw XCTSkip("Font resource cache is absent; run with the packaged font resources available")
        }
        // Exercise registration after a token was cached by a preview/test host.
        _ = DotistDesign.nativeFont(13, language: "en")
        DotistDesign.registerFonts(in: directory)
        for (language, region) in [("en", "SC"), ("zh-CN", "SC"), ("zh-TW", "TC"), ("zh-Hant", "TC"), ("ja", "JP")] {
            for serif in [false, true] {
                for weight in [NSFont.Weight.regular, .semibold] {
                    let font = DotistDesign.nativeFont(13, weight: weight, serif: serif, language: language)
                    XCTAssertEqual(font.familyName, serif ? "Newsreader" : "Atkinson Hyperlegible Next")
                    let chinese = CTFontCreateForString(font as CTFont, "中文" as CFString, CFRange(location: 0, length: 2))
                    XCTAssertEqual(CTFontCopyFamilyName(chinese) as String, "Noto \(serif ? "Serif" : "Sans") \(region)", "\(language), serif=\(serif)")
                }
            }
        }
    }

    func testAllRendersUngroupedRowsFirstAndGroupViewExcludesThem() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-ungrouped-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let group = try store.addGroup(name: "Named group")
        let grouped = try store.addTask(title: "Grouped", category: group.id)
        let ungrouped = try store.addTask(title: "Ungrouped", category: DotistGroup.inboxID)
        let model = try AppModel(store: store)
        let state = TaskPanelState()
        var rows: [TaskListRowFrame] = []
        let content = MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, primary: false)
            .frame(width: 364, height: 620)
            .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
        let host = NSHostingView(rootView: content)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let inboxRow = try XCTUnwrap(rows.first { $0.task.id == ungrouped.id })
        let groupRow = try XCTUnwrap(rows.first { $0.task.id == grouped.id })
        XCTAssertLessThan(inboxRow.frame.minY, groupRow.frame.minY)
        state.groupID = group.id
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(rows.map { $0.task.id }, [grouped.id])
    }

    func testInboxCannotCreateAnIndependentPanel() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-inbox-panel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
        let controller = GroupPanelController(model: model, groupID: DotistGroup.inboxID, near: .zero,
            showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, didClose: { _ in })
        XCTAssertNil(controller.window)
        XCTAssertNil(controller.motion)
        XCTAssertFalse(controller.compact)
        controller.toggleCompact()
        controller.closePanel()
    }

    func testShelfDropToInboxMovesTheWholeSubtreeAndSupportsUndo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-inbox-drop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let group = try store.addGroup(name: "Named group")
        let root = try store.addTask(title: "Root", category: group.id)
        let child = try store.addTask(title: "Child", category: group.id, parentId: root.id)
        let model = try AppModel(store: store)
        model.beginDrag(root.id, scope: "list:all")
        let target = TaskReorderEngine.Target(groupID: DotistGroup.inboxID, slot: Int.max, level: 0, parentID: nil, beforeID: nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            model.commitReorder(taskID: root.id, to: target, completed: {
                model.endDrag()
                continuation.resume()
            }, failed: {
                model.endDrag()
                XCTFail(model.error ?? "Inbox drop failed")
                continuation.resume()
            })
        }
        XCTAssertEqual(model.ungroupedTasks.map(\.id), [root.id])
        XCTAssertFalse(model.visibleGroups.contains { $0.id == DotistGroup.inboxID })
        XCTAssertEqual(model.tasks.first { $0.id == child.id }?.parentId, root.id)
        XCTAssertTrue(model.tasks.filter { [root.id, child.id].contains($0.id) }.allSatisfy { $0.category == DotistGroup.inboxID })
        XCTAssertNil(model.dragId)
        XCTAssertTrue(model.canUndoAction)
        model.undoLast()
        let restored = expectation(description: "Undo restores the complete subtree to its group")
        let observation = model.$tasks.sink { tasks in
            if tasks.filter({ [root.id, child.id].contains($0.id) }).allSatisfy({ $0.category == group.id }) { restored.fulfill() }
        }
        await fulfillment(of: [restored], timeout: 3)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(model.tasks.first { $0.id == child.id }?.parentId, root.id)
    }
}
