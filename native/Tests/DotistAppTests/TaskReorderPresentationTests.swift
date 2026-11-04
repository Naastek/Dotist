import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TaskReorderPresentationTests: XCTestCase {
    func testTicSubtreeUsesOneMountedRowAndOneLineGap() async throws {
        let clock = LayoutMotionTestClock(reduceMotion: true)
        defer { clock.restore() }
        let scene = try Scene(height: 620)
        defer { scene.close() }
        try await settled(scene, "tic-before")
        let source = try scene.row(scene.source.id)
        scene.runtime.send(.begin(source.task.id, CGPoint(x: 110, y: source.frame.midY)))
        try await settled(scene, "tic-lift")
        XCTAssertEqual(scene.runtime.drag?.startFrame.height, 32, "The lifted subtree is one line, with a +N badge")
        XCTAssertEqual(try scene.row(scene.source.id).frame.height, 32, "The gesture owner stays mounted at the placeholder")
        XCTAssertEqual(scene.ghost.height, 32, "There is exactly one line of placeholder space")
        scene.assertNoInFlowHeaderOverlap()
        scene.runtime.send(.cancel)
    }
    func testNoDuplicateSpaceBeforeFirstRowOrBelowLife() async throws {
        let scene = try Scene(height: 620)
        defer { scene.close() }
        try await settled(scene, "compact-before")
        let source = try scene.row(scene.source.id)
        let life = try scene.row(scene.life[0].id)
        scene.runtime.send(.begin(source.task.id, CGPoint(x: 110, y: source.frame.midY)))
        scene.runtime.send(.move(source.task.id, CGPoint(x: 110, y: life.frame.minY)))
        try await Task.sleep(for: .milliseconds(250))
        try await settled(scene, "compact-first")
        let head = try scene.row(source.task.id)
        let first = try scene.row(scene.life[0].id)
        XCTAssertEqual(head.frame.height, 32)
        XCTAssertEqual(first.frame.minY, head.frame.maxY, accuracy: 0.5,
                       "The mounted source is the only placeholder before the first task")
        let last = try scene.row(scene.life[1].id)
        scene.runtime.send(.move(source.task.id, CGPoint(x: 110, y: last.frame.maxY + 2)))
        try await Task.sleep(for: .milliseconds(250))
        try await settled(scene, "compact-last")
        let finalHead = try scene.row(source.task.id)
        let finalLast = try scene.row(scene.life[1].id)
        XCTAssertEqual(finalHead.frame.minY, finalLast.frame.maxY, accuracy: 0.5,
                       "No second source hole may remain below life")
        scene.assertNoInFlowHeaderOverlap()
        scene.runtime.send(.cancel)
    }

    func testNestedTargetParentAndConnectorStayInsideDestinationGroup() async throws {
        let scene = try Scene(height: 620)
        defer { scene.close() }
        try await settled(scene, "thread-before")
        let source = try scene.row(scene.source.id), parent = try scene.row(scene.life[0].id)
        scene.runtime.send(.begin(source.task.id, CGPoint(x: 110, y: source.frame.midY)))
        scene.runtime.send(.move(source.task.id, CGPoint(x: 132, y: parent.frame.maxY + 1)))
        try await Task.sleep(for: .milliseconds(250))
        try await settled(scene, "thread-nested")
        let target = try XCTUnwrap(scene.runtime.drag?.target)
        XCTAssertEqual(target.level, 1)
        let actualParent = try scene.row(try XCTUnwrap(target.parentID))
        XCTAssertEqual(actualParent.task.category, target.groupID)
        let end = scene.ghost.midY
        for heading in scene.headers() {
            XCTAssertFalse(heading.minY > actualParent.frame.midY && heading.maxY < end,
                           "A parent connector may not cross a group heading")
        }
        scene.runtime.send(.cancel)
    }

    func testEveryPresentedFrameKeepsHeadingsAndTasksDisjointThroughRetargetAndCancel() async throws {
        let scene = try Scene(height: 620)
        defer { scene.close() }
        try await settled(scene, "frames-before")
        let source = try scene.row(scene.source.id), life = try scene.row(scene.life[1].id)
        let start = CGPoint(x: 110, y: source.frame.midY)
        scene.runtime.send(.begin(source.task.id, start))
        let evidence = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTIST_DRAG_EVIDENCE"] ?? "/tmp/dotist-drag-renderings")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        var samples = ["phase\tframe\ttime\theaderY\trowY"]
        for phase in 0..<3 {
            if phase == 0 { scene.runtime.send(.move(source.task.id, CGPoint(x: 110, y: life.frame.maxY + 1))) }
            if phase == 1 { scene.runtime.send(.move(source.task.id, start)) }
            if phase == 2 { scene.runtime.send(.cancel) }
            for frame in 0..<14 {
                let image = try await scene.fixture.capture(scale: 1)
                scene.assertNoInFlowHeaderOverlap()
                let heading = try scene.presentedElement("group-header:life")
                let row = try scene.presentedRow(scene.life[0].id)
                samples.append("\(phase)\t\(frame)\t\(ProcessInfo.processInfo.systemUptime)\t\(heading.minY)\t\(row.minY)")
                XCTAssertGreaterThanOrEqual(row.minY, heading.maxY)
                if frame == 2 { try image.representation(using: .png, properties: [:])?.write(to: evidence.appendingPathComponent("retarget-frame-\(phase).png")) }
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        try samples.joined(separator: "\n").write(to: evidence.appendingPathComponent("retarget-frames.tsv"), atomically: true, encoding: .utf8)
        XCTAssertNil(scene.runtime.drag)
    }

    func testReleaseKeepsPlaceholderTopForSameAndCrossGroupAndFilteredMoves() async throws {
        for filtered in [false, true] {
            for reduced in [false, true] {
                let clock = LayoutMotionTestClock(reduceMotion: reduced)
                defer { clock.restore() }
                let scene = try Scene(height: 620, singleSourceRoot: true)
                defer { scene.close() }
                if filtered {
                    let today = Date().dotistDay
                    await withCheckedContinuation { continuation in
                        scene.model.change(recordHistory: false, completed: { continuation.resume() }) { store in
                            for id in [scene.source.id, scene.child.id, scene.life[0].id, scene.life[1].id] { _ = try store.setDueDate(id, date: today) }
                        }
                    }
                    scene.state.scope = "today"
                }
                try await settled(scene, "landing-before-\(filtered)-\(reduced)")
                let source = try scene.row(scene.source.id), other = try scene.row(scene.life[0].id)
                let point = CGPoint(x: 110, y: other.frame.midY + 1)
                scene.runtime.send(.begin(source.task.id, CGPoint(x: 110, y: source.frame.midY)))
                scene.runtime.send(.move(source.task.id, point))
                try await Task.sleep(for: .milliseconds(230))
                try await settled(scene, "landing-slot-\(filtered)-\(reduced)")
                let top = scene.ghost.minY
                XCTAssertEqual(scene.runtime.drag?.target?.groupID, "life")
                scene.runtime.send(.end(source.task.id, point))
                var landingSamples = ["frame\ttop"]
                for frame in 0..<14 {
                    _ = try await scene.fixture.capture(scale: 1)
                    let presentedTop = try scene.presentedRow(source.task.id).minY
                    landingSamples.append("\(frame)\t\(presentedTop)")
                    XCTAssertEqual(presentedTop, top, accuracy: 0.5, "Commit cannot add a second landing movement")
                    try await Task.sleep(for: .milliseconds(16))
                }
                let evidence = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DOTIST_DRAG_EVIDENCE"] ?? "/tmp/dotist-drag-renderings")
                try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
                try landingSamples.joined(separator: "\n").write(to: evidence.appendingPathComponent("landing-\(filtered)-\(reduced).tsv"), atomically: true, encoding: .utf8)
                for _ in 0..<100 where scene.runtime.drag != nil { try await Task.sleep(for: .milliseconds(10)) }
                try await Task.sleep(for: .milliseconds(230))
                try await settled(scene, "landing-final-\(filtered)-\(reduced)")
                let finalTop = try scene.presentedRow(source.task.id).minY
                XCTAssertEqual(finalTop, top, accuracy: 0.5, "Replacing the placeholder must retain its top without a measured second landing")
                XCTAssertEqual(scene.model.tasks.first { $0.id == source.task.id }?.category, "life")
                XCTAssertEqual(scene.model.tasks.first { $0.id == scene.child.id }?.parentId, source.task.id)
                scene.assertNoInFlowHeaderOverlap()
            }
        }
    }

    func testCollapsedAndAdjacentEmptyGroupsOpenAndKeepExactlyOnePlaceholder() async throws {
        for reduced in [false, true] {
            let clock = LayoutMotionTestClock(reduceMotion: reduced)
            defer { clock.restore() }
            let scene = try Scene(height: 620, adjacentEmptyGroups: true)
            defer { scene.close() }
            let group = try XCTUnwrap(scene.emptyGroups.first)
            scene.state.setGroupCollapsed(true, id: group.id)
            try await settled(scene, "empty-before-\(reduced)")
            let source = try scene.row(scene.source.id)
            scene.runtime.send(.begin(source.task.id, CGPoint(x: 110, y: source.frame.midY)))
            try await Task.sleep(for: .milliseconds(220))
            try await settled(scene, "empty-pickup-\(reduced)")
            let header = try XCTUnwrap(scene.groups.first { $0.id == group.id })
            let point = CGPoint(x: 110, y: header.frame.maxY - 2)
            scene.runtime.send(.move(source.task.id, point))
            try await Task.sleep(for: .milliseconds(220))
            try await settled(scene, "empty-open-\(reduced)")
            XCTAssertFalse(scene.state.collapsedGroups.contains(group.id))
            XCTAssertEqual(scene.runtime.drag?.destination?.slot, .empty(group.id))
            XCTAssertEqual(try scene.row(source.task.id).frame.height, 32)
            XCTAssertEqual(scene.ghost.height, 32)
            scene.assertNoInFlowHeaderOverlap()
            scene.runtime.send(.end(source.task.id, point))
            for _ in 0..<100 where scene.runtime.drag != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(scene.model.tasks.first { $0.id == source.task.id }?.category, group.id)
        }
    }

    func testOpeningNonemptyGroupKeepsClippedTasksOutOfDropSlots() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let scene = try Scene(height: 620)
        defer { scene.close() }
        try await settled(scene, "nonempty-before")
        scene.state.setGroupCollapsed(true, id: "life")
        try await settled(scene, "nonempty-closing-start")
        try await clock.advance(by: 0.25)
        try await settled(scene, "nonempty-closed")
        let hidden = Set(scene.life.map(\.id))
        XCTAssertTrue(scene.rows.allSatisfy { !hidden.contains($0.task.id) })
        let source = try scene.row(scene.source.id)
        scene.runtime.send(.begin(source.task.id, CGPoint(x: 110, y: source.frame.midY)))
        try await Task.sleep(for: .milliseconds(220))
        try await settled(scene, "nonempty-pickup")
        let header = try XCTUnwrap(scene.groups.first { $0.id == "life" })
        let point = CGPoint(x: 110, y: header.frame.maxY - 2)
        scene.runtime.send(.move(source.task.id, point))
        try await settled(scene, "nonempty-opening")
        XCTAssertFalse(scene.state.collapsedGroups.contains("life"))
        for delta in [0.04, 0.06] {
            try await clock.advance(by: delta)
            try await settled(scene, "nonempty-clipped")
            scene.runtime.send(.move(source.task.id, point))
            XCTAssertTrue(scene.rows.allSatisfy { !hidden.contains($0.task.id) })
            XCTAssertTrue(scene.runtime.pickupFrames(scene.rows).allSatisfy { !hidden.contains($0.task.id) })
            XCTAssertEqual(scene.runtime.drag?.destination?.slot, .empty("life"))
            XCTAssertNil(scene.runtime.drag?.target?.beforeID, "Clipped rows cannot become hit anchors")
        }
        try await clock.advance(by: 0.15)
        try await settled(scene, "nonempty-open")
        XCTAssertTrue(hidden.isSubset(of: Set(scene.rows.map { $0.task.id })))
        let restoredHeader = try XCTUnwrap(scene.groups.first { $0.id == "life" })
        let release = CGPoint(x: 110, y: restoredHeader.frame.maxY - 2)
        scene.runtime.send(.move(source.task.id, release))
        XCTAssertEqual(scene.runtime.drag?.target?.beforeID, scene.life[0].id)
        try await Task.sleep(for: .milliseconds(220))
        try await settled(scene, "nonempty-target")
        let top = scene.ghost.minY
        scene.runtime.send(.end(source.task.id, release))
        for _ in 0..<100 where scene.runtime.drag != nil { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(220))
        try await settled(scene, "nonempty-committed")
        XCTAssertEqual(try scene.presentedRow(source.task.id).minY, top, accuracy: 0.5)
        XCTAssertEqual(scene.model.tasks.first { $0.id == source.task.id }?.category, "life")
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
    }

    private final class FixtureDefaults: UserDefaults, @unchecked Sendable {
        private var values: [String: Any] = [:]
        override func set(_ value: Any?, forKey key: String) { values[key] = value }
        override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    }

    @MainActor private final class Scene {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-drag-" + UUID().uuidString)
        let store: TaskStore
        let model: AppModel
        let runtime = TaskReorderRuntime()
        let motion = TaskDragMotion()
        let filter = DateFilterPresentation(schedule: { _, _ in })
        let selection = TaskSelectionController()
        let state: TaskPanelState
        let source: DotistTask
        let child: DotistTask
        let life: [DotistTask]
        let emptyGroups: [DotistGroup]
        var rows: [TaskListRowFrame] = []
        var groups: [TaskListGroupFrame] = []
        var ghost = CGRect.zero
        var fixture: NativeRenderingFixture<AnyView>!
        let height: CGFloat
        private let enhancedAX = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        private let savedAX: Any?
        init(height: CGFloat, width: CGFloat = 364, adjacentEmptyGroups: Bool = false, singleSourceRoot: Bool = false) throws {
            savedAX = NSApp.accessibilityAttributeValue(enhancedAX)
            NSApp.accessibilitySetValue(true, forAttribute: enhancedAX)
            self.height = height
            store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
            _ = try store.updateGroup("work", name: "work")
            _ = try store.updateGroup("life", name: "life")
            try store.deleteGroup("study")
            let side = try store.addGroup(name: "side project")
            _ = try store.addTask(title: "Inbox note")
            source = try store.addTask(title: "Plan launch", category: "work")
            child = try store.addTask(title: "Review copy", category: "work", parentId: source.id)
            if !singleSourceRoot { _ = try store.addTask(title: "Ship draft", category: "work") }
            life = try [store.addTask(title: "Read a chapter", category: "life"), store.addTask(title: "Take a walk", category: "life")]
            if adjacentEmptyGroups {
                emptyGroups = [side, try store.addGroup(name: "Next empty group")]
            } else {
                emptyGroups = []
                _ = try store.addTask(title: "Sketch ideas", category: side.id)
            }
            var patch = DotistSettingsPatch(); patch.language = "en"; patch.theme = "light"
            _ = try store.updateSettings(patch)
            model = try AppModel(store: store)
            // No CFPreferences writes, including while testing group expansion.
            let defaults = FixtureDefaults()
            state = TaskPanelState(scope: "all", collapseStore: TaskGroupCollapseStore(defaults: defaults))
            let view = MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, filterPresentation: self.filter, reorderRuntime: self.runtime, dragMotion: self.motion, selection: self.selection)
                .onPreferenceChange(TaskListRowFrame.Key.self) { [weak self] in self?.rows = $0 }
                .onPreferenceChange(TaskListGroupFrame.Key.self) { [weak self] in self?.groups = $0 }
                .onPreferenceChange(TaskGhostFrameKey.self) { [weak self] in self?.ghost = $0 }
                .background(Color.white).environment(\.colorScheme, .light)
            fixture = NativeRenderingFixture(AnyView(view), size: CGSize(width: width, height: height))
        }
        func close() { fixture.close(); runtime.handleInput = nil; NSApp.accessibilitySetValue(savedAX, forAttribute: enhancedAX); try? FileManager.default.removeItem(at: directory) }
        func elementFrame(_ id: String) -> CGRect? {
            func search(_ node: NSObject) -> (any NSAccessibilityElementProtocol)? {
                if let element = node as? any NSAccessibilityElementProtocol,
                   element.accessibilityIdentifier?() == id { return element }
                let selector = #selector(NSAccessibilityProtocol.accessibilityChildren)
                guard node.responds(to: selector) else { return nil }
                for child in node.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] {
                    if let found = search(child) { return found }
                }
                return nil
            }
            guard let row = search(fixture.host) else { return nil }
            return fixture.host.convert(fixture.window.convertFromScreen(row.accessibilityFrame()), from: nil)
        }
        func presentedElement(_ id: String) throws -> CGRect { try XCTUnwrap(elementFrame(id)) }
        func presentedRow(_ id: String) throws -> CGRect { try presentedElement("task-row:" + id) }
        func row(_ id: String) throws -> TaskListRowFrame { try XCTUnwrap(rows.first { $0.task.id == id }) }
        func capture(_ name: String) async throws -> NSBitmapImageRep {
            try await Task.sleep(for: .milliseconds(10))
            // Preferences from hosted AppKit children arrive after drawing.
            // Drain that delivery before pairing their frames with these pixels.
            _ = try await fixture.capture(scale: 2)
            let image = try await fixture.capture(scale: 2)
            let base = ProcessInfo.processInfo.environment["DOTIST_DRAG_EVIDENCE"]
                .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("dotist-drag-renderings")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: base.appendingPathComponent("\(name)-\(Int(height)).png"))
            return image
        }
        func headers() -> [CGRect] {
            model.visibleGroups.compactMap { elementFrame("group-header:" + $0.id) }
        }
        func assertNoInFlowHeaderOverlap(file: StaticString = #filePath, line: UInt = #line) {
            for header in headers() {
                for row in rows {
                    guard runtime.drag?.blockIDs.contains(row.task.id) != true,
                          let presented = try? presentedRow(row.task.id) else { continue }
                    XCTAssertFalse(header.intersects(presented), "Header \(header) overlaps \(row.task.title): \(presented)", file: file, line: line)
                }
                // The invisible mounted head moves between slots and can
                // cross a heading geometrically. It paints no task content;
                // test its single-line height separately from visible rows.
            }
        }
    }





    func testLiftingOnlyRootKeepsItsNowEmptySourceGroupAsInitialDestination() async throws {
        let scene = try Scene(height: 620, singleSourceRoot: true)
        defer { scene.close() }
        try await settled(scene, "empty-source-before")
        let source = try scene.row(scene.source.id)
        scene.runtime.send(.begin(source.task.id, CGPoint(x: 110, y: source.frame.midY)))
        XCTAssertEqual(scene.runtime.drag?.target?.groupID, "work")
        XCTAssertEqual(scene.runtime.drag?.destination?.slot, .empty("work"))
        scene.runtime.send(.cancel)
        XCTAssertEqual(try scene.store.listTasks().first { $0.id == source.task.id }?.category, "work")
    }




    func testAllUsesCompactSectionGapsWithoutStretchingAt620And900() async throws {
        var previous: [CGRect]?
        for height: CGFloat in [620, 900] {
            let scene = try Scene(height: height)
            defer { scene.close() }
            _ = try await scene.capture("idle")
            XCTAssertEqual(scene.rows.count, scene.model.tasks.count)
            let headers = scene.headers().sorted { $0.minY < $1.minY }
            XCTAssertEqual(headers.count, scene.model.visibleGroups.count)
            for header in headers {
                let lastRow = try XCTUnwrap(scene.rows.filter { $0.frame.maxY <= header.minY }.max { $0.frame.maxY < $1.frame.maxY })
                let gap = header.minY - lastRow.frame.maxY
                print("ALL SPACING height=\(height) header=\(header) previous=\(lastRow.frame) gap=\(gap)")
                XCTAssertLessThanOrEqual(gap, 12.5, "Section padding plus header padding must leave a compact gap")
                let firstRow = try XCTUnwrap(scene.rows.filter { $0.frame.minY >= header.maxY }.min { $0.frame.minY < $1.frame.minY })
                XCTAssertEqual(firstRow.frame.minY, header.maxY + 1, accuracy: 0.5, "Header must sit directly above its first task")
            }
            let layout = scene.rows.sorted { $0.frame.minY < $1.frame.minY }.map(\.frame) + headers
            if let previous { XCTAssertEqual(layout, previous, "A taller viewport must not stretch the outline") }
            previous = layout
            scene.assertNoInFlowHeaderOverlap()
        }
    }

    func testBeginningDragNeverPublishesAnUninitializedInsertionTarget() async throws {
        let scene = try Scene(height: 620)
        defer { scene.close() }
        _ = try await scene.capture("initial-idle")
        let source = try scene.row(scene.source.id)
        var transientGaps = 0
        let observation = scene.runtime.$drag.sink { drag in
            if let drag, drag.target == nil { transientGaps += 1 }
        }
        defer { observation.cancel() }
        scene.runtime.send(.begin(source.task.id, CGPoint(x: 100, y: source.frame.midY)))
        _ = try await scene.capture("initial-drag")
        XCTAssertEqual(transientGaps, 0, "The initial target must be complete before publishing; a partial state inserts a duplicate gap")
        XCTAssertEqual(scene.ghost.height, try XCTUnwrap(scene.runtime.drag).startFrame.height)
        scene.runtime.send(.cancel)
    }


    func testStationaryTargetsAndDirectionReversalsAcrossGroupsCommitWholeTree() async throws {
        for height: CGFloat in [620, 900] {
            let scene = try Scene(height: height)
            defer { scene.close() }
            _ = try await scene.capture("before-drag")
            XCTAssertNotNil(scene.runtime.handleInput)
            let source = try scene.row(scene.source.id)
            let start = CGPoint(x: 100, y: source.frame.midY)
            let firstLife = try scene.row(scene.life[0].id)
            scene.runtime.send(.begin(scene.source.id, start))
            let point = CGPoint(x: 100, y: firstLife.frame.midY + 1)
            scene.runtime.send(.move(scene.source.id, point))
            for _ in 0..<4 {
                _ = try await scene.capture("drag-lower")
                scene.runtime.send(.move(scene.source.id, point))
                XCTAssertEqual(scene.runtime.drag?.target?.groupID, "life")
                XCTAssertEqual(scene.runtime.drag?.target?.beforeID, scene.life[1].id)
                scene.assertNoInFlowHeaderOverlap()
            }
            let lower = try scene.row(scene.life[1].id)
            scene.runtime.send(.move(scene.source.id, CGPoint(x: 100, y: lower.frame.midY + 1)))
            _ = try await scene.capture("drag-end")
            XCTAssertNil(scene.runtime.drag?.target?.beforeID)
            let reversed = try scene.row(scene.life[1].id)
            let reversePoint = CGPoint(x: 100, y: reversed.frame.midY - 1)
            scene.runtime.send(.move(scene.source.id, reversePoint))
            for _ in 0..<4 {
                _ = try await scene.capture("drag-reversed")
                scene.runtime.send(.move(scene.source.id, reversePoint))
                XCTAssertEqual(scene.runtime.drag?.target?.beforeID, scene.life[1].id)
            }
            scene.runtime.send(.end(scene.source.id, reversePoint))
            for _ in 0..<100 where scene.runtime.drag != nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(scene.runtime.drag)
            let persisted = try scene.store.listTasks()
            XCTAssertEqual(persisted.count, 7)
            XCTAssertEqual(persisted.first { $0.id == scene.source.id }?.category, "life")
            XCTAssertNil(persisted.first { $0.id == scene.source.id }?.parentId)
            XCTAssertEqual(persisted.first { $0.id == scene.child.id }?.category, "life")
            XCTAssertEqual(persisted.first { $0.id == scene.child.id }?.parentId, scene.source.id)
            XCTAssertEqual(scene.model.ordered(persisted.filter { $0.category == "life" && $0.parentId == nil }).map(\.id), [scene.life[0].id, scene.source.id, scene.life[1].id])
            _ = try await scene.capture("committed")
            scene.assertNoInFlowHeaderOverlap()
        }
    }

    func testUpwardDragCancellationRestoresPixelsAndNeverPersists() async throws {
        let scene = try Scene(height: 620)
        defer { scene.close() }
        let before = try await scene.capture("cancel-idle")
        let persisted = try scene.store.listTasks()
        let source = try scene.row(scene.life[1].id)
        let destination = try scene.row(scene.source.id)
        let point = CGPoint(x: 100, y: destination.frame.midY - 1)
        scene.runtime.send(.begin(source.task.id, CGPoint(x: 100, y: source.frame.midY)))
        scene.runtime.send(.move(source.task.id, point))
        for _ in 0..<4 {
            _ = try await scene.capture("drag-upper")
            scene.runtime.send(.move(source.task.id, point))
            XCTAssertEqual(scene.runtime.drag?.target?.groupID, "work")
            XCTAssertEqual(scene.runtime.drag?.target?.beforeID, scene.source.id)
            scene.assertNoInFlowHeaderOverlap()
        }
        scene.runtime.send(.cancel)
        try await Task.sleep(for: .milliseconds(240))
        _ = try await scene.capture("cancelled")
        XCTAssertNil(scene.runtime.drag)
        XCTAssertNil(scene.model.dragId)
        XCTAssertEqual(try scene.store.listTasks(), persisted)
        let after = try await scene.fixture.capture(scale: 2)
        XCTAssertEqual(before.pixelsWide, after.pixelsWide)
        XCTAssertEqual(before.pixelsHigh, after.pixelsHigh)
        // Source and insertion previews must disappear after cancellation.
        XCTAssertEqual(before.representation(using: .png, properties: [:]), after.representation(using: .png, properties: [:]))
    }

    func testPickupAfterNativeScrollBeforePreferenceDeliveryUsesLiveSourceFrame() async throws {
        let clock = LayoutMotionTestClock(reduceMotion: true)
        defer { clock.restore() }
        let scene = try Scene(height: 320)
        defer { scene.close() }
        try await settled(scene, "pickup-scroll-before")
        let source = try scene.row(scene.source.id)
        let origin = scene.runtime.scrollOriginY
        XCTAssertTrue(scene.runtime.scroll(by: 40))
        // The native scroll offset is synchronous; AX and SwiftUI geometry may
        // still have the previous generation until drawing. Keep that race.
        let delta = origin - scene.runtime.scrollOriginY
        XCTAssertEqual(delta, -40, accuracy: 0.5)
        let expected = source.frame.offsetBy(dx: 0, dy: delta)
        let start = CGPoint(x: expected.minX + 100, y: expected.minY + 11)
        scene.runtime.send(.begin(source.task.id, start))
        let drag = try XCTUnwrap(scene.runtime.drag)
        print("PICKUP SCROLL cached=\(source.frame) native=\(expected) lifted=\(drag.startFrame) grab=\(start)")
        XCTAssertEqual(drag.startFrame.minY, expected.minY, accuracy: 0.5,
                       "Pickup must read native geometry, not an earlier preference generation")
        scene.runtime.send(.cancel)
    }

    /// A carried subtree adds a badge, without enlarging the one-line surface.
    func testLiftedSurfaceHasClearanceWithoutChangingOneLineLayoutHeight() async throws {
        let scene = try Scene(height: 440)
        defer { scene.close() }
        try await settled(scene, "clearance-source")
        let source = try scene.row(scene.source.id)
        let start = CGPoint(x: 100, y: source.frame.midY)
        scene.runtime.send(.begin(source.task.id, start))
        let session = try XCTUnwrap(scene.runtime.drag)
        XCTAssertEqual(session.visibleBlock.count, 2)
        let fixture = NativeRenderingFixture(TaskLiftedBlock(drag: session, motion: scene.motion) { _ in PointerInk() }
            .frame(width: 364, height: 440, alignment: .topLeading)
            .environment(\._accessibilityReduceTransparency, true).environment(\.colorScheme, .light), size: CGSize(width: 364, height: 440))
        defer { fixture.close() }
        let image = try await fixture.capture(scale: 2)
        let frame = session.startFrame
        // Sample the intentionally opaque accessibility branch: compositor
        // glass is omitted by unordered rasterization, but shares this shape.
        var left = image.pixelsWide, right = 0, top = image.pixelsHigh, bottom = 0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        let surface = CGRect(x: CGFloat(left)/2, y: CGFloat(top)/2, width: CGFloat(right-left+1)/2, height: CGFloat(bottom-top+1)/2)
        print("LIFTED SURFACE content=\(frame) surface=\(surface) horizontalClearance=\(frame.minX-surface.minX),\(surface.maxX-frame.maxX) subtreeHeight=\(frame.height)")
        XCTAssertEqual(surface.minX, frame.minX - 12, accuracy: 0.5)
        XCTAssertEqual(surface.maxX, frame.maxX + 12, accuracy: 0.5)
        XCTAssertEqual(surface.minY, frame.minY - 4, accuracy: 0.5)
        XCTAssertEqual(surface.maxY, frame.maxY + 4, accuracy: 0.5)
        XCTAssertEqual(frame.height, 32)
        scene.runtime.send(.cancel)
    }

    private struct PointerInk: NSViewRepresentable {
        final class Ink: NSView {
            override func draw(_ dirtyRect: NSRect) { NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill(); bounds.fill() }
        }
        func makeNSView(context: Context) -> Ink { Ink() }
        func updateNSView(_ view: Ink, context: Context) {}
    }

    func testLiftedBlockFollowsBothAxesImmediatelyInAnimatedTransaction() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
        let task = try store.addTask(title: "pointer probe")
        let frame = CGRect(x: 16, y: 100, width: 120, height: 32)
        let row = TaskListRowFrame(task: task, frame: frame)
        let start = CGPoint(x: 80, y: 110)
        let motion = TaskDragMotion(); motion.location = start
        let drag = TaskListDrag(taskID: task.id, blockIDs: [task.id], visibleBlock: [row], startFrame: frame, startLocation: start)
        let fixture = NativeRenderingFixture(
            TaskLiftedBlock(drag: drag, motion: motion) { _ in PointerInk() }
                .frame(width: 364, height: 620, alignment: .topLeading).background(Color.white),
            size: CGSize(width: 364, height: 620))
        defer { fixture.close() }
        let baseline = try await fixture.capture(scale: 1)
        let evidence = ProcessInfo.processInfo.environment["DOTIST_DRAG_EVIDENCE"].map { URL(fileURLWithPath: $0) }
        if let evidence { try baseline.representation(using: .png, properties: [:])?.write(to: evidence.appendingPathComponent("pointer-after-start.png")) }
        for point in [start, CGPoint(x: 120, y: 160), CGPoint(x: 70, y: 90)] {
            withAnimation(.linear(duration: 1)) { motion.location = point }
            let image = try await fixture.capture(scale: 1)
            if let evidence { try image.representation(using: .png, properties: [:])?.write(to: evidence.appendingPathComponent("pointer-after-\(Int(point.x))-\(Int(point.y)).png")) }
            var x0 = image.pixelsWide, y0 = image.pixelsHigh
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    if let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent - c.greenComponent > 0.5 && c.redComponent - c.blueComponent > 0.5 {
                        x0 = min(x0, x); y0 = min(y0, y)
                    }
                }
            }
            print("POINTER point=\(point) paintedOrigin=\(x0),\(y0)")
            XCTAssertEqual(CGFloat(x0), frame.minX + point.x - start.x, accuracy: 0.5)
            XCTAssertEqual(CGFloat(y0), frame.minY + point.y - start.y, accuracy: 0.5)
        }
    }
    func testSelectedRootsCarryTheirSubtreesAndRemainOneUndoOperation() async throws {
        let scene = try Scene(height: 620)
        defer { scene.close() }
        try await settled(scene, "selection-before")
        let before = try scene.store.listTasks()
        let source = try scene.row(scene.source.id)
        let target = try scene.row(scene.life[1].id)
        scene.selection.update { $0.ids = [scene.source.id, scene.life[0].id] }
        scene.runtime.send(.begin(source.task.id, CGPoint(x: 100, y: source.frame.midY)))
        XCTAssertEqual(scene.runtime.drag?.rootIDs.count, 2)
        XCTAssertEqual(scene.runtime.drag?.visibleBlock.count, 3)
        let point = CGPoint(x: 100, y: target.frame.maxY + 1)
        scene.runtime.send(.move(source.task.id, point))
        scene.runtime.send(.end(source.task.id, point))
        for _ in 0..<100 where scene.runtime.drag != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(scene.runtime.drag)
        XCTAssertEqual(scene.model.undoHistory.count, 1)
        XCTAssertEqual(Set(scene.model.tasks.map(\.id)), Set(before.map(\.id)))
        XCTAssertEqual(scene.model.tasks.first { $0.id == scene.child.id }?.parentId, source.task.id)
        XCTAssertEqual(scene.selection.value.ids, [scene.source.id, scene.life[0].id])
        scene.model.undoLast()
        for _ in 0..<100 where scene.model.historyActionInFlight { try await Task.sleep(for: .milliseconds(10)) }
        func outline(_ tasks: [DotistTask]) -> [String] {
            tasks.map { "\($0.id):\($0.category):\($0.parentId ?? "root"):\($0.position)" }.sorted()
        }
        XCTAssertEqual(outline(try scene.store.listTasks()), outline(before))
    }

    func testFilteredRepeatedContextRowsHaveDistinctGapsAndOneLiftedRepresentation() async throws {
        let clock = LayoutMotionTestClock(reduceMotion: true)
        defer { clock.restore() }
        let scene = try Scene(height: 900)
        defer { scene.close() }
        let today = Date().dotistDay
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!.dotistDay
        await withCheckedContinuation { continuation in
            scene.model.change(recordHistory: false, completed: { continuation.resume() }) { store in
                _ = try store.setDueDate(scene.source.id, date: today)
                _ = try store.setDueDate(scene.child.id, date: tomorrow)
                _ = try store.setDueDate(scene.life[0].id, date: tomorrow)
            }
        }
        scene.state.scope = "next7"
        try await settled(scene, "filtered-context-before")
        let copies = scene.rows.filter { $0.task.id == scene.source.id }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(copies.count, 2, "The parent appears as a match and as tomorrow's context")
        let source = try XCTUnwrap(copies.last)
        let before = try scene.store.listTasks()
        let start = CGPoint(x: 100, y: source.frame.midY)
        scene.runtime.send(.begin(source.task.id, start))
        try await settled(scene, "filtered-context-middle")
        let drag = try XCTUnwrap(scene.runtime.drag)
        XCTAssertEqual(Set(drag.visibleBlock.map { $0.task.id }).count, drag.visibleBlock.count)
        XCTAssertEqual(drag.visibleBlock.first?.region, source.region)
        XCTAssertEqual(scene.ghost.height, 32, accuracy: 0.5)
        XCTAssertEqual(scene.rows.first { $0.task.id == source.task.id && $0.region == copies[0].region }?.frame.height, copies[0].frame.height)
        scene.runtime.send(.cancel)
        try await settled(scene, "filtered-context-cancelled")
        XCTAssertEqual(try scene.store.listTasks(), before)
    }


    func testFilterReturnDuringDragRebasesInputGeometryWithoutMovingTheGrabbedPoint() async throws {
        for reduced in [false, true] {
            let clock = LayoutMotionTestClock(reduceMotion: reduced)
            defer { clock.restore() }
            let scene = try Scene(height: 440)
            defer { scene.close() }
            scene.filter.toggle()
            try await settled(scene, "integrated-filter-open")
            try await clock.advance(by: 0.2)
            try await settled(scene, "integrated-filter-expanded")
            let before = try scene.store.listTasks()
            let source = try scene.row(scene.source.id)
            let start = CGPoint(x: 110, y: source.frame.minY + 7)
            scene.runtime.send(.begin(source.task.id, start))
            let probe = NativeRenderingFixture(LiftedProbe(runtime: scene.runtime, motion: scene.motion), size: CGSize(width: 500, height: 620))
            defer { probe.close() }
            let oldViewport = try XCTUnwrap(scene.runtime.pickupViewportFrame)
            let scroll = try XCTUnwrap(scene.fixture.descendants(NSScrollView.self).first { $0.bounds.height > 100 })
            let scrollOrigin = scroll.contentView.bounds.origin
            scene.filter.dismiss()
            _ = try await scene.capture("integrated-filter-return-start")
            for step in [0.06, 0.12] {
                try await clock.advance(by: step)
                try await settled(scene, "integrated-filter-return")
                _ = try XCTUnwrap(scene.runtime.drag)
                let painted = try redOrigin(try await probe.capture(scale: 1))
                XCTAssertEqual(painted.x, source.frame.minX, accuracy: 0.5)
                XCTAssertEqual(painted.y, source.frame.minY, accuracy: 0.5, "Layout return cannot move the grabbed point")
                XCTAssertEqual(scene.motion.location, start)
                XCTAssertEqual(scroll.contentView.bounds.origin, scrollOrigin)
                XCTAssertEqual(scene.fixture.descendants(TaskContentTransitionView.self).first?.outgoingOpacity, 0)
                scene.assertNoInFlowHeaderOverlap()
            }
            XCTAssertEqual(try XCTUnwrap(scene.runtime.pickupViewportFrame).minY - oldViewport.minY, -34, accuracy: 0.5)
            let point = CGPoint(x: start.x, y: scene.headers()[1].maxY + 17)
            scene.runtime.send(.move(source.task.id, point))
            let target = try XCTUnwrap(scene.runtime.drag?.target)
            XCTAssertEqual(target.groupID, "life")
            scene.runtime.send(.move(source.task.id, point))
            XCTAssertEqual(scene.runtime.drag?.target, target, "Repeated input must not follow an obsolete destination")
            scene.runtime.send(.cancel)
            try await settled(scene, "integrated-filter-cancel")
            XCTAssertNil(scene.runtime.drag)
            XCTAssertEqual(try scene.store.listTasks(), before)
            XCTAssertTrue(scene.fixture.descendants(NSScrollView.self).contains { $0 === scroll })
            let nativeTop = scene.headers()[1].maxY + 1
            scene.runtime.send(.begin(scene.life[0].id, CGPoint(x: 110, y: nativeTop + 7)))
            print("RESTART reduced=\(reduced) actual=\(scene.runtime.drag?.startFrame.minY ?? -1) native=\(nativeTop)")
            XCTAssertEqual(try XCTUnwrap(scene.runtime.drag).startFrame.minY, nativeTop, accuracy: 0.5,
                           "A fresh pickup after return must use current native row geometry")
            scene.runtime.send(.cancel)
            XCTAssertFalse(scene.fixture.window.isVisible)
        }
    }

    func testDragBeginningDuringGroupTransitionUsesLatestLiveRowsAndRetiresOutgoingPixels() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        let scene = try Scene(height: 620)
        defer { scene.close() }
        try await settled(scene, "integrated-group-before")
        scene.state.groupID = "life"
        try await settled(scene, "integrated-group-start")
        try await clock.advance(by: 0.06)
        let surface = try XCTUnwrap(scene.fixture.descendants(TaskContentTransitionView.self).first)
        XCTAssertGreaterThan(surface.outgoingOpacity, 0)
        XCTAssertEqual(Set(scene.rows.map { $0.task.id }), Set(scene.life.map(\.id)))
        let source = try scene.row(scene.life[0].id)
        scene.runtime.send(.begin(source.task.id, CGPoint(x: 110, y: source.frame.midY)))
        try await settled(scene, "integrated-group-drag")
        let session = try XCTUnwrap(scene.runtime.drag)
        XCTAssertEqual(Set(scene.rows.map { $0.task.id }), Set(scene.life.map(\.id)))
        XCTAssertEqual(session.visibleBlock.map { $0.task.id }, [source.task.id])
        XCTAssertEqual(session.startFrame.minY, source.frame.minY, accuracy: 0.5)
        XCTAssertEqual(surface.outgoingOpacity, 0)
        XCTAssertEqual(surface.opacity?.value, 1)
        scene.runtime.send(.cancel)
        XCTAssertFalse(scene.fixture.window.isVisible)
    }

    private struct LiftedProbe: View {
        @ObservedObject var runtime: TaskReorderRuntime
        let motion: TaskDragMotion
        var body: some View {
            Group {
                if let drag = runtime.drag { TaskLiftedBlock(drag: drag, motion: motion) { _ in PointerInk() } }
            }.frame(width: 500, height: 620, alignment: .topLeading).background(Color.white)
        }
    }

    private func redOrigin(_ image: NSBitmapImageRep) throws -> CGPoint {
        var left = image.pixelsWide, top = image.pixelsHigh
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                if let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   c.redComponent - c.greenComponent > 0.5, c.redComponent - c.blueComponent > 0.5 {
                    left = min(left, x); top = min(top, y)
                }
            }
        }
        XCTAssertLessThan(left, image.pixelsWide, "The production lifted layer must actually paint")
        return CGPoint(x: left, y: top)
    }

    private func settled(_ scene: Scene, _ name: String) async throws {
        for _ in 0..<3 { _ = try await scene.capture(name) }
    }




    func testStaleStoreAnchorFailureClearsTheDragWithoutPersistingAMove() async throws {
        let scene = try Scene(height: 620)
        defer { scene.close() }
        try await settled(scene, "failure-before")
        let source = try scene.row(scene.source.id)
        let destination = try scene.row(scene.life[0].id)
        let point = CGPoint(x: 100, y: destination.frame.minY + 1)
        scene.runtime.send(.begin(source.task.id, CGPoint(x: 100, y: source.frame.midY)))
        scene.runtime.send(.move(source.task.id, point))
        let anchor = try XCTUnwrap(scene.runtime.drag?.target?.beforeID)
        try scene.store.deleteTask(anchor)
        let before = try scene.store.listTasks()
        scene.runtime.send(.end(source.task.id, point))
        for _ in 0..<100 where scene.runtime.drag != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(scene.runtime.drag)
        XCTAssertNil(scene.model.dragId)
        XCTAssertNotNil(scene.model.error)
        XCTAssertEqual(try scene.store.listTasks(), before)
        XCTAssertEqual(before.first { $0.id == source.task.id }?.category, "work")
    }

    func testEdgeScrollKeepsPointerFixedInBothDirectionsAndCancellationRestoresRows() async throws {
        let scene = try Scene(height: 320)
        defer { scene.close() }
        try await settled(scene, "edge-before")
        let source = try scene.row(scene.source.id)
        let scroll = try XCTUnwrap(scene.runtime.scrollView)
        let viewport = scene.fixture.host.convert(scroll.bounds, from: scroll)
        let persisted = try scene.store.listTasks()
        scene.runtime.send(.begin(source.task.id, CGPoint(x: 100, y: source.frame.minY + 8)))
        let origin = scene.runtime.scrollOriginY
        let bottom = CGPoint(x: 100, y: viewport.maxY - 2)
        scene.runtime.send(.move(source.task.id, bottom))
        try await Task.sleep(for: .milliseconds(200))
        try await settled(scene, "edge-bottom")
        let lower = scene.runtime.scrollOriginY
        XCTAssertGreaterThan(lower, origin)
        XCTAssertEqual(scene.motion.location, bottom)
        let top = CGPoint(x: 100, y: viewport.minY + 2)
        scene.runtime.send(.move(source.task.id, top))
        try await Task.sleep(for: .milliseconds(200))
        try await settled(scene, "edge-top")
        XCTAssertLessThan(scene.runtime.scrollOriginY, lower)
        XCTAssertEqual(scene.motion.location, top)
        scene.runtime.send(.cancel)
        try await settled(scene, "edge-cancelled")
        XCTAssertNil(scene.runtime.drag)
        XCTAssertEqual(try scene.store.listTasks(), persisted)
        XCTAssertEqual(try scene.row(source.task.id).frame.height, source.frame.height)
    }

    func testUnorderedWindowReceivesNativeDragEventsWithoutDesktopInput() async throws {
        let scene = try Scene(height: 620)
        defer { scene.close() }
        try await settled(scene, "events-before")
        let source = try scene.row(scene.source.id)
        let start = CGPoint(x: 110, y: source.frame.midY)
        let host = scene.fixture.host, window = scene.fixture.window
        XCTAssertFalse(window.isVisible)
        let hit = try XCTUnwrap(window.contentView?.hitTest(window.contentView!.convert(host.convert(start, to: nil), from: nil)))
        XCTAssertFalse(hit is NSControl || hit is NSText, "Do not enter an AppKit control tracking loop")
        func send(_ kind: NSEvent.EventType, _ point: CGPoint) async throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: host.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseUp ? 0 : 1))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await send(.leftMouseDown, start)
        try await send(.leftMouseDragged, start + CGPoint(x: 0, y: 8))
        guard scene.runtime.drag != nil else {
            throw XCTSkip("NSWindow.sendEvent does not start SwiftUI recognition in this unordered window; no visible window or desktop input is authorized. Runtime-driven native paint checks run separately.")
        }
        try await Task.sleep(for: .milliseconds(650))
        let next = start + CGPoint(x: 18, y: 80)
        try await send(.leftMouseDragged, next)
        XCTAssertEqual(scene.motion.location.x, next.x, accuracy: 0.5)
        XCTAssertEqual(scene.motion.location.y, next.y, accuracy: 0.5)
        try await settled(scene, "events-middle")
        try await send(.leftMouseUp, next)
        for _ in 0..<100 where scene.runtime.drag != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(scene.runtime.drag)
        XCTAssertFalse(window.isVisible)
        try await settled(scene, "events-after")
    }

}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
