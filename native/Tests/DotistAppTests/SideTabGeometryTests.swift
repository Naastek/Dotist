import XCTest
@testable import DotistApp

final class SideTabGeometryTests: XCTestCase {
    func testWidthsForSelectionAndPointerStates() {
        XCTAssertEqual(SideTabGeometry.width(selected: false, expanded: false, hovered: false), 8)
        XCTAssertEqual(SideTabGeometry.width(selected: true, expanded: false, hovered: false), 26)
        XCTAssertEqual(SideTabGeometry.width(selected: false, expanded: true, hovered: false), 70)
        XCTAssertEqual(SideTabGeometry.width(selected: false, expanded: true, hovered: true), 92)
        XCTAssertEqual(SideTabGeometry.width(selected: true, expanded: true, hovered: true), 78)
    }
    func testSideChangesAtVisibleScreenBoundary() {
        XCTAssertTrue(SideTabGeometry.isRight(panelMinX: 109, visibleMinX: 0))
        XCTAssertFalse(SideTabGeometry.isRight(panelMinX: 110, visibleMinX: 0))
        XCTAssertTrue(SideTabGeometry.isRight(panelMinX: -900, visibleMinX: -1000))
        XCTAssertFalse(SideTabGeometry.isRight(panelMinX: -890, visibleMinX: -1000))
    }
}
