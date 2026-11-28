import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class NativeFloatingGlassTests: XCTestCase {
    func testPanelReusesSystemGlassAcrossAllThreeForms() async throws {
        let size = CGSize(width: 364, height: 440)
        func surface(_ size: CGSize, material: DotistPanelMaterial, compact: Bool, reveal: CGFloat, transitioning: Bool = false) -> some View {
            FloatingSurface(material: material, compact: compact, transitioning: transitioning,
                onRight: true, size: size, reveal: reveal, color: .orange)
            .frame(width: size.width, height: size.height)
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._colorSchemeContrast, .standard)
        }
        let fixture = NativeRenderingFixture(surface(size, material: .regular, compact: false, reveal: 0), size: size)
        defer { fixture.close() }

        func installedGlass() throws -> NSGlassEffectView {
            let views = fixture.descendants(NSGlassEffectView.self)
            XCTAssertEqual(views.count, 1)
            return try XCTUnwrap(views.first)
        }

        _ = try await fixture.capture(scale: 1)
        let glass = try installedGlass()
        XCTAssertEqual(glass.style, .regular)
        XCTAssertNotNil(glass.tintColor)
        XCTAssertNil(glass.hitTest(CGPoint(x: 20, y: 20)))

        let middle = CGSize(width: 180, height: 230)
        let ball = CGSize(width: 48, height: 48)
        let strip = CGSize(width: 182, height: 48)
        let forms: [(CGSize, DotistPanelMaterial, Bool, CGFloat, Bool, NSGlassEffectView.Style)] = [
            (middle, .regular, true, 0, true, .clear),
            (ball, .regular, true, 0, false, .clear),
            (strip, .regular, true, 1, false, .clear),
            (ball, .regular, true, 0, false, .clear),
            (middle, .regular, false, 0, true, .regular),
            (size, .regular, false, 0, false, .regular),
            (size, .clear, false, 0, false, .clear),
        ]
        for (bounds, material, compact, reveal, transitioning, expectedStyle) in forms {
            fixture.host.rootView = surface(bounds, material: material, compact: compact, reveal: reveal, transitioning: transitioning)
            _ = try await fixture.capture(scale: 1)
            XCTAssertTrue(try installedGlass() === glass)
            XCTAssertEqual(glass.style, expectedStyle)
            XCTAssertEqual(glass.bounds.width, bounds.width - 4, accuracy: 0.5)
            XCTAssertEqual(glass.bounds.height, bounds.height - 4, accuracy: 0.5)
        }
    }

    func testCalendarKeepsItsOpaquePaperWithoutPanelGlass() async throws {
        let model = try AppModel(store: TaskStore(databasePath: ":memory:"))
        let calendar = RangeCalendar(model: model, start: "2026-11-23", end: "2026-11-23",
            choose: { _, _ in }, close: {})
        let fixture = NativeRenderingFixture(calendar, size: CGSize(width: 344, height: 360))
        defer { fixture.close() }

        let image = try await fixture.capture(scale: 1)
        XCTAssertTrue(fixture.descendants(NSGlassEffectView.self).isEmpty)
        for x in [4, 340] {
            XCTAssertEqual(try XCTUnwrap(image.colorAt(x: x, y: image.pixelsHigh / 2)).alphaComponent,
                1, accuracy: 0.01)
        }
    }
}
