import AppKit
import DotistCore
import XCTest
@testable import DotistApp

final class PanelInteractionRevisionTests: XCTestCase {
    func testToolbarTargetsUseHorizontalSlotMidpointsAndClamp() {
        XCTAssertEqual(ToolbarDragLayout.targetIndex(from: 1, translation: 15, count: 4), 1)
        XCTAssertEqual(ToolbarDragLayout.targetIndex(from: 1, translation: 17, count: 4), 2)
        XCTAssertEqual(ToolbarDragLayout.targetIndex(from: 2, translation: -17, count: 4), 1)
        XCTAssertEqual(ToolbarDragLayout.targetIndex(from: 1, translation: -999, count: 4), 0)
        XCTAssertEqual(ToolbarDragLayout.targetIndex(from: 1, translation: 999, count: 4), 3)
        XCTAssertEqual(ToolbarDragLayout.targetIndex(from: 0, translation: 100, count: 1), 0)
        XCTAssertEqual(ToolbarDragLayout.targetIndex(from: 0, translation: .nan, count: 4), 0)
    }

    func testAdjacentToolbarItemsMakeRoomInBothDirections() {
        XCTAssertEqual(ToolbarDragLayout.offset(index: 1, source: 0, target: 2, translation: 70), -32)
        XCTAssertEqual(ToolbarDragLayout.offset(index: 2, source: 0, target: 2, translation: 70), -32)
        XCTAssertEqual(ToolbarDragLayout.offset(index: 3, source: 0, target: 2, translation: 70), 0)
        XCTAssertEqual(ToolbarDragLayout.offset(index: 1, source: 3, target: 1, translation: -70), 32)
        XCTAssertEqual(ToolbarDragLayout.offset(index: 3, source: 3, target: 1, translation: -70), -70)
    }

    func testUndoToastExpiresAtSevenSecondsAndRestartResetsClock() {
        var toast = PausableToastLifetime(duration: 7)
        toast.restart(at: 100)
        XCTAssertTrue(toast.isVisible(at: 106.999))
        XCTAssertFalse(toast.isVisible(at: 107))
        toast.restart(at: 108)
        XCTAssertTrue(toast.isVisible(at: 114.999))
        XCTAssertFalse(toast.isVisible(at: 115))
    }

    func testHoverPausesRemainingTimeIncludingRepeatedHoverEvents() {
        var toast = PausableToastLifetime(duration: 7)
        toast.restart(at: 0)
        toast.setHovered(true, at: 3)
        toast.setHovered(true, at: 4)
        XCTAssertTrue(toast.isVisible(at: 100))
        toast.setHovered(false, at: 100)
        XCTAssertTrue(toast.isVisible(at: 103.999))
        XCTAssertFalse(toast.isVisible(at: 104))
        toast.setHovered(true, at: 105)
        XCTAssertFalse(toast.isVisible(at: 106), "Hover cannot resurrect an expired toast")
    }

    func testGenericNoticeExpiresAtTwoSecondsAndRestartDuringHoverKeepsPause() {
        var toast = PausableToastLifetime(duration: 2)
        toast.restart(at: 0)
        XCTAssertFalse(toast.isVisible(at: 2))
        toast.restart(at: 3)
        toast.setHovered(true, at: 4)
        toast.restart(at: 5)
        XCTAssertTrue(toast.isVisible(at: 100))
        toast.setHovered(false, at: 100)
        XCTAssertFalse(toast.isVisible(at: 102))
    }
}
