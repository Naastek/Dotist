import Foundation
import XCTest
@testable import DotistApp

final class TaskDragDiagnosticsTests: XCTestCase {
    func testTraceDestinationRequiresQAIdentityOptInAndSiblingDataDirectory() {
        let app = URL(fileURLWithPath: "/private/tmp/dotist-trace-probe/Dotist-Native-QA.app")
        let data = "/private/tmp/dotist-trace-probe/data"
        func destination(_ id: String? = "dev.codex.dotist-native-qa", flag: String? = "1", path: String? = nil) -> URL? {
            TaskDragDiagnostics.destination(bundleID: id, bundleURL: app, flag: flag, dataDirectory: path ?? data)
        }
        XCTAssertEqual(destination()?.path, data + "/drag-trace.ndjson")
        XCTAssertNil(destination("com.dotist.app"), "The installed user app must never log pointer data")
        XCTAssertNil(destination(nil))
        XCTAssertNil(destination(flag: nil))
        XCTAssertNil(destination(flag: "0"))
        XCTAssertNil(destination(path: "/private/tmp/a-different-qa/data"))
        XCTAssertNil(TaskDragDiagnostics.destination(bundleID: "dev.codex.dotist-native-qa", bundleURL: app, flag: "1", dataDirectory: nil))
    }
}
