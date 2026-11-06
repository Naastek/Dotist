# Dotist

<p align="right"><a href="README.md">English</a> · <strong>简体中文</strong></p>

**macOS 原生本地优先待办小窗。** Dotist 以轻量浮动面板常驻桌面，任务数据保存在本机 SQLite 数据库中，原生界面与可选的本地 MCP 接口共用同一套底层任务服务。

<p align="center">
  <img src="docs/images/dotist-main-en.png" width="360" alt="Dotist 浮动任务面板">
</p>

<p align="center"><sub>浮动任务面板将分组、日期和快速录入融为一体（虚构英文示例数据）。</sub></p>

## 为什么选择 Dotist

- **原生界面**：专为搭载 Apple 芯片且运行 macOS 26+ 的设备设计，基于 SwiftUI 与 AppKit 构建，提供 Liquid Glass 材质质感与全键盘操作。
- **浮动面板与轻量气泡**：常驻桌面边缘随时记录待办，也可一键收起为极简悬浮球，鼠标悬停即显示下一项任务。
- **层级化整理**：支持最多 5 层子任务嵌套、多选批量操作、拖拽排序以及左侧分组便签。
- **多维度视图**：列表、日历、看板与甘特图自由切换，排期一览无余。
- **本地优先存储**：数据与偏好设置保存在 Mac 本机，无需注册账号，无云端绑定。
- **可选本地 MCP 接口**：默认保持关闭，应用未预置任何 AI 模型。通过 stdio 代理直接让本地 AI 工具接入。

<p align="center">
  <img src="docs/images/dotist-calendar-en.png" width="900" alt="Dotist 任务视图">
</p>

<p align="center"><sub>任务视图提供日历、看板与甘特图多种排期展现（虚构英文示例数据）。</sub></p>

## 快速上手

- **添加任务**：在底部输入栏输入内容并按 `Return`；再次按 `Return` 可继续添加同级任务；按 `Tab` 缩进、`Shift-Tab` 提升层级，按 `Esc` 取消。
- **编辑与完成**：点击任意任务标题即可行内编辑；按空格键或 `⌘Return` 快速完成任务。
- **整理与多选**：拖拽任务或整棵子树即可调整顺序与层级；按住 `Shift` 或 `⌘` 点击进行多选；通过左侧便签切换分组；按 `⌘Z` 和 `Shift-⌘Z` 随时撤销与重做。
- **查找与聚焦**：按 `⌘K` 调出命令搜索面板；点击工具栏收起按钮将面板切换为悬浮球。
- **设置偏好**：按 `⌘,` 开启设置，配置外观、字体、材质与 MCP 参数。

## 安装与签名说明

1. 前往 [GitHub Releases](https://github.com/Naastek/Dotist/releases/latest) 下载最新版本。
2. 将 `Dotist.app` 移入 `/Applications`（应用程序目录）。
3. 启动 Dotist，面板将默认出现在屏幕右上角。

> **系统要求**：搭载 Apple 芯片（M 系列）且运行 macOS 26 或更高版本的 Mac。

### 安全与 Gatekeeper

- **Ad-hoc 签名**：当前打包脚本生成 Ad-hoc 签名包，不包含 Developer ID 签名或公证。
- **首次启动被拦截**：若首次打开时被 macOS Gatekeeper 阻止，请前往 **系统设置 > 隐私与安全性**，点击 **仍要打开**。
- **Sparkle 更新**：软件更新归档采用独立的 Sparkle 密钥进行签名，与 Apple 代码签名机制完全独立。自动检查更新默认开启，自动安装默认关闭。

> **提示**：GitHub 上的最新 Release 不一定与 `main` 分支的最新源码一致。本地候选包构建脚本不会自动发布为线上 Release。

## 数据、隐私与 MCP

### 本地存储与隐私

Dotist 无需注册任何账号，所有数据均保存在本地磁盘：
- **任务数据库**：`~/Library/Application Support/com.dotist.app/tasks.sqlite`
- **偏好配置**：`~/Library/Application Support/com.dotist.app/settings.json`

- **同步说明**：应用未实现 iCloud、CloudKit 或 Android 同步。

检查更新会连接 GitHub。

### 可选本地 MCP（Model Context Protocol）

Dotist 内置本地 MCP 接口，**默认保持关闭**，且**未捆绑任何 AI 模型**。在 **设置 > MCP** 中开启后，外部 MCP 客户端可以通过 stdio 代理直接运行本地可执行文件：

```bash
/Applications/Dotist.app/Contents/MacOS/dotist --mcp
```

- **聚焦与独立会话**：常规读写操作在后台静默执行，不会抢夺窗口焦点；仅在调用 `focus_task` 时才会激活并唤醒应用。各客户端拥有独立的 MCP 会话，并共享同一份本地 SQLite 数据库。
- **网络行为说明**：虽然 Dotist 本身完全在本地运行且无用户账号体系，但接入的 MCP 客户端在读写任务数据后，可能会将内容传输至其自身对接的模型服务提供商。因此开启 MCP 并不构成零网络连接承诺。

## 本地开发

Dotist 采用纯原生 Swift 技术栈（SwiftUI、AppKit、GRDB/SQLite 及官方 Swift MCP SDK），不依赖 Rust、Tauri 或 Web 运行时。

### 环境要求

- 搭载 Apple 芯片的 Mac（macOS 26+）
- 安装有 macOS 26 SDK 的 Xcode
- Swift
- Python 3

### 构建与测试

```bash
# 运行 Swift 核心、MCP 及窗口测试套件
bash native/scripts/test-native.sh

# 构建隔离的 QA 验收包
bash native/scripts/build-qa.sh

# 构建本地发布候选包（不会自动上传发布）
bash native/scripts/build-local.sh
```

## 相关文档

- [UI 决策](docs/ui-decisions.md)：交互设计与视觉约定说明。
- [macOS 原生应用](docs/native-macos.md)：数据模型、窗口管理、测试验收、签名与更新机制。
- [原生架构](docs/native-consolidation.md)：Swift 任务服务、MCP 协议契约与架构设计。
