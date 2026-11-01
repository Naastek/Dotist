import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TaskRowMetadataTests: XCTestCase {
    func testMetadataKeepsItsWidthRightEdgeAndTitleGapAtEveryDepth() throws {
        var metadataWidths: [CGFloat] = []
        for depth in 0...4 {
            let renderer = ImageRenderer(content:
                TaskRowLayout(depth: depth) {
                    Rectangle().fill(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1))
                    Rectangle().fill(Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1)).frame(height: 20)
                    HStack(spacing: 8) {
                        Text("今天 · 2026-11-01 · 本周")
                        HStack(spacing: 2) {
                            Text("1/2")
                            Image(systemName: "chevron.right").font(.system(size: 8))
                        }
                    }.font(.system(size: 12)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .frame(height: 20).background(Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 1))
                }.padding(.horizontal, 16).frame(width: 364).background(Color.white)
            )
            renderer.scale = 2
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wE1-metadata-d\(depth).png")
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: path)
            var titleX: [CGFloat] = [], metaX: [CGFloat] = []
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y) else { continue }
                    if color.blueComponent > 0.9 && color.redComponent < 0.1 && color.greenComponent < 0.1 { titleX.append(CGFloat(x) / 2) }
                    if color.greenComponent > 0.9 && color.redComponent < 0.1 && color.blueComponent < 0.1 { metaX.append(CGFloat(x) / 2) }
                }
            }
            let left = try XCTUnwrap(metaX.min()), right = try XCTUnwrap(metaX.max()) + 0.5
            let titleRight = try XCTUnwrap(titleX.max()) + 0.5
            XCTAssertEqual(right, 348, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(left - titleRight, 7.5)
            metadataWidths.append(right - left)
            print("wE1 metadata depth=\(depth), right=\(right), width=\(right-left), titleGap=\(left-titleRight)")
        }
        XCTAssertGreaterThan(try XCTUnwrap(metadataWidths.first), 332 * 0.4, "Exercise metadata wider than the old compression cap")
        for width in metadataWidths { XCTAssertEqual(width, metadataWidths[0], accuracy: 0.5) }
    }

    func testMainWindowFocusedActionsLeaveProgressPixelsVisible() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wE1-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let task = try store.addTask(title: "A long title which must give its trailing metadata and actions enough space", category: DotistGroup.inboxID, dueDate: Date().dotistDay)
        for index in 0..<2 { _ = try store.addTask(title: "child \(index)", category: task.category, parentId: task.id) }
        let model = try AppModel(store: store)
        let selection = TaskSelectionController()
        var rows: [TaskListRowFrame] = []
        let content = MainWindow(model: model, state: TaskPanelState(), showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, selection: selection)
            .onPreferenceChange(TaskListRowFrame.Key.self) { rows = $0 }
            .frame(width: 364, height: 620).background(Color.white).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 364, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(rows.first { $0.task.id == task.id })
        func snapshot(_ name: String) throws -> NSBitmapImageRep {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-wE1-row-\(name).png")
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: path)
            return rep
        }
        let idle = try snapshot("idle")
        selection.row(task.id).focusRequest.send()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let focused = try snapshot("focused")
        let scale = CGFloat(idle.pixelsWide) / 364
        var progressChanges = 0, actionChanges = 0
        for y in Int(row.frame.minY * scale)..<Int(row.frame.maxY * scale) {
            for x in Int(210 * scale)..<Int(348 * scale) {
                let before = try XCTUnwrap(idle.colorAt(x: x, y: y))
                let after = try XCTUnwrap(focused.colorAt(x: x, y: y))
                let delta = abs(before.redComponent - after.redComponent) + abs(before.greenComponent - after.greenComponent) + abs(before.blueComponent - after.blueComponent)
                if delta > 0.05 {
                    if CGFloat(x) / scale >= 320 { progressChanges += 1 }
                    else if CGFloat(x) / scale < 280 { actionChanges += 1 }
                }
            }
        }
        XCTAssertEqual(progressChanges, 0, "Focusing the row must not hide or cover its progress button")
        XCTAssertGreaterThan(actionChanges, 0, "The real focused row must reveal its actions to the left")
        print("wE1 real row: progressChangedPixels=\(progressChanges), actionChangedPixels=\(actionChanges), frame=\(row.frame)")
    }
}
