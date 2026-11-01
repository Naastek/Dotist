import XCTest
@testable import DotistApp

final class TaskReorderEngineTests: XCTestCase {
    func testSlotsThresholdGroupsAndSubtrees() throws {
        let rows: [TaskReorderEngine.Row] = [
            .init(id: "a", level: 0, groupID: "work", parentID: nil, midY: 20),
            .init(id: "b", level: 0, groupID: "work", parentID: nil, midY: 52),
            .init(id: "c", level: 1, groupID: "work", parentID: "b", midY: 80),
            .init(id: "d", level: 0, groupID: "life", parentID: nil, midY: 150)
        ]
        let groups: [TaskReorderEngine.Group] = [.init(id: "work", minY: 0, maxY: 110), .init(id: "life", minY: 110, maxY: 180), .init(id: "empty", minY: 180, maxY: 220)]
        func target(_ y: Double, _ x: Double, _ block: Set<String> = ["a"]) throws -> TaskReorderEngine.Target {
            try XCTUnwrap(TaskReorderEngine.target(rows: rows, groups: groups, draggedID: "a", blockIDs: block, startY: 20, offsetY: y, offsetX: x))
        }
        let before = try target(20, 0)
        XCTAssertEqual(before.slot, 0)
        XCTAssertEqual(before.beforeID, "b")
        let after = try target(65, 0)
        XCTAssertEqual(after.slot, 2)
        XCTAssertNil(after.parentID)
        XCTAssertEqual(try target(40, 15.3).level, 0)
        let child = try target(40, 15.5)
        XCTAssertEqual(child.level, 1)
        XCTAssertEqual(child.parentID, "b")
        XCTAssertEqual(try target(130, 0).groupID, "life")
        XCTAssertEqual(try target(180, 0).groupID, "empty")
        XCTAssertEqual(try target(180, 0).slot, 0)
        XCTAssertEqual(try target(40, 30, ["a", "c"]).level, 1)
    }
    func testChildOutdentsOnlyPastThreshold() throws {
        let rows: [TaskReorderEngine.Row] = [
            .init(id: "parent", level: 0, groupID: "g", parentID: nil, midY: 10),
            .init(id: "child", level: 1, groupID: "g", parentID: "parent", midY: 40),
            .init(id: "next", level: 0, groupID: "g", parentID: nil, midY: 70)
        ]
        let groups: [TaskReorderEngine.Group] = [.init(id: "g", minY: 0, maxY: 100)]
        func target(_ x: Double) throws -> TaskReorderEngine.Target {
            try XCTUnwrap(TaskReorderEngine.target(rows: rows, groups: groups, draggedID: "child", blockIDs: ["child"], startY: 40, offsetY: 0, offsetX: x))
        }
        XCTAssertEqual(try target(-15.3).parentID, "parent")
        XCTAssertEqual(try target(-15.5).level, 0)
        XCTAssertEqual(try target(-15.5).beforeID, "next")
    }

    func testHoveringOverAnotherRowDoesNotIndentWithoutHorizontalMovement() throws {
        let rows: [TaskReorderEngine.Row] = [
            .init(id: "source", level: 0, groupID: "g", parentID: nil, midY: 16),
            .init(id: "destination", level: 0, groupID: "g", parentID: nil, midY: 48)
        ]
        let target = try XCTUnwrap(TaskReorderEngine.target(
            rows: rows, groups: [.init(id: "g", minY: 0, maxY: 64)],
            draggedID: "source", blockIDs: ["source"], startY: 16,
            offsetY: 40, offsetX: 0
        ))
        XCTAssertEqual(target.level, 0)
        XCTAssertNil(target.parentID)
        XCTAssertNil(target.beforeID)
    }

    func testPanelIndentThresholdAndGroupHeaderOrEmptyGroupTargets() throws {
        let rows: [TaskReorderEngine.Row] = [
            .init(id: "source", level: 0, groupID: "a", parentID: nil, midY: 50),
            .init(id: "parent", level: 0, groupID: "b", parentID: nil, midY: 150)
        ]
        let groups: [TaskReorderEngine.Group] = [
            .init(id: "a", minY: 0, maxY: 80),
            .init(id: "b", minY: 100, maxY: 180),
            .init(id: "empty", minY: 200, maxY: 234)
        ]
        func target(y: Double, x: Double, block: Set<String> = ["source"]) throws -> TaskReorderEngine.Target {
            try XCTUnwrap(TaskReorderEngine.target(rows: rows, groups: groups, draggedID: "source", blockIDs: block, startY: 50, offsetY: y - 50, offsetX: x, indentStep: 26))
        }
        let header = try target(y: 110, x: 0)
        XCTAssertEqual(header.groupID, "b")
        XCTAssertEqual(header.beforeID, "parent")
        XCTAssertNil(header.parentID)
        XCTAssertEqual(try target(y: 170, x: 18.1).level, 0)
        XCTAssertEqual(try target(y: 170, x: 18.3).parentID, "parent")
        // A subtree can itself be nested; hidden height is supplied by the caller.
        XCTAssertEqual(try target(y: 170, x: 40, block: ["source", "hidden-child"]).parentID, "parent")
        let empty = try target(y: 210, x: 40)
        XCTAssertEqual(empty.groupID, "empty")
        XCTAssertEqual(empty.slot, 0)
        XCTAssertEqual(empty.level, 0)
        XCTAssertNil(empty.beforeID)
    }

}

extension TaskReorderEngineTests {
    func testMultiLevelTargetsThresholdsAndCollapsedSubtreeHeight() throws {
        let rows: [TaskReorderEngine.Row] = [
            .init(id: "source", depth: 0, groupID: "g", parentID: nil, midY: 10),
            .init(id: "root", depth: 0, groupID: "g", parentID: nil, midY: 40),
            .init(id: "one", depth: 1, groupID: "g", parentID: "root", midY: 70),
            .init(id: "two", depth: 2, groupID: "g", parentID: "one", midY: 100),
            .init(id: "three", depth: 3, groupID: "g", parentID: "two", midY: 130),
            .init(id: "four", depth: 4, groupID: "g", parentID: "three", midY: 160),
            .init(id: "next", depth: 0, groupID: "g", parentID: nil, midY: 220)
        ]
        func target(_ x: Double, height: Int = 0, y: Double = 180) throws -> TaskReorderEngine.Target {
            try XCTUnwrap(TaskReorderEngine.target(rows: rows, groups: [.init(id: "g", minY: 0, maxY: 260)], draggedID: "source", blockIDs: ["source"], startY: 10, offsetY: y - 10, offsetX: x, indentStep: 26, subtreeHeight: height))
        }
        XCTAssertEqual(try target(18.1).level, 0)
        XCTAssertEqual(try target(18.3).parentID, "root")
        XCTAssertEqual(try target(44.1).level, 1)
        XCTAssertEqual(try target(44.3).parentID, "one")
        XCTAssertEqual(try target(70.3).parentID, "two")
        XCTAssertEqual(try target(96.3).parentID, "three")
        XCTAssertEqual(try target(1000).level, 4)
        XCTAssertEqual(try target(1000, height: 2).level, 2)
        XCTAssertEqual(try target(1000, height: 2).parentID, "one")
        XCTAssertEqual(try target(1000, height: 4).level, 0)
        XCTAssertEqual(try target(1000, y: 55).level, 1)
        XCTAssertEqual(try target(1000, y: 30).level, 0)
        XCTAssertEqual(try target(-1000).beforeID, "next")
        XCTAssertEqual(rows[4].depth, 3)
    }

    func testNestedInsertionDoesNotSplitSiblingSubtreeOrUseNextFamilyAsAnchor() throws {
        let rows: [TaskReorderEngine.Row] = [
            .init(id: "source", depth: 2, groupID: "g", parentID: "other", midY: 10),
            .init(id: "root", depth: 0, groupID: "g", parentID: nil, midY: 40),
            .init(id: "one", depth: 1, groupID: "g", parentID: "root", midY: 70),
            .init(id: "two", depth: 2, groupID: "g", parentID: "one", midY: 100),
            .init(id: "three", depth: 3, groupID: "g", parentID: "two", midY: 130),
            .init(id: "sibling", depth: 2, groupID: "g", parentID: "one", midY: 160),
            .init(id: "next-root", depth: 0, groupID: "g", parentID: nil, midY: 190),
            .init(id: "next-one", depth: 1, groupID: "g", parentID: "next-root", midY: 220)
        ]
        let groups: [TaskReorderEngine.Group] = [.init(id: "g", minY: 0, maxY: 250)]
        let target = try XCTUnwrap(TaskReorderEngine.target(rows: rows, groups: groups, draggedID: "source", blockIDs: ["source"], startY: 10, offsetY: 100, offsetX: 0))
        XCTAssertEqual(target.level, 2)
        XCTAssertEqual(target.parentID, "one")
        XCTAssertEqual(target.slot, 4)
        XCTAssertEqual(target.beforeID, "sibling")
        let outdent = try XCTUnwrap(TaskReorderEngine.target(rows: rows, groups: groups, draggedID: "source", blockIDs: ["source"], startY: 10, offsetY: 160, offsetX: -18))
        XCTAssertEqual(outdent.level, 1)
        XCTAssertEqual(outdent.parentID, "root")
        XCTAssertNil(outdent.beforeID)
    }
}
