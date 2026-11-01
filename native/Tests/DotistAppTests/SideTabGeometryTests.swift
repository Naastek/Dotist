import XCTest
@testable import DotistApp

final class SideTabGeometryTests: XCTestCase {
    func testWidthsFollowTextAndExpansion() {
        XCTAssertEqual(SideTabGeometry.expandedWidth(textWidth: 10), 48)
        XCTAssertEqual(SideTabGeometry.expandedWidth(textWidth: 82.2), 111)
        XCTAssertEqual(SideTabGeometry.width(expanded: false, fullWidth: 111), 10)
        XCTAssertEqual(SideTabGeometry.width(expanded: true, fullWidth: 111), 111)
    }
    func testSideChangesAtWidthDependentScreenBoundary() {
        XCTAssertTrue(SideTabGeometry.isRight(panelMinX: 109, visibleMinX: 0, expandedWidth: 110))
        XCTAssertFalse(SideTabGeometry.isRight(panelMinX: 110, visibleMinX: 0, expandedWidth: 110))
        XCTAssertTrue(SideTabGeometry.isRight(panelMinX: -900, visibleMinX: -1000, expandedWidth: 120))
        XCTAssertFalse(SideTabGeometry.isRight(panelMinX: -880, visibleMinX: -1000, expandedWidth: 120))
    }
}
