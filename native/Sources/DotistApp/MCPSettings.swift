import AppKit
import DotistCore
import SwiftUI

struct MCPSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var service: MCPService
    @State private var client = "codex"
    @State private var copied = false

    private var configuration: String {
        let executable = Bundle.main.executableURL?.path ?? ""
        let data = Bundle.main.bundleIdentifier == "dev.codex.dotist-native-qa" ? ProcessInfo.processInfo.environment["DOTIST_DATA_DIR"] : nil
        if client == "json" {
            var entry: [String: Any] = ["command": executable, "args": ["--mcp"]]
            if let data { entry["env"] = ["DOTIST_DATA_DIR": data] }
            let value = ["mcpServers": ["dotist": entry]]
            return (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let environment = data.map { " \(client == "codex" ? "--env" : "-e") " + quote("DOTIST_DATA_DIR=" + $0) } ?? ""
        return client + " mcp add dotist" + environment + " -- " + quote(executable) + " --mcp"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(model.text("启用本地 MCP"), isOn: Binding(get: { model.settings.mcpEnabled }, set: {
                var patch = DotistSettingsPatch(); patch.mcpEnabled = $0; model.updateSettings(patch)
            })).toggleStyle(.switch)
            HStack(spacing: 7) {
                Circle().fill(service.running ? DotistDesign.accent : DotistDesign.faint).frame(width: 6, height: 6)
                Text(model.text(service.running ? "运行中" : service.starting ? "启动中…" : "已停止"))
                if service.running {
                    Text("·")
                    Text(model.text("已连接 {n} 个客户端").replacingOccurrences(of: "{n}", with: "\(service.connections)"))
                }
            }.font(.system(size: 12)).foregroundColor(DotistDesign.muted)
            if let error = service.error { Text(error).foregroundColor(DotistDesign.danger).font(.system(size: 12)) }
            Text(model.text("客户端通过本机连接读取和修改任务。修改会即时显示，普通操作不会抢走键盘焦点。"))
                .foregroundColor(DotistDesign.muted)
            Divider()
            Picker(model.text("客户端"), selection: $client) {
                Text("Codex").tag("codex")
                Text("Claude Code").tag("claude")
                Text(model.text("其他客户端")).tag("json")
            }.pickerStyle(.segmented)
            Text(model.text(client == "json" ? "将配置加入客户端的 MCP 设置。" : "复制命令，在终端执行后重新连接客户端。"))
                .font(.system(size: 12)).foregroundColor(DotistDesign.muted)
            Text(configuration).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(model.text(copied ? "已复制" : "复制")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(configuration, forType: .string)
                copied = true
            }.buttonStyle(DefaultButtonStyle())
                .accessibilityLabel(Text(model.text(client == "json" ? "复制客户端配置" : client == "codex" ? "复制 Codex 添加命令" : "复制 Claude Code 添加命令")))
            Text(model.text("支持批量添加、搜索、日期与状态调整、分组管理和删除恢复。"))
                .font(.system(size: 12)).foregroundColor(DotistDesign.muted)
        }.onChange(of: client) { _ in copied = false }
    }
}
