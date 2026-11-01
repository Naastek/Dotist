import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class PanelColorTests: XCTestCase {
    private func model() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-color-wIB1-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try AppModel(store: TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    func testPanelColorSelectionPersistsAllAndGroupIndependentlyAndGroupCanUndo() async throws {
        let model = try model()
        let all = TaskPanelState()
        let work = TaskPanelState(groupID: "work")
        all.selectColor(.orange, in: model)
        try await waitUntil { model.settings.allColor == "orange" }
        XCTAssertEqual(all.selectedColor(in: model), .orange)
        XCTAssertEqual(model.themeColor(forGroup: nil), .orange)
        XCTAssertEqual(model.themeColor(forGroup: "work"), .orange)
        work.selectColor(.purple, in: model)
        try await waitUntil { !model.busy && work.selectedColor(in: model) == .purple }
        XCTAssertEqual(model.groups.first { $0.id == "work" }?.color, "purple")
        XCTAssertEqual(model.settings.allColor, "orange")
        XCTAssertEqual(model.themeColor(forGroup: "work"), .purple)
        model.undoLast()
        try await waitUntil { !model.busy && work.selectedColor(in: model) == .none }
        XCTAssertEqual(model.themeColor(forGroup: "work"), .orange)
        all.selectColor(.none, in: model)
        try await waitUntil { model.settings.allColor == "none" }
        XCTAssertEqual(model.themeColor(forGroup: nil), .none)
        XCTAssertNil(model.error)
    }

    func testSolidPaperRetainsColorInBothSchemesAndBubbleShapes() throws {
        for scheme in [ColorScheme.light, .dark] {
            for compact in [false, true] {
                func pixel(_ color: DotistGroupColor) throws -> NSColor {
                    let content = FloatingPanelSurface(opacity: 73, frost: 22, compact: compact, color: color, solid: true, scheme: scheme)
                        .frame(width: 48, height: 48)
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 1
                    let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                    return try XCTUnwrap(bitmap.colorAt(x: 24, y: 24)?.usingColorSpace(.sRGB))
                }
                let neutral = try pixel(.none)
                let orange = try pixel(.orange)
                let blue = try pixel(.blue)
                XCTAssertEqual(orange.alphaComponent, 1, accuracy: 0.01)
                XCTAssertGreaterThan(orange.redComponent - orange.blueComponent, neutral.redComponent - neutral.blueComponent + 0.015)
                XCTAssertGreaterThan(blue.blueComponent - blue.redComponent, neutral.blueComponent - neutral.redComponent + 0.015)
            }
        }
    }
}
