import AppKit
import DotistCore
import SwiftUI
import XCTest
@testable import DotistApp

@MainActor
final class TaskReorderPresentationTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        DotistDesign.registerFonts(in: repo.appendingPathComponent(".cache/native-migration/fonts"))
    }

    @MainActor private final class Scene {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-drag-" + UUID().uuidString)
        let store: TaskStore
        let model: AppModel
        let runtime = TaskReorderRuntime()
        let motion = TaskDragMotion()
        let state: TaskPanelState
        let source: DotistTask
        let child: DotistTask
        let life: [DotistTask]
        var rows: [TaskListRowFrame] = []
        var groups: [TaskListGroupFrame] = []
        var ghost = CGRect.zero
        var gaps: [TaskInsertionSlot: CGRect] = [:]
        var fixture: NativeRenderingFixture<AnyView>!
        let height: CGFloat
        init(height: CGFloat, width: CGFloat = 364) throws {
            self.height = height
            store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
            _ = try store.updateGroup("work", name: "work")
            _ = try store.updateGroup("life", name: "life")
            try store.deleteGroup("study")
            let side = try store.addGroup(name: "side project")
            _ = try store.addTask(title: "Inbox note")
            source = try store.addTask(title: "Plan launch", category: "work")
            child = try store.addTask(title: "Review copy", category: "work", parentId: source.id)
            _ = try store.addTask(title: "Ship draft", category: "work")
            life = try [store.addTask(title: "Read a chapter", category: "life"), store.addTask(title: "Take a walk", category: "life")]
            _ = try store.addTask(title: "Sketch ideas", category: side.id)
            var patch = DotistSettingsPatch(); patch.language = "en"; patch.theme = "light"
            _ = try store.updateSettings(patch)
            model = try AppModel(store: store)
            // An unpersisted suite isolates collapse state from every real app.
            let defaults = UserDefaults(suiteName: "dotist-drag-fixture-" + UUID().uuidString)!
            state = TaskPanelState(scope: "all", collapseStore: TaskGroupCollapseStore(defaults: defaults))
            let view = MainWindow(model: model, state: state, showViews: {}, showSearch: {}, showSettings: {}, showGroupPanel: { _ in }, collapse: {}, reorderRuntime: self.runtime, dragMotion: self.motion)
                .onPreferenceChange(TaskListRowFrame.Key.self) { [weak self] in self?.rows = $0 }
                .onPreferenceChange(TaskListGroupFrame.Key.self) { [weak self] in self?.groups = $0 }
                .onPreferenceChange(TaskGhostFrameKey.self) { [weak self] in self?.ghost = $0 }
                .onPreferenceChange(TaskInsertionFramesKey.self) { [weak self] in self?.gaps = $0 }
                .background(Color.white).environment(\.colorScheme, .light)
            fixture = NativeRenderingFixture(AnyView(view), size: CGSize(width: width, height: height))
        }
        func close() { fixture.close(); runtime.handleInput = nil; try? FileManager.default.removeItem(at: directory) }
        func row(_ id: String) throws -> TaskListRowFrame { try XCTUnwrap(rows.first { $0.task.id == id }) }
        func capture(_ name: String) async throws -> NSBitmapImageRep {
            let image = try await fixture.capture(scale: 2)
            let base = ProcessInfo.processInfo.environment["DOTIST_DRAG_EVIDENCE"]
                .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("dotist-drag-renderings")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: base.appendingPathComponent("\(name)-\(Int(height)).png"))
            return image
        }
        func headers() -> [CGRect] {
            fixture.descendants(GroupHeaderInkView.self).map { fixture.host.convert($0.bounds, from: $0) }
        }
        func assertNoInFlowHeaderOverlap(file: StaticString = #filePath, line: UInt = #line) {
            for header in headers() {
                for row in rows {
                    XCTAssertFalse(header.intersects(row.frame), "Header \(header) overlaps \(row.task.title): \(row.frame)", file: file, line: line)
                }
                // The ghost is now full logical projection geometry. Check all
                // actual layout spaces, including the previous slot closing.
                for gap in gaps.values where !gap.isEmpty {
                    XCTAssertFalse(header.intersects(gap), "Header overlaps insertion space", file: file, line: line)
                }
            }
        }
    }

    func testCrossGroupGiveWayMovesNativeHeadingsAndRowsTogetherAtIntermediateHeights() async throws {
        let clock = LayoutMotionTestClock()
        defer { clock.restore() }
        for size in [CGSize(width: 364, height: 620), CGSize(width: 320, height: 540)] {
            let scene = try Scene(height: size.height, width: size.width)
            defer { scene.close() }
            _ = try await scene.capture("motion-before")
            let source = try scene.row(scene.source.id)
            let destination = try scene.row(scene.life[0].id)
            let sibling = try scene.row(scene.life[1].id)
            let header = try XCTUnwrap(scene.headers().max { $0.minY < $1.minY })
            let start = CGPoint(x: 100, y: source.frame.midY)
            let point = CGPoint(x: 100, y: destination.frame.midY + 1)
            scene.runtime.send(.begin(source.task.id, start))
            scene.runtime.send(.move(source.task.id, point))
            let fullHeight = try XCTUnwrap(scene.runtime.drag).startFrame.height
            XCTAssertTrue(scene.runtime.insertionMotion.heights.isEmpty, "Retarget must start from presented layout")
            try await clock.advance(by: 0.025)
            _ = try await scene.capture("motion-during")
            let intermediate = try scene.row(sibling.task.id).frame.minY - sibling.frame.minY
            let headerDelta = try XCTUnwrap(scene.headers().max { $0.minY < $1.minY }).minY - header.minY
            print("GIVE WAY size=\(size) intermediateRow=\(intermediate) nativeHeader=\(headerDelta) fullHeight=\(fullHeight)")
            XCTAssertGreaterThan(intermediate, 0)
            XCTAssertLessThan(intermediate, fullHeight)
            XCTAssertEqual(headerDelta, intermediate, accuracy: 0.5, "Native heading and SwiftUI row share every layout tick")
            XCTAssertEqual(scene.ghost.height, fullHeight, "Destination metadata retains the full reserved height")
            scene.assertNoInFlowHeaderOverlap()
            // A slow AX/bitmap operation must not silently consume the rest of
            // this logical frame. Inspect the real layout after a wall-clock
            // pause longer than the production transition's whole duration.
            let heldRow = try scene.row(sibling.task.id).frame
            let heldHeader = try XCTUnwrap(scene.headers().max { $0.minY < $1.minY })
            try await Task.sleep(for: .milliseconds(150))
            _ = try await scene.capture("motion-held")
            XCTAssertEqual(try scene.row(sibling.task.id).frame, heldRow)
            XCTAssertEqual(try XCTUnwrap(scene.headers().max { $0.minY < $1.minY }), heldHeader)
            scene.runtime.send(.move(source.task.id, point))
            XCTAssertEqual(scene.runtime.drag?.target?.beforeID, scene.life[1].id)

            // Reverse while the first slot is still moving. Both heights start
            // from their presented values; neither jumps to an endpoint.
            let presented = scene.runtime.insertionMotion.heights
            scene.runtime.send(.move(source.task.id, start))
            XCTAssertEqual(scene.runtime.insertionMotion.heights, presented)
            try await clock.advance(by: 0.020)
            _ = try await scene.capture("motion-reversal")
            scene.assertNoInFlowHeaderOverlap()
            scene.runtime.send(.move(source.task.id, point))
            try await clock.advance(by: 0.150)
            _ = try await scene.capture("motion-after")
            XCTAssertEqual(try scene.row(sibling.task.id).frame.minY - sibling.frame.minY, fullHeight, accuracy: 0.5)
            scene.assertNoInFlowHeaderOverlap()
            scene.runtime.send(.cancel)
        }
    }

    func testSameGroupDisplacementAndReducedMotionUseTheSameImmediateLayout() async throws {
        for reduced in [false, true] {
            let clock = LayoutMotionTestClock(reduceMotion: reduced)
            defer { clock.restore() }
            let scene = try Scene(height: 620)
            defer { scene.close() }
            _ = try await scene.capture("same-group-before-\(reduced)")
            let source = try scene.row(scene.life[1].id)
            let destination = try scene.row(scene.life[0].id)
            let point = CGPoint(x: 100, y: destination.frame.minY + 1)
            scene.runtime.send(.begin(source.task.id, CGPoint(x: 100, y: source.frame.midY)))
            scene.runtime.send(.move(source.task.id, point))
            if reduced {
                XCTAssertEqual(scene.runtime.insertionMotion.heights,
                               [.before(destination.task.id): source.frame.height],
                               "The real input handler must resolve Reduce Motion immediately")
            } else { try await clock.advance(by: 0.025) }
            _ = try await scene.capture("same-group-during-\(reduced)")
            let displacement = try scene.row(destination.task.id).frame.minY - destination.frame.minY
            if reduced {
                XCTAssertEqual(displacement, source.frame.height, "Reduce Motion applies final geometry immediately")
            } else {
                XCTAssertGreaterThan(displacement, 0)
                XCTAssertLessThan(displacement, source.frame.height)
            }
            scene.assertNoInFlowHeaderOverlap()
            scene.runtime.send(.move(source.task.id, point))
            XCTAssertEqual(scene.runtime.drag?.target?.beforeID, destination.task.id)
            scene.runtime.send(.cancel)
            _ = try await scene.capture("same-group-after-\(reduced)")
            XCTAssertEqual(try scene.row(destination.task.id).frame, destination.frame)
            XCTAssertTrue(scene.runtime.insertionMotion.heights.isEmpty)
            scene.assertNoInFlowHeaderOverlap()
        }
    }

    func testInsertionClockFastReversalAndReduceMotionSnapWithoutResidualTransforms() async throws {
        let motion = TaskInsertionMotion()
        let first = TaskInsertionSlot.before("first"), second = TaskInsertionSlot.before("second")
        motion.retarget(slot: first, height: 64, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(25))
        let presented = motion.heights
        XCTAssertGreaterThan(presented[first, default: 0], 0)
        XCTAssertLessThan(presented[first, default: 0], 64)
        motion.retarget(slot: second, height: 64, reduceMotion: false)
        XCTAssertEqual(motion.heights, presented)
        motion.retarget(slot: first, height: 64, reduceMotion: false)
        XCTAssertEqual(motion.heights, presented)
        motion.retarget(slot: second, height: 64, reduceMotion: true)
        XCTAssertEqual(motion.heights, [second: 64])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(motion.heights, [second: 64], "The interrupted timer must not restore an old height")
        motion.retarget(slot: nil, height: 0, reduceMotion: true)
        XCTAssertTrue(motion.heights.isEmpty)
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
                XCTAssertEqual(firstRow.frame.minY, header.maxY, accuracy: 0.5, "Header must sit directly above its first task")
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
            if let drag, drag.target != nil && drag.initialTarget == nil { transientGaps += 1 }
        }
        defer { observation.cancel() }
        scene.runtime.send(.begin(source.task.id, CGPoint(x: 100, y: source.frame.midY)))
        _ = try await scene.capture("initial-drag")
        XCTAssertEqual(transientGaps, 0, "The initial target must be complete before publishing; a partial state inserts a duplicate gap")
        XCTAssertTrue(scene.ghost.isEmpty)
        scene.runtime.send(.cancel)
    }

    func testSourceAndInsertionSpaceDoNotPaintDuplicateRows() async throws {
        let scene = try Scene(height: 620)
        defer { scene.close() }
        _ = try await scene.capture("duplicates-idle")
        let source = try scene.row(scene.source.id)
        let destination = try scene.row(scene.life[0].id)
        let start = CGPoint(x: 100, y: source.frame.midY)
        scene.runtime.send(.begin(source.task.id, start))
        scene.runtime.send(.move(source.task.id, CGPoint(x: 100, y: destination.frame.midY + 1)))
        _ = try await scene.capture("duplicates-drag")
        let drag = try XCTUnwrap(scene.runtime.drag)
        // Isolate in-flow paint by placing only the floating layer outside the
        // capture. Source identities, target and real insertion layout remain.
        scene.runtime.drag = TaskListDrag(taskID: drag.taskID, blockIDs: drag.blockIDs, visibleBlock: drag.visibleBlock,
            startFrame: drag.startFrame.offsetBy(dx: -1000, dy: 0), startLocation: drag.startLocation,
            target: drag.target, region: drag.region, ghostBeforeID: drag.ghostBeforeID, ghostAfterID: drag.ghostAfterID,
            targetIsEmpty: drag.targetIsEmpty, rootIDs: drag.rootIDs, sourceDepth: drag.sourceDepth,
            subtreeHeight: drag.subtreeHeight, initialTarget: drag.initialTarget)
        for _ in 0..<30 where scene.ghost.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            _ = try await scene.capture("duplicates-inflow")
        }
        let image = try await scene.capture("duplicates-inflow")
        XCTAssertFalse(scene.ghost.isEmpty)
        for rect in [source.frame, try scene.row(scene.child.id).frame, scene.ghost] {
            var ink = 0
            for y in Int(rect.minY * 2)..<Int(rect.maxY * 2) {
                for x in Int(rect.minX * 2)..<Int(rect.maxX * 2) {
                    if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       1 - max(color.redComponent, color.greenComponent, color.blueComponent) > 0.1 { ink += 1 }
                }
            }
            print("DUPLICATE INK rect=\(rect) pixels=\(ink)")
            XCTAssertEqual(ink, 0, "The floating block is the sole painted copy; source and insertion space stay clear")
        }
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
        try XCTUnwrap(baseline.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/dotist-pointer-baseline.png"))
        for point in [start, CGPoint(x: 120, y: 160), CGPoint(x: 70, y: 90)] {
            withAnimation(.linear(duration: 1)) { motion.location = point }
            let image = try await fixture.capture(scale: 1)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/dotist-pointer-moving.png"))
            var x0 = image.pixelsWide, y0 = image.pixelsHigh
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    if let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent - c.greenComponent > 0.5 && c.redComponent - c.blueComponent > 0.5 {
                        x0 = min(x0, x); y0 = min(y0, y)
                    }
                }
            }
            print("POINTER point=\(point) paintedOrigin=\(x0),\(y0)")
            XCTAssertEqual(CGFloat(x0), frame.minX, accuracy: 0.5)
            XCTAssertEqual(CGFloat(y0), frame.minY + point.y - start.y, accuracy: 0.5)
        }
    }
}
