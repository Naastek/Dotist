import AppKit
import Combine
import CoreText
import DotistCore
import SwiftUI

/// Explicit, QA-only diagnostics. The queued writer avoids file IO on the
/// gesture path, and no task titles or document contents are recorded.
enum TaskDragDiagnostics {
    private static let queue = DispatchQueue(label: "dotist.qa.drag-trace")
    static var enabled: Bool {
        Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa"
            && ProcessInfo.processInfo.environment["DOTIST_DRAG_TRACE"] == "1"
    }
    static func destination(bundleID: String?, bundleURL: URL, flag: String?, dataDirectory: String?) -> URL? {
        guard bundleID == "dev.codex.dotist-native-qa", flag == "1", let dataDirectory else { return nil }
        let directory = URL(fileURLWithPath: dataDirectory).standardizedFileURL
        let expected = bundleURL.deletingLastPathComponent().appendingPathComponent("data", isDirectory: true).standardizedFileURL
        guard directory.path == expected.path else { return nil }
        return directory.appendingPathComponent("drag-trace.ndjson")
    }
    static func record(_ event: String, fields: [String: String] = [:]) {
        guard let url = destination(bundleID: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL,
            flag: ProcessInfo.processInfo.environment["DOTIST_DRAG_TRACE"],
            dataDirectory: ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"]) else { return }
        let entry: [String: Any] = ["time": Date().timeIntervalSince1970,
            "uptime": ProcessInfo.processInfo.systemUptime, "pid": ProcessInfo.processInfo.processIdentifier,
            "event": event, "fields": fields]
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(10)
        let line = data
        queue.async {
            if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }
    static func flush() { queue.sync {} }
}

