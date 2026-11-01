import AppKit
import Network

enum MCPProxy {
    @MainActor static func run() -> Never {
        let socket = MCPService.socketPath
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL == Bundle.main.bundleURL && $0.processIdentifier != getpid() && $0.activationPolicy != .prohibited
        }
        if !running, Bundle.main.bundleURL.pathExtension == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = ["--background"]
            configuration.environment = ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"].map { ["DOTIST_DATA_DIR": $0] } ?? [:]
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        }
        connect(socket, remaining: 40)
        dispatchMain()
    }

    private static func connect(_ socket: String, remaining: Int) {
        let connection = NWConnection(to: .unix(path: socket), using: .tcp)
        let queue = DispatchQueue(label: "dev.dotist.mcp.proxy")
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                FileHandle.standardInput.readabilityHandler = { input in
                    let data = input.availableData
                    guard !data.isEmpty else { input.readabilityHandler = nil; connection.cancel(); exit(0) }
                    connection.send(content: data, completion: .contentProcessed { error in
                        if error != nil { exit(1) }
                    })
                }
                receive(connection)
            case .failed, .waiting:
                connection.stateUpdateHandler = nil
                connection.cancel()
                guard remaining > 0 else { fail("Dotist MCP 未启用。请在 Dotist 设置 → MCP 中启用本地服务。") }
                queue.asyncAfter(deadline: .now() + .milliseconds(250)) { connect(socket, remaining: remaining - 1) }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private static func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data, !data.isEmpty {
                do { try FileHandle.standardOutput.write(contentsOf: data) }
                catch { exit(1) }
            }
            if complete || error != nil { exit(error == nil ? 0 : 1) }
            receive(connection)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
