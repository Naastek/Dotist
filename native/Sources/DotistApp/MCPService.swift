import DotistCore
import Foundation
import MCP
import Network

@MainActor
final class MCPService: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var connections = 0
    @Published private(set) var error: String?
    var focus: @MainActor @Sendable (DotistTask?) -> Void = { _ in }
    nonisolated static var socketPath: String { TaskStore.dataDirectory.appendingPathComponent("mcp.sock").path }
    private let store: TaskStore
    private let socketPath: String
    private var listener: NWListener?
    private var probe: NWConnection?
    private var sessions: [ObjectIdentifier: (server: Server, connection: NWConnection)] = [:]
    private var generation = UUID()
    private var ownsSocket = false

    init(store: TaskStore, socketPath: String = MCPService.socketPath) {
        self.store = store
        self.socketPath = socketPath
    }

    func start() {
        guard listener == nil, probe == nil else { return }
        error = nil
        starting = true
        guard FileManager.default.fileExists(atPath: socketPath) else { bind(); return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
            guard attributes[.type] as? FileAttributeType == .typeSocket,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw TaskStoreError("MCP 路径被其他文件占用")
            }
            let generation = self.generation
            let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
            probe = connection
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == generation, self.probe != nil else { return }
                    switch state {
                    case .ready:
                        connection.cancel()
                        self.probe = nil
                        self.starting = false
                        self.error = "已有另一个 Dotist MCP 服务在使用此数据目录"
                    case .waiting(let failure), .failed(let failure):
                        connection.cancel()
                        self.probe = nil
                        guard case .posix(let code) = failure, code == .ECONNREFUSED || code == .ENOENT else {
                            self.starting = false
                            self.error = failure.localizedDescription
                            return
                        }
                        do {
                            if FileManager.default.fileExists(atPath: self.socketPath) { try FileManager.default.removeItem(atPath: self.socketPath) }
                            self.bind()
                        } catch { self.starting = false; self.error = error.localizedDescription }
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
        } catch { starting = false; self.error = error.localizedDescription }
    }

    private func bind() {
        do {
            guard socketPath.utf8.count < 104 else { throw TaskStoreError("MCP 数据目录路径过长") }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: socketPath)
            let listener = try NWListener(using: parameters)
            let generation = UUID()
            self.generation = generation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    switch state {
                    case .ready:
                        self.ownsSocket = true
                        guard chmod(self.socketPath, 0o600) == 0 else {
                            self.stop()
                            self.error = "无法设置 MCP 连接权限"
                            return
                        }
                        self.starting = false
                        self.running = true
                    case .failed(let failure):
                        self.stop()
                        self.error = failure.localizedDescription
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, generation: generation) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch { starting = false; self.error = error.localizedDescription }
    }

    func stop() {
        generation = UUID()
        probe?.cancel()
        probe = nil
        listener?.cancel()
        listener = nil
        let open = sessions.values
        sessions.removeAll()
        for session in open {
            // Cancel even connections whose SDK transport has not finished starting.
            session.connection.cancel()
            Task { await session.server.stop() }
        }
        connections = 0
        running = false
        starting = false
        if ownsSocket {
            do { try FileManager.default.removeItem(atPath: socketPath) }
            catch { self.error = error.localizedDescription }
            ownsSocket = false
        }
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard self.generation == generation, listener != nil else { connection.cancel(); return }
        let transport = NetworkTransport(connection: connection, heartbeatConfig: .init(enabled: false), reconnectionConfig: .init(enabled: false))
        let server = Server(name: "Dotist", version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                            instructions: """
                            Dotist is a local macOS task manager. Writes update the UI live without taking focus.
                            Tasks use stable ids, one level of subtasks, local YYYY-MM-DD dates and todo/doing/done status.
                            Completing a parent completes its children; children never auto-complete their parent.
                            Deletions are restorable. Use add_tasks for an atomic batch and focus_task only when explicitly asked to show a task.
                            """, capabilities: .init(tools: .init()))
        let key = ObjectIdentifier(server)
        sessions[key] = (server, connection)
        connections = sessions.count
        let tools = DotistMCPTools(store: store, focus: focus)
        Task { [weak self] in
            await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools.definitions()) }
            await server.withMethodHandler(CallTool.self) { await tools.call($0.name, $0.arguments) }
            guard self?.generation == generation else { connection.cancel(); return }
            do { try await server.start(transport: transport) }
            catch {
                await server.stop()
                guard let self, self.generation == generation else { return }
                self.error = error.localizedDescription
                self.sessions.removeValue(forKey: key)
                self.connections = self.sessions.count
                return
            }
            await server.waitUntilCompleted()
            guard let self, self.generation == generation else { return }
            self.sessions.removeValue(forKey: key)
            self.connections = self.sessions.count
        }
    }
}
