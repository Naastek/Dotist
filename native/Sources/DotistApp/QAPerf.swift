import AppKit
import QuartzCore

@MainActor
enum QAPerf {
    static let enabled = Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa" && ProcessInfo.processInfo.environment["DOTIST_QA_PERF"] == "1"
    enum Counter: String, CaseIterable {
        case sideTabsSynchronize, sideTabsLayout, sideTabTick, shadowSynchronize, shadowRender, shadowSetFrame, sideTabSetFrame, surfaceInsets, floatingPanelBody, taskListBody, taskListEntries, bubbleContent, timer30Hz, timer10Hz, idleTimer
    }
    private struct Span {
        var kind: String; var start: CFTimeInterval; var period: Double
        var baseline: [Counter: Int]; var starts: [Double] = []; var ticks: [Double] = []
        var inTick = false; var ending = false
        var marks: [String: Double] = [:]
    }
    private static var counters: [Counter: Int] = [:]
    private static var span: Span?
    static func count(_ counter: Counter) { counters[counter, default: 0] += 1 }
    static func begin(_ kind: String, period: Double) {
        span = Span(kind: kind, start: CACurrentMediaTime(), period: period, baseline: counters)
    }
    static func mark(_ name: String) {
        guard let start = span?.start else { return }
        span?.marks[name] = (CACurrentMediaTime() - start) * 1000
    }
    static func updatePeriod(_ period: Double) { if period > 0 { span?.period = period } }
    static func tickStart(period: Double? = nil) {
        guard span != nil else { return }
        if let period, period > 0 { span?.period = period }
        span?.starts.append(CACurrentMediaTime()); span?.inTick = true
    }
    static func tickEnd() {
        guard let start = span?.starts.last, span?.inTick == true else { return }
        span?.ticks.append((CACurrentMediaTime() - start) * 1000); span?.inTick = false
        if span?.ending == true { finish() }
    }
    static func end() {
        guard span != nil else { return }
        if span?.inTick == true { span?.ending = true } else { finish() }
    }
    private static func finish() {
        guard let s = span else { return }; span = nil
        let intervals = zip(s.starts.dropFirst(), s.starts).map { ($0 - $1) * 1000 }
        func percentile(_ values: [Double], _ p: Double) -> Double? {
            guard !values.isEmpty else { return nil }; let sorted = values.sorted()
            return sorted[Int(ceil(Double(sorted.count) * p)) - 1]
        }
        func value(_ x: Double?) -> Any { x.map { $0 as Any } ?? NSNull() }
        let deltas = Dictionary(uniqueKeysWithValues: Counter.allCases.map { ($0.rawValue, counters[$0, default: 0] - s.baseline[$0, default: 0]) })
        var line: [String: Any] = ["kind": s.kind, "duration_ms": (CACurrentMediaTime() - s.start) * 1000, "counters": deltas]
        if s.kind != "idle" {
            line["total_ms"] = line.removeValue(forKey: "duration_ms")
            line["preparation_ms"] = s.marks
            line["frames"] = s.starts.count; line["toggle_to_first_tick_ms"] = value(s.starts.first.map { ($0 - s.start) * 1000 })
            line["refresh_period_ms"] = s.period * 1000
            line["interval_ms"] = ["p50": value(percentile(intervals, 0.5)), "p95": value(percentile(intervals, 0.95)), "max": value(intervals.max())]
            line["dropped"] = intervals.filter { $0 > s.period * 1500 }.count
            line["tick_ms"] = ["mean": value(s.ticks.isEmpty ? nil : s.ticks.reduce(0, +) / Double(s.ticks.count)), "p95": value(percentile(s.ticks, 0.95)), "max": value(s.ticks.max())]
        }
        append(line)
    }
    static func append(_ line: [String: Any]) {
        guard let directory = ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"], let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), let file = try? FileHandle(forWritingTo: URL(fileURLWithPath: directory).appendingPathComponent("perf.log")) else {
            // Create the log on first use; report errors rather than hiding missing results.
            guard let directory = ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"], let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { fputs("QA perf: missing data directory or invalid JSON\n", stderr); return }
            let url = URL(fileURLWithPath: directory).appendingPathComponent("perf.log")
            do { try (data + Data([10])).write(to: url, options: .withoutOverwriting) } catch { fputs("QA perf: cannot create perf.log: \(error)\n", stderr) }; return
        }
        defer { try? file.close() }
        do { try file.seekToEnd(); try file.write(contentsOf: data + Data([10])) } catch { fputs("QA perf: cannot append perf.log: \(error)\n", stderr) }
    }
}

@MainActor
final class QAPerfDriver: NSObject {
    private weak var panel: NSWindow?
    private let toggle: () -> Void
    private let isBubble: () -> Bool
    private var link: CADisplayLink?
    private var origin = NSPoint.zero
    private var moveStart: CFTimeInterval = 0
    private var afterMove: (() -> Void)?
    init(panel: NSWindow, toggle: @escaping () -> Void, isBubble: @escaping () -> Bool) { self.panel = panel; self.toggle = toggle; self.isBubble = isBubble }
    func start() {
        let env = ProcessInfo.processInfo.environment
        let count = max(0, Int(env["DOTIST_QA_TOGGLE"] ?? "0") ?? 0)
        let move = env["DOTIST_QA_MOVE"] == "1"
        let idle = max(0, Double(env["DOTIST_QA_IDLE"] ?? "0") ?? 0)
        guard env["DOTIST_QA_TOGGLE"] != nil || move || env["DOTIST_QA_IDLE"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.toggles(count, move: move, idle: idle) }
    }
    private func toggles(_ remaining: Int, move: Bool, idle: Double) {
        guard remaining > 0 else { runMoves(move, idle: idle); return }
        toggle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.toggles(remaining - 1, move: move, idle: idle) }
    }
    private func runMoves(_ move: Bool, idle: Double) {
        guard move else { runIdle(idle); return }
        if isBubble() { toggle(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.move("move") { self.bubbleMove(idle) } } }
        else { self.move("move") { self.bubbleMove(idle) } }
    }
    private func bubbleMove(_ idle: Double) {
        if !isBubble() { toggle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if self.isBubble() { self.move("move_bubble") { self.runIdle(idle) } } else { self.runIdle(idle) }
        }
    }
    private func move(_ kind: String, completion: @escaping () -> Void) {
        guard let panel, let view = panel.contentView, panel.isVisible, panel.screen != nil else { completion(); return }
        origin = panel.frame.origin; moveStart = CACurrentMediaTime(); afterMove = completion
        let link = view.displayLink(target: self, selector: #selector(moveTick(_:)))
        self.link = link; QAPerf.begin(kind, period: link.duration); link.add(to: .main, forMode: .common)
    }
    @objc private func moveTick(_ link: CADisplayLink) {
        QAPerf.tickStart(period: link.targetTimestamp - link.timestamp)
        let elapsed = CACurrentMediaTime() - moveStart
        let phase = min(1, elapsed / 2)
        panel?.setFrameOrigin(NSPoint(x: origin.x + 240 * (phase <= 0.5 ? phase * 2 : (1 - phase) * 2), y: origin.y))
        if elapsed >= 2 { link.invalidate(); self.link = nil; QAPerf.end() }
        QAPerf.tickEnd()
        if elapsed >= 2 { let next = afterMove; afterMove = nil; next?() }
    }
    private func runIdle(_ duration: Double) {
        guard duration > 0 else { QAPerf.append(["kind": "done"]); return }
        QAPerf.begin("idle", period: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { QAPerf.end(); QAPerf.append(["kind": "done"]) }
    }
}
