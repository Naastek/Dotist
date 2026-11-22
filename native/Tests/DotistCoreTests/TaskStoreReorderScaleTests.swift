import Foundation
import XCTest
@testable import DotistCore

final class TaskStoreReorderScaleTests: XCTestCase {
    func testReorderPreservesCrossGroupManualOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-reorder-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaskStore(databasePath: dir.appendingPathComponent("tasks.sqlite").path)

        let w1 = try store.addTask(title: "W1", category: "work")
        let l1 = try store.addTask(title: "L1", category: "life")
        let s1 = try store.addTask(title: "S1", category: "study")
        let w2 = try store.addTask(title: "W2", category: "work")
        let l2 = try store.addTask(title: "L2", category: "life")

        func globalOrder() throws -> [String] {
            try store.listTasks().sorted { ($0.position, $0.id) < ($1.position, $1.id) }.map(\.id)
        }

        // Establish a known cross-group manual order first: [w1, l1, s1, w2, l2].
        try store.reorder(l1.id, relativeTo: w1.id, after: true, allTasks: true)
        try store.reorder(s1.id, relativeTo: l1.id, after: true, allTasks: true)
        try store.reorder(w2.id, relativeTo: s1.id, after: true, allTasks: true)
        try store.reorder(l2.id, relativeTo: w2.id, after: true, allTasks: true)
        XCTAssertEqual(try globalOrder(), [w1.id, l1.id, s1.id, w2.id, l2.id])

        // Move l2 before w1 in cross-group ("allTasks") view.
        try store.reorder(l2.id, relativeTo: w1.id, after: false, allTasks: true)
        XCTAssertEqual(try globalOrder(), [l2.id, w1.id, l1.id, s1.id, w2.id])

        // Move s1 after w2 in cross-group view; unrelated manual order must stay intact.
        try store.reorder(s1.id, relativeTo: w2.id, after: true, allTasks: true)
        XCTAssertEqual(try globalOrder(), [l2.id, w1.id, l1.id, w2.id, s1.id])

        // Within-group order for "work" stays [w1, w2], and for "life" stays [l2, l1].
        let all = try store.listTasks()
        let workOrder = all.filter { $0.category == "work" }.sorted { ($0.position, $0.id) < ($1.position, $1.id) }.map(\.id)
        let lifeOrder = all.filter { $0.category == "life" }.sorted { ($0.position, $0.id) < ($1.position, $1.id) }.map(\.id)
        XCTAssertEqual(workOrder, [w1.id, w2.id])
        XCTAssertEqual(lifeOrder, [l2.id, l1.id])
    }

    func testReorderLatencyAt150_1000_5000Tasks() throws {
        let groups = [DotistGroup.inboxID, "work", "life", "study"]
        for count in [150, 1000, 5000] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-reorder-scale-\(count)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = try TaskStore(databasePath: dir.appendingPathComponent("tasks.sqlite").path)
            let batch = (0..<count).map { idx in
                TaskStore.NewTask(
                    title: "Task #\(idx) with realistic title text and tags #proj\(idx % 7) #p\(idx % 3)",
                    category: groups[idx % groups.count],
                    dueDate: idx % 4 == 0 ? "2026-12-01" : nil
                )
            }
            let created = try store.addTasks(batch)
            let first = created[0].id
            let middle = created[count / 2].id
            let last = created[count - 1].id

            // Warm up SQLite page cache once.
            try store.reorder(last, relativeTo: first, after: false, allTasks: true)

            let iterations = 20
            var samples: [Double] = []
            samples.reserveCapacity(iterations)
            for i in 0..<iterations {
                let t0 = ContinuousClock.now
                if i % 2 == 0 {
                    try store.reorder(last, relativeTo: middle, after: true, allTasks: true)
                } else {
                    try store.reorder(last, relativeTo: first, after: false, allTasks: true)
                }
                let dt = t0.duration(to: .now)
                samples.append(Double(dt.components.seconds) * 1000.0 + Double(dt.components.attoseconds) / 1e15)
            }
            samples.sort()
            let med = samples[samples.count / 2]
            let mean = samples.reduce(0, +) / Double(samples.count)
            let p95 = samples[min(samples.count - 1, Int(Double(samples.count - 1) * 0.95))]
            print("REORDER_BENCH count=\(count) iters=\(iterations) med_ms=\(String(format: "%.3f", med)) mean_ms=\(String(format: "%.3f", mean)) p95_ms=\(String(format: "%.3f", p95))")
        }
    }
}
