# Dotist React + Tauri 实施计划

**目标：** 在 Mac 上实现本地优先的悬浮分类待办与本地 MCP，为未来 Android/iCloud 同步保留数据结构。
**架构：** React/Vite 调 Tauri 命令；Tauri 与独立 stdio MCP 共享 Rust SQLite 服务。SQLite 任务与 outbox 在单一事务写入。CloudKit 实现、真实账号和远程服务不属于本期。
**约束：** 不触碰真实用户任务、不安装全局工具链、不配置客户端持久 MCP 权限；Arc 只参考/使用免费 MIT 项目。

1. 先写数据服务测试：增改完成、排序、删除墓碑、outbox 原子性、并发后共享可见；实现 SQLite 服务。
2. 先写 stdio MCP 协议和任务操作测试；实现共享业务服务的 MCP 入口并验证 stdout 只含协议消息。
3. 构建 React 界面，测试增改完成排序与中文 IME 的组合期间回车；Tauri 配置置顶、右上角、拖动与菜单栏。
4. 隔离临时数据库，执行自动化测试、生产构建、实际启动与截图。保留真实限制，未验证不得声称可用。
