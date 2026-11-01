import DotistCore
import Darwin
import Foundation
import MCP
import Network
import XCTest
@testable import DotistApp

final class MCPTests: XCTestCase {
    private func store() throws -> TaskStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try TaskStore(databasePath: directory.appendingPathComponent("tasks.sqlite").path)
    }

    @MainActor func testToolsUseOneAtomicStoreAndOnlyExplicitFocusRequestsFocus() async throws {
        let store = try store()
        var focused = false
        let tools = DotistMCPTools(store: store, focus: { _ in focused = true })
        let invalid = await tools.call("add_tasks", ["category": "work", "tasks": [
            ["title": "有效"], ["title": "无效", "due_date": "2026-02-30"]
        ]])
        XCTAssertEqual(invalid.isError, true)
        XCTAssertTrue(try store.listTasks().isEmpty)
        let typo = await tools.call("add_tasks", ["category": "work", "tasks": [["title": "日期拼错", "due_data": "2026-11-10"]]])
        XCTAssertEqual(typo.isError, true)
        XCTAssertTrue(try store.listTasks().isEmpty)
        let created = await tools.call("add_tasks", ["category": "工作", "tasks": [["title": "第一项"], ["title": "第二项"]]])
        XCTAssertNotEqual(created.isError, true)
        XCTAssertEqual(try store.listTasks().count, 2)
        XCTAssertFalse(focused)
        let id = try XCTUnwrap(store.listTasks().first?.id)
        let updated = await tools.call("update_task", ["id": .string(id), "status": "doing"])
        XCTAssertNotEqual(updated.isError, true)
        XCTAssertEqual(try store.listTasks().first?.status, .doing)
        XCTAssertFalse(focused)
        let focus = await tools.call("focus_task", ["id": .string(id)])
        XCTAssertNotEqual(focus.isError, true)
        XCTAssertTrue(focused)
        let deleted = await tools.call("delete_task", ["id": .string(id)])
        let restored = await tools.call("restore_task", ["id": .string(id)])
        XCTAssertNotEqual(deleted.isError, true)
        XCTAssertNotEqual(restored.isError, true)
        XCTAssertEqual(try store.listTasks().count, 2)
    }

    @MainActor func testSDKSessionsShareLiveDataAndStopRemovesTheSocket() async throws {
        let store = try store()
        let socket = "/tmp/dotist-\(UUID().uuidString).sock"
        let service = MCPService(store: store, socketPath: socket)
        defer { service.stop() }
        service.start()
        for _ in 0..<200 {
            if service.running || service.error != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(service.error)
        XCTAssertTrue(service.running)
        guard service.running else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: socket)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let first = Client(name: "first", version: "1")
        let second = Client(name: "second", version: "1")
        let transport1 = NetworkTransport(connection: NWConnection(to: .unix(path: socket), using: .tcp), heartbeatConfig: .init(enabled: false), reconnectionConfig: .init(enabled: false))
        let transport2 = NetworkTransport(connection: NWConnection(to: .unix(path: socket), using: .tcp), heartbeatConfig: .init(enabled: false), reconnectionConfig: .init(enabled: false))
        _ = try await first.connect(transport: transport1)
        _ = try await second.connect(transport: transport2)
        let tools = try await first.listTools()
        XCTAssertTrue(tools.tools.contains { $0.name == "add_tasks" })
        XCTAssertTrue(tools.tools.first { $0.name == "list_tasks" }?.annotations.readOnlyHint == true)
        XCTAssertEqual(service.connections, 2)
        let created = try await first.callTool(name: "add_tasks", arguments: ["category": "work", "tasks": [["title": "跨客户端可见"]]])
        XCTAssertNotEqual(created.isError, true)
        let read = try await second.callTool(name: "list_tasks")
        guard case .text(let text, _, _) = read.content.first else { return XCTFail("Missing actual task result") }
        XCTAssertTrue(text.contains("跨客户端可见"))
        await first.disconnect()
        await second.disconnect()
        service.stop()
        XCTAssertEqual(service.connections, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
    }

    @MainActor func testSocketPathNeverOverwritesAnExistingRegularFile() throws {
        let store = try store()
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("dotist-protected-\(UUID().uuidString)").path
        try Data("keep".utf8).write(to: URL(fileURLWithPath: socket))
        defer { try? FileManager.default.removeItem(atPath: socket) }
        let service = MCPService(store: store, socketPath: socket)
        service.start()
        XCTAssertNotNil(service.error)
        XCTAssertEqual(try String(contentsOfFile: socket, encoding: .utf8), "keep")
        service.stop()
        XCTAssertEqual(try String(contentsOfFile: socket, encoding: .utf8), "keep")
    }

    @MainActor func testStaleSocketRecoversAndALiveServiceIsNotRemoved() async throws {
        let store = try store()
        let path = "/tmp/dotist-stale-\(UUID().uuidString).sock"
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8) + [0])
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        Darwin.close(descriptor)
        XCTAssertEqual(bound, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let service = MCPService(store: store, socketPath: path)
        defer { service.stop() }
        service.start()
        for _ in 0..<200 {
            if service.running || service.error != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(service.error)
        XCTAssertTrue(service.running)
        let other = MCPService(store: store, socketPath: path)
        other.start()
        for _ in 0..<200 {
            if other.error != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(other.error)
        other.stop()
        XCTAssertTrue(service.running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        service.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
