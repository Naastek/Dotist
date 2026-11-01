import Combine
import DotistCore
import Foundation
import XCTest
@testable import DotistApp

final class MCPLifecycleTests: XCTestCase {
    @MainActor func testDisablingWhileAcceptingNeverAllowsTaskWrites() async throws {
        for attempt in -1..<20 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-stop-probe-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
            let socket = "/tmp/dotist-stop-\(UUID().uuidString).sock"
            let service = MCPService(store: store, socketPath: socket)
            let observer = service.$connections.sink { count in
                if count > 0 && attempt >= 0 { Task { @MainActor in service.stop() } }
            }
            service.start()
            for _ in 0..<200 {
                if service.running || service.error != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(service.running)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
import json,socket,sys
client=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
client.settimeout(1.5)
try:
 client.connect(sys.argv[1])
 stream=client.makefile('rwb',buffering=0)
 def send(value): stream.write((json.dumps(value)+'\\n').encode())
 send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-03-26','capabilities':{},'clientInfo':{'name':'stop-probe','version':'1'}}})
 first=stream.readline()
 if first:
  send({'jsonrpc':'2.0','method':'notifications/initialized'})
  send({'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'add_tasks','arguments':{'category':'work','tasks':[{'title':'must be rejected after stop'}]}}})
  stream.readline()
except (OSError,ValueError):
 pass
finally:
 client.close()
""", socket]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            await Task.detached { process.waitUntilExit() }.value
            let count = try store.listTasks().count
            if attempt >= 0 {
                XCTAssertFalse(service.running)
                XCTAssertEqual(service.connections, 0)
            }
            observer.cancel()
            service.stop()
            try FileManager.default.removeItem(at: directory)
            let expected = attempt < 0 ? 1 : 0
            XCTAssertEqual(count, expected, attempt < 0 ? "The real client must write while the service is enabled" : "Stopped service accepted a write on attempt \(attempt)")
            if count != expected { return }
        }
    }
}
