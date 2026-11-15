import AppKit
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TaskHeaderStabilityTests: XCTestCase {
    private struct Frames: PreferenceKey {
        static var defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
    }
    private func content(expanded: Bool, reserved: CGFloat = 126, frames: @escaping ([String: CGRect]) -> Void) -> some View {
        HeaderClusterLayout(reservedWindowWidth: reserved) {
            Color.clear.frame(width: 0, height: 24)
            HStack(spacing: 1) {
                if expanded { Color.gray.frame(width: 100, height: 24) }
                Color.blue.frame(width: 24, height: 24)
                    .background(GeometryReader { proxy in Color.clear.preference(key: Frames.self, value: ["filter": proxy.frame(in: .named("header"))]) })
            }
            HStack(spacing: 1) {
                if expanded { Color.gray.frame(width: 100, height: 24) }
                Color.gray.frame(width: 24, height: 24)
            }.background(GeometryReader { proxy in Color.clear.preference(key: Frames.self, value: ["window": proxy.frame(in: .named("header"))]) })
        }.coordinateSpace(name: "header").onPreferenceChange(Frames.self, perform: frames)
    }
    func testRenderedFilterAnchorSurvivesHoverExpansionAtBothPanelWidths() async throws {
        for width in [408.0, 432.0] {
            var measured: [String: CGRect] = [:]
            let fixture = NativeRenderingFixture(content(expanded: false) { measured = $0 }, size: CGSize(width: width - 26, height: 24))
            defer { fixture.close() }
            try await Task.sleep(for: .milliseconds(100))
            let first = try XCTUnwrap(measured["filter"])
            let originalWindow = try XCTUnwrap(measured["window"])
            fixture.host.rootView = content(expanded: true) { measured = $0 }
            fixture.host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let second = try XCTUnwrap(measured["filter"])
            XCTAssertGreaterThan(try XCTUnwrap(measured["window"]).width, originalWindow.width + 90)
            XCTAssertEqual(first.minX, second.minX, accuracy: 0.5)
            XCTAssertEqual(first.width, second.width, accuracy: 0.5)
            XCTAssertFalse(fixture.window.isVisible)
        }
    }
    func testUnreservedLayoutControlDetectsAnchorMovement() async throws {
        var measured: [String: CGRect] = [:]
        let fixture = NativeRenderingFixture(content(expanded: false, reserved: 0) { measured = $0 }, size: CGSize(width: 382, height: 24))
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let first = try XCTUnwrap(measured["filter"])
        fixture.host.rootView = content(expanded: true, reserved: 0) { measured = $0 }
        fixture.host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(abs(try XCTUnwrap(measured["filter"]).minX - first.minX), 90)
        XCTAssertFalse(fixture.window.isVisible)
    }

}
