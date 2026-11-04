import AppKit
import SwiftUI
import XCTest
@testable import DotistApp

/// Sample painted pixels, not model frames: AppKit's frame can already be at
/// the destination while SwiftUI is still presenting the preceding frame.
@MainActor final class TaskDragFlowTests: XCTestCase {
    final class State: ObservableObject { @Published var gap: CGFloat = 64 }
    struct Flow: View {
        @ObservedObject var state: State
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: state.gap)
                GroupCollapseHeader(title: "work", language: "en", collapsed: false, hovered: false, toggle: {})
                Color.red.frame(height: 32)
            }.frame(width: 240, height: 200, alignment: .topLeading).background(Color.white)
                .environment(\.colorScheme, .light)
        }
    }
    func testHeaderInkAndTaskPixelsShareEveryAnimationFrame() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
        let state = State()
        let fixture = NativeRenderingFixture(Flow(state: state), size: CGSize(width: 240, height: 200))
        defer { fixture.close() }
        _ = try await fixture.capture(scale: 1)
        try await Task.sleep(for: .milliseconds(60))
        _ = try await fixture.capture(scale: 1)
        withAnimation(.linear(duration: 0.4)) { state.gap = 0 }
        let evidence = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTIST_DRAG_EVIDENCE"] ?? "/tmp/dotist-drag-renderings")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        var samples = ["frame\theaderY\ttaskY"]
        for index in 0..<24 {
            let image = try await fixture.capture(scale: 1)
            try image.representation(using: .png, properties: [:])?.write(to: evidence.appendingPathComponent("flow-current.png"))
            var ink: [Int] = [], task: [Int] = []
            for y in 0..<image.pixelsHigh {
                for x in 0..<60 {
                    guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if c.redComponent - c.greenComponent > 0.5 && c.redComponent - c.blueComponent > 0.5 { task.append(y) }
                    if max(c.redComponent, c.greenComponent, c.blueComponent) < 0.5 { ink.append(y) }
                }
            }
            let top = try XCTUnwrap(ink.min()), bottom = try XCTUnwrap(ink.max())
            let row = try XCTUnwrap(task.min())
            samples.append("\(index)\t\(top)\t\(row)")
            XCTAssertLessThan(bottom, row, "Heading ink must never overlap the following task")
            XCTAssertEqual(CGFloat(top + bottom) / 2, CGFloat(row) - 15.5, accuracy: 1.5,
                           "The heading and task must share their presentation displacement")
            if index == 2 || index == 12 {
                try image.representation(using: .png, properties: [:])?.write(to:
                    evidence.appendingPathComponent("header-flow-\(index).png"))
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        try samples.joined(separator: "\n").write(to: evidence.appendingPathComponent("header-flow.tsv"), atomically: true, encoding: .utf8)
        XCTAssertFalse(fixture.window.isVisible)
    }
}
