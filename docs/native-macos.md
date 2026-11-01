# macOS 原生应用

Dotist 的界面、任务服务与 MCP 使用 Swift。SwiftUI 实现任务、日历、看板、甘特、设置、搜索和快速添加；AppKit 管理悬浮窗口、菜单栏、焦点与快捷键。GRDB 管理 SQLite 事务与变更观察。当前应用不再链接 Rust/C ABI、Tauri 或网页运行时。

数据库为 ~/Library/Application Support/com.dotist.app/tasks.sqlite，偏好设置为同目录的 settings.json。原生基线直接读取当前 schema v5，不重建任务 ID，不重写已有记录，不提供更早版本的升级链。删除按批次恢复；日期和状态在同一任务服务验证。Android 与 CloudKit 同步没有实现。

主面板第一行是标题与主要操作，第二行放日期筛选和日历入口。矢量图标使用统一网格与描边。横条只显示下一件任务，圆球显示数量。搜索可点击左上角 Dotist 图标或按应用内 ⌘K 打开；顶部有独立拖动区域，重新打开保留位置。搜索窗与自绘面板使用一致的连续圆角，搜索框采用系统同心圆角。设置继续使用 ⌘,、菜单栏或全局快捷键。

分组以文件夹索引标签切换，每组可打开独立浮动面板并收成独立气泡；任务数据共享，分组、日期、标签、展开/折叠和草稿按面板保留。主窗与分组面板使用同一套动效：面板与气泡变形、文字渐变、悬停横条、失焦淡出及减少动态效果均一致，气泡会向屏内展开。打开任务视图时同步主面板的窗口层级并置前，避免置顶主面板挡住日历、看板或甘特。未分类任务使用内部 inbox 作为隐式无分组桶，不作为分组展示；拖动可归类，删除分组时任务迁移到无分组。

最低系统基线为 macOS 26。窗口材质与控件统一使用公开 Liquid Glass API，保留系统无障碍偏好，不再包含较早系统的材质与交互分支。当前构建与实机验收面向 Apple Silicon，Intel 没有发布包；系统兼容声明不等于逐版本实测。

## 构建与验收

需要 macOS 26 或更高版本的 Apple Silicon Mac、支持 macOS 26 或更新 SDK 的 Xcode、Swift、Python 3。首次构建需联网获取锁定的 GRDB、官方 Swift MCP SDK、Sparkle 和字体；无需 Node 或 Rust。

~~~sh
bash native/scripts/test-native.sh
bash native/scripts/build-qa.sh
bash native/scripts/build-local.sh
~~~

QA 包启动和 --mcp 都必须显式提供其专属 DOTIST_DATA_DIR，缺失或不匹配时拒绝运行。验收不使用真实任务数据。UI 验收需要解锁的桌面与 macOS UI Automation 权限。

~~~sh
bash native/scripts/test-ui.sh /absolute/path/to/fresh-qa-directory
bash native/scripts/test-updater.sh /absolute/path/to/Dotist-Native-QA.app
~~~

候选包保存在 .cache/native-migration/，脚本不自动安装。安装前须正常退出正式应用并做 SQLite 一致性备份；回退应用时不要自动用旧数据库覆盖新增任务。

## 本地 MCP

设置中启用服务后，客户端以应用可执行文件的 --mcp 模式启动 stdio 代理。服务运行在应用内的本机 Unix socket，每个客户端有独立会话，共用同一任务服务与数据库观察。普通操作不抢焦点，focus_task 才明确聚焦。批量新增整体提交或回滚。

## 自动更新与发布

公开配置与版本集中在 native/app.json。更新仅使用原生 Sparkle appcast.xml 和原生归档，不再发布 Tauri latest.json、minisign 签名或 MCP sidecar。

CI 从 SPARKLE_SIGNING_PRIVATE_KEY 读取原生 Sparkle 密钥，通过 stdin 交给官方 sign_update，并用现有公开密钥独立回验。密钥必须匹配已发布的信任根；格式切换必须在获准发布前完成。不得通过更换公钥或跳过验签使发布通过。

main 推送触发原生测试、构建、完整草稿、下载回验及当前 SHA 检查，全部通过后发布。源码版本以 .0 结尾，Actions 运行编号作为补丁版本。应用包使用 ad hoc 签名，尚未 Developer ID 签名或公证。

完整的数据、窗口、性能与 MCP 约定见 [原生技术链路](native-consolidation.md)。


## v4.2 用户实机反馈更新（2026-11-01）

顶部改为工具栏和独立侧边便签，无可见 Inbox；删组迁移任务，父任务不折叠，悬浮球无进度环。五层任务、颜色主题、日期筛选、拖动、设置与字体对齐的完整锁定决定及对应测试见 [ui-decisions.md](ui-decisions.md)。本条取代本文中与其冲突的旧 UI 描述，历史验收结果仍仅代表当时版本。
