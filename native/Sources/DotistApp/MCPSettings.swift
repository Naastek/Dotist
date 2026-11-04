import AppKit
import DotistCore
import SwiftUI

struct MCPSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var service: MCPService
    var emphasized: String? = nil
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
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(model.text("MCP"), footer: model.text("客户端通过本机连接读取和修改任务。修改会即时显示，普通操作不会抢走键盘焦点。"), language: model.language) {
                SettingsFormRow(title: model.text("启用本地 MCP"), language: model.language, emphasized: emphasized == "mcp.启用本地 MCP") {
                    Toggle(model.text("启用本地 MCP"), isOn: Binding(get: { model.settings.mcpEnabled }, set: {
                        var patch = DotistSettingsPatch(); patch.mcpEnabled = $0; model.updateSettings(patch)
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(DotistDesign.accent)
                        .accessibilityIdentifier("settings-mcp-enabled")
                }.settingsSearchAnchor("mcp.启用本地 MCP")
                HStack(spacing: 7) {
                    Text(model.text(service.running ? "运行中" : service.starting ? "启动中…" : "已停止"))
                    Spacer()
                    if service.running {
                        Text(model.text("已连接 {n} 个客户端").replacingOccurrences(of: "{n}", with: "\(service.connections)"))
                    }
                }.font(DotistDesign.font(12, language: model.language)).foregroundStyle(DotistDesign.muted)
                    .padding(.horizontal, 14).frame(minHeight: 44)
                if let error = service.error {
                    Text(error).foregroundStyle(DotistDesign.danger).font(DotistDesign.font(12, language: model.language)).padding(14)
                }
            }
            SettingsGroup(model.text("客户端"), footer: model.text("支持批量添加、搜索、日期与状态调整、分组管理和删除恢复。"), language: model.language) {
                SettingsFormRow(title: model.text("客户端"), language: model.language, emphasized: emphasized == "mcp.客户端") {
                    SettingsSegmentedPicker(selection: $client,
                        options: [("codex", "Codex"), ("claude", "Claude Code"), ("json", model.text("其他客户端"))],
                        label: model.text("客户端"), language: model.language).frame(width: 280, height: 24)
                        .accessibilityIdentifier("settings-mcp-client")
                }.settingsSearchAnchor("mcp.客户端")
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.text(client == "json" ? "将配置加入客户端的 MCP 设置。" : "复制命令，在终端执行后重新连接客户端。"))
                        .font(DotistDesign.font(12, language: model.language)).foregroundStyle(DotistDesign.muted)
                    Text(configuration).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-mcp-configuration")
                }.padding(14)
                SettingsFormRow(title: model.text("复制"), language: model.language, emphasized: emphasized == "mcp.复制") {
                    Button(model.text(copied ? "已复制" : "复制")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configuration, forType: .string)
                        copied = true
                    }.buttonStyle(DefaultButtonStyle())
                        .accessibilityIdentifier("settings-mcp-copy")
                        .accessibilityLabel(Text(model.text(client == "json" ? "复制客户端配置" : client == "codex" ? "复制 Codex 添加命令" : "复制 Claude Code 添加命令")))
                }.settingsSearchAnchor("mcp.复制")
            }
        }.font(DotistDesign.font(13, language: model.language))
            .onChange(of: client) { _, _ in copied = false }
    }
}
