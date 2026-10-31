# macOS 原生应用

Dotist 使用 SwiftUI 实现任务、日历、看板、甘特、设置和快速添加，AppKit 管理悬浮面板、菜单栏、窗口层级、焦点与全局快捷键。Rust 任务核心经 C ABI 连接 Swift；本地 MCP 与界面共用原来的 SQLite 和任务逻辑。

## 数据与界面

数据库仍为 `~/Library/Application Support/com.dotist.app/tasks.sqlite`，偏好设置仍在同目录的 `settings.json`。迁移保留任务 ID、分组、父子关系、状态、日期、手动顺序、删除恢复及同步预留记录；Android 与 CloudKit 同步尚未实现。

原生颜色、字体、尺寸与信息密度对应既有设计 token。Liquid Glass 用于浮动外壳及操作控件，任务内容保持清晰。控件选中态使用中性胶囊，不绘制彩色焦点边框；键盘操作仍可使用。点击收起后，鼠标停在圆球上不会自动展开详情，需要移出再进入。

主面板顶部和列表空白处、任务视图顶部与内容留白、设置顶部均可拖动窗口。日历保留日、周、月三种视图与拖动改期；看板按状态组织，甘特可手动排序或按分组展示。

最低构建目标保留 macOS 11。Liquid Glass 使用 macOS 26 及以上的公开 API，旧系统使用材质回退。当前发布和实机验收覆盖 Apple Silicon；Intel 尚无发布包，旧系统的运行情况未逐版本实测。

## 构建与验收

需要 Apple Silicon Mac、支持 macOS 26 SDK 的 Xcode、Rust、Node.js 22.18 或以上和 Python 3，Python 工具只使用标准库。首次构建需联网下载校验过的 Sparkle 与字体，字体及许可证随应用打包。

```sh
npm ci
export DOTIST_MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
export DOTIST_CARGO_OFFLINE=0
bash native/scripts/test-bridge.sh
bash native/scripts/build-local.sh
```

脚本将候选包放在 `.cache/native-migration/`，不会自动替换已安装应用。`build-local.sh --version X.Y.Z` 可以指定本地版本；正式发布版本由 Actions 递增生成。

`build-qa.sh` 生成专用 QA bundle 和隔离数据目录，启动时必须显式提供该目录的 DOTIST_DATA_DIR，缺失或不匹配时拒绝启动；QA MCP 同样检查数据目录。

```sh
bash native/scripts/build-qa.sh
bash native/scripts/test-ui.sh /absolute/path/to/qa-build-directory
bash native/scripts/test-updater.sh /absolute/path/to/Dotist-Native-QA.app
```

界面测试需要已解锁的桌面及 macOS UI Automation 权限；物理输入专项要求受保护的指针驱动，普通界面套件会明确跳过这些专项。更新测试从现有 TAURI_SIGNING_PRIVATE_KEY 和 TAURI_SIGNING_PRIVATE_KEY_PASSWORD 环境变量读取凭据，创建独立 QA 更新包和 localhost 服务，结束时停止自己启动的服务并保留结果。

## 自动更新与发布

原生更新使用 Sparkle，保留原有自动检查、自动安装、跳过版本和错误偏好。自动下载后在正常退出时安装，下次打开生效；关闭自动安装会取消暂存。检查周期为 24 小时，手动检查始终可用。

原生 appcast.xml 与旧客户端的 latest.json 都由 GitHub Releases 提供，指向同一份原生归档，分别附带 Sparkle Ed25519 和 Tauri minisign 签名。适配工具复用已有更新信任密钥；解密后核对公钥，通过 stdin 交给签名器，不把私钥写入发布包或日志。

main 推送触发测试和构建，生成完整 draft，再下载回验两种签名、版本、URL、长度和包内容；只有当前 main 仍指向触发 SHA 时才公开发布。源码版本以 `.0` 结尾，Actions 运行编号作为补丁版本。普通安装包采用 ad hoc 签名，尚未使用 Apple Developer ID 签名或公证。

安装或手动替换前应正常退出应用并备份应用包、数据库与设置。回退应用包时保留当前数据库，避免覆盖升级后新增的任务。
