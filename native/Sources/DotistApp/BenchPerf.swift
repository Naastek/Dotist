#if DOTIST_BENCH
import AppKit
import QuartzCore

@MainActor
enum BenchPerf {
    static let enabled = ProcessInfo.processInfo.environment["DOTIST_BENCH_PERF"] == "1"
    static let noActivate = ProcessInfo.processInfo.environment["DOTIST_BENCH_NO_ACTIVATE"] == "1"

    enum Counter: String, CaseIterable {
        case sideTabsSynchronize
        case sideTabsLayout
        case sideTabTick
        case timer30Hz
        case timer10Hz
        case idleTimer
        case floatingPanelBody
        case mainWindowBody
        case surfaceInsets
        case shadowRefresh
        case shadowTick
        case panelSetFrame
        case panelSetFrameSkipped
    }

    private struct FrameSample {
        var wallStart: Double
        var wallEnd: Double = 0
        var linkTimestamp: Double
        var linkTargetTimestamp: Double
        var setFrameMs: Double = 0
        var beforeWaiting: Double?
    }

    private struct Span {
        var kind: String
        var start: CFTimeInterval
        var period: Double
        var baseline: [Counter: Int]
        var frames: [FrameSample] = []
        var driverReady: Double?
        var inTick = false
        var ending = false
    }

    private static var counters: [Counter: Int] = [:]
    private static var span: Span?
    private static var runLoopObserver: CFRunLoopObserver?

    private static func ensureRunLoopObserver() {
        guard runLoopObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            Int.max
        ) { _, _ in
            MainActor.assumeIsolated {
                guard var s = BenchPerf.span, !s.frames.isEmpty else { return }
                let idx = s.frames.count - 1
                if s.frames[idx].wallEnd > 0, s.frames[idx].beforeWaiting == nil {
                    s.frames[idx].beforeWaiting = CACurrentMediaTime()
                    BenchPerf.span = s
                }
            }
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            runLoopObserver = observer
        }
    }

    static func count(_ counter: Counter) {
        guard enabled else { return }
        counters[counter, default: 0] += 1
    }

    static func begin(_ kind: String, period: Double = 0) {
        guard enabled else { return }
        ensureRunLoopObserver()
        span = Span(kind: kind, start: CACurrentMediaTime(), period: period, baseline: counters)
    }

    static func driverStarted(kind: String, period: Double) {
        guard enabled else { return }
        if span?.kind != kind { begin(kind, period: period) }
        span?.period = period
        span?.driverReady = CACurrentMediaTime()
    }

    static func tickStart(linkTimestamp: Double = 0, linkTargetTimestamp: Double = 0) {
        guard enabled, span != nil else { return }
        let period = linkTargetTimestamp - linkTimestamp
        if period > 0 { span?.period = period }
        span?.frames.append(FrameSample(
            wallStart: CACurrentMediaTime(),
            linkTimestamp: linkTimestamp,
            linkTargetTimestamp: linkTargetTimestamp
        ))
        span?.inTick = true
    }

    static func recordSetFrameMs(_ ms: Double) {
        guard enabled, var s = span, !s.frames.isEmpty else { return }
        s.frames[s.frames.count - 1].setFrameMs += ms
        span = s
    }

    static func tickEnd() {
        guard enabled, var s = span, !s.frames.isEmpty, s.inTick else { return }
        s.frames[s.frames.count - 1].wallEnd = CACurrentMediaTime()
        s.inTick = false
        span = s
        if s.ending { finish() }
    }

    static func end() {
        guard enabled, span != nil else { return }
        if span?.inTick == true { span?.ending = true } else { finish() }
    }

    private static func finish() {
        guard let s = span else { return }
        span = nil
        func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        func percentile(_ values: [Double], _ p: Double) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1))
            return sorted[index]
        }
        func val(_ x: Double?) -> Any { x.map { round3($0) } ?? NSNull() }
        func stats(_ values: [Double]) -> [String: Any] {
            [
                "mean": val(values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)),
                "p50": val(percentile(values, 0.5)),
                "p95": val(percentile(values, 0.95)),
                "max": val(values.max()),
            ]
        }

        let deltas = Dictionary(uniqueKeysWithValues: Counter.allCases.map {
            ($0.rawValue, counters[$0, default: 0] - s.baseline[$0, default: 0])
        })
        let durationMs = round3((CACurrentMediaTime() - s.start) * 1000)
        var line: [String: Any] = [
            "kind": s.kind,
            "counters": deltas,
        ]
        if s.kind == "idle" {
            line["duration_ms"] = durationMs
        } else {
            let wallIntervals = zip(s.frames.dropFirst(), s.frames).map { ($0.wallStart - $1.wallStart) * 1000 }
            let vsyncIntervals = zip(s.frames.dropFirst(), s.frames).compactMap { a, b -> Double? in
                guard a.linkTimestamp > 0, b.linkTimestamp > 0 else { return nil }
                return (a.linkTimestamp - b.linkTimestamp) * 1000
            }
            let targetIntervals = zip(s.frames.dropFirst(), s.frames).compactMap { a, b -> Double? in
                guard a.linkTargetTimestamp > 0, b.linkTargetTimestamp > 0 else { return nil }
                return (a.linkTargetTimestamp - b.linkTargetTimestamp) * 1000
            }
            let ticks = s.frames.map { ($0.wallEnd - $0.wallStart) * 1000 }
            let setFrames = s.frames.map(\.setFrameMs)
            let commits = s.frames.compactMap { f -> Double? in
                guard let bw = f.beforeWaiting, f.wallEnd > 0 else { return nil }
                return max(0, (bw - f.wallEnd) * 1000)
            }
            let waitGaps = zip(s.frames.dropFirst(), s.frames).compactMap { next, prev -> Double? in
                guard let bw = prev.beforeWaiting else { return nil }
                return max(0, (next.wallStart - bw) * 1000)
            }
            let lateness = s.frames.compactMap { f -> Double? in
                guard f.linkTimestamp > 0 else { return nil }
                return (f.wallStart - f.linkTimestamp) * 1000
            }

            line["total_ms"] = durationMs
            line["frames"] = s.frames.count
            line["trace_start_host_s"] = s.start
            line["prepare_ms"] = val(s.driverReady.map { ($0 - s.start) * 1000 })
            line["trace_frames"] = s.frames.map { frame -> [String: Any] in
                [
                    "start_ms": round3((frame.wallStart - s.start) * 1000),
                    "end_ms": round3((frame.wallEnd - s.start) * 1000),
                    "resize_ms": round3(frame.setFrameMs),
                    "sleep_ms": val(frame.beforeWaiting.map { ($0 - s.start) * 1000 }),
                    "target_ms": val(frame.linkTargetTimestamp > 0 ? (frame.linkTargetTimestamp - s.start) * 1000 : nil),
                ]
            }
            line["toggle_to_first_tick_ms"] = val(s.frames.first.map { ($0.wallStart - s.start) * 1000 })
            line["refresh_period_ms"] = val(s.period > 0 ? s.period * 1000 : nil)
            line["interval_ms"] = stats(wallIntervals)
            line["vsync_interval_ms"] = stats(vsyncIntervals)
            line["target_interval_ms"] = stats(targetIntervals)
            line["dropped"] = s.period > 0 ? wallIntervals.filter { $0 > s.period * 1500 }.count : 0
            line["tick_ms"] = stats(ticks)
            line["set_frame_ms"] = stats(setFrames)
            line["commit_after_tick_ms"] = stats(commits)
            line["wait_to_next_tick_ms"] = stats(waitGaps)
            line["callback_lateness_ms"] = stats(lateness)
            if let maxIdx = wallIntervals.indices.max(by: { wallIntervals[$0] < wallIntervals[$1] }) {
                let prev = s.frames[maxIdx]
                let next = s.frames[maxIdx + 1]
                line["worst_interval_detail"] = [
                    "frame_index": maxIdx + 1,
                    "wall_interval_ms": round3(wallIntervals[maxIdx]),
                    "prev_tick_ms": round3((prev.wallEnd - prev.wallStart) * 1000),
                    "prev_set_frame_ms": round3(prev.setFrameMs),
                    "prev_commit_ms": val(prev.beforeWaiting.map { max(0, ($0 - prev.wallEnd) * 1000) }),
                    "wait_to_next_tick_ms": val(prev.beforeWaiting.map { max(0, (next.wallStart - $0) * 1000) }),
                ]
            }
        }
        append(line)
    }

    static func append(_ line: [String: Any]) {
        guard enabled,
              let directory = ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"],
              let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("bench-perf.jsonl")
        let payload = data + Data([10])
        if let file = try? FileHandle(forWritingTo: url) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .withoutOverwriting)
        }
    }
}

@MainActor
final class BenchPerfDriver {
    private let toggle: () -> Void
    init(toggle: @escaping () -> Void) { self.toggle = toggle }

    func start() {
        let env = ProcessInfo.processInfo.environment
        guard BenchPerf.enabled else { return }
        let settle = Double(env["DOTIST_BENCH_SETTLE"] ?? "6.0") ?? 6.0
        let toggles = max(0, Int(env["DOTIST_BENCH_TOGGLE"] ?? "0") ?? 0)
        let gap = Double(env["DOTIST_BENCH_TOGGLE_GAP"] ?? "1.0") ?? 1.0
        let idle = max(0, Double(env["DOTIST_BENCH_IDLE"] ?? "0") ?? 0)
        let autoExit = env["DOTIST_BENCH_EXIT"] == "1"
        guard toggles > 0 || idle > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            self.runIdle(idle) {
                self.runToggles(toggles, gap: gap) {
                    BenchPerf.append(["kind": "done"])
                    if autoExit {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    private func runIdle(_ duration: Double, completion: @escaping () -> Void) {
        guard duration > 0 else { completion(); return }
        BenchPerf.begin("idle", period: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            BenchPerf.end()
            completion()
        }
    }

    private func runToggles(_ remaining: Int, gap: Double, completion: @escaping () -> Void) {
        guard remaining > 0 else { completion(); return }
        toggle()
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            self.runToggles(remaining - 1, gap: gap, completion: completion)
        }
    }
}
#endif
