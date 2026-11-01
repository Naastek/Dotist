# 原生自动更新、按钮与拖窗验收（2026-10-31）

本轮按用户授权完成原生更新接入、按钮尺寸与点按支持、顶部及面板空白拖动，并在验收后更新本机应用。提交、推送和公开发布仍需单独授权。

## 更新架构与兼容

保留原有 `auto_check_updates`、`auto_install_updates`、`skipped_update_version`、`last_update_error` 及 Rust 设置依赖规则，继续从原来的 settings.json 读写。自动检查周期为 24 小时；自动下载后正常退出时安装，下次打开生效。关闭自动安装会取消暂存；手动检查、立即更新、跳过版本及错误反馈保留。

原生 UI 使用已有 Sparkle 2.9.6 自定义驱动。`build-local.sh` 会剔除 QA localhost 配置，再嵌入生产 appcast、原有 updater 密钥对应的原始 Ed25519 公钥及解压前验签要求。

- 原生 feed：`https://github.com/Naastek/Dotist/releases/latest/download/appcast.xml`。
- 旧 Tauri feed：原有 `latest.json` 不变。两个 feed 指向同一份原生 `.app.tar.gz`，分别提供 Sparkle Ed25519 与 Tauri minisign 签名。
- `native/release-tools` 使用固定版本的官方 minisign 库解密原有更新密钥，核对公钥后通过 stdin 把 seed 交给官方 Sparkle sign_update。不会生成新信任根、输出私钥、把解密后的密钥写入文件或作为命令行参数。
- GitHub Actions 保留 main 推送触发、递增版本、完整 draft、下载回验和当前 SHA 检查后发布的流程。原生 Rust / Swift 构建取代 Tauri UI 构建，附带 MCP、字体、资源和 Sparkle。
- 两种归档签名、版本、URL、长度、主 bundle ID、原生标记、包内更新配置和必要资源均由 `verify-update.py` 检查。真实产物通过独立复核；翻转 Sparkle 签名一字节后验证明确失败。

2026-10-31 本轮只读核对的公开版本仍是 v0.1.2，仅有旧 Tauri 归档、签名和 latest.json。**公开 appcast 还未发布，生产在线更新不能计为已验收。** 本机版本已配置未来公开地址；需要另行授权提交／推送并发布原生版本后，再核对在线资产及客户端检查。当前没有对远端作写入。

## 交互调整

导航箭头原来把 32×32 图标框又叠加了通用按钮 24pt 横向／10pt 纵向内边距，造成宽高和“今天”按钮不一致。现在普通操作按钮统一 32pt 高，图标按钮为 32×32pt；日／周／月与视图切换保留 36pt 外胶囊及中性选中项。切换按钮标签的胶囊区域明确参与命中，托管视图显式接受激活窗口的首次点击。

实测旧版本的按钮边缘与未激活窗口中央点击可以成功；未稳定复现所有用户描述的偶发点按问题，因此不把尺寸修复等同于证明所有历史点按原因。最终候选继续验证一次点按、边缘点按、方向键与 Space、主题异步保存。保留细绿色键盘焦点，没有恢复蓝色焦点框。

主窗口顶部、列表空白处和任务视图顶部使用 SwiftUI WindowDragGesture；任务行、输入框、菜单、日期选择和按钮保留各自事件。macOS 11–14 提供使用屏幕指针位置的拖动回退，没有缩小最低系统版本；本轮实机仅覆盖 macOS 27 Apple Silicon，旧系统回退未实机验证。

XCTest 的 press/thenDrag 在本机没有产生窗口位移，后续使用带前台、QA 路径、窗口范围与 AX 命中归属检查的真实 CGEvent。主面板顶部／空白、任务视图顶部／内容留白、设置顶部共五处拖动均测得窗口位移，拖后切换按钮仍生效。最终复测先将 QA 固定在屏幕中央，避免多轮测试保存的位置靠近屏幕边缘而触发系统工作区限制。自动化输入辅助失败不算产品通过。

## 跳过暂存更新的回归

真实流程复现：自动下载完成后点击“跳过此版本”，偏好已保存，但仍显示“更新已下载”。修复前带日志的 QA 证明：恢复安装直接进入 `showUpdateFound(stage=installing,user=true)`，省略 `showUserInitiatedUpdateCheck`，所以 state 仍是 downloaded；dismiss 时 `busy=false` 无法清理。

现在无 decision 的 skip 先进入 checking，直到 Sparkle 结束回调清理状态；实际提交 skip 时清除暂存标记。测试覆盖跳过后提示消失、版本偏好持久化、手动检查仍能找到该版本。此逻辑与“关闭自动安装”的取消流程分开，保留用户主动跳过的语义。

## 验收资源

本轮工作目录：`.cache/native-migration/update-controls/`。

- `bridge.log`：Rust 桥接 3 项、Swift 核心与悬浮指针 5 项通过。
- `../ui-tests-0tdIelwN/results.xcresult`：常规 UI 12 项通过，8 项因要求专用签名或物理输入 fixture 明确跳过；专用测试另行执行。
- `drag-physical/`：三个区域的真实鼠标拖动及拖后按钮操作通过。
- `first-physical-red-valid/`：旧版本未激活窗口中央点击正向样例；这不是失败复现。
- `baseline-retry.xcresult`：旧导航按钮尺寸回归失败；普通分段点击通过。
- `trace-fixture/update-skip/`：修复前的真实跳过失败及 update-events.log。

可复用更新验收命令：

```sh
native/scripts/test-updater.sh /absolute/path/to/Dotist-Native-QA.app /path/to/existing/updater-key-directory
```

也可通过现有 TAURI_SIGNING_PRIVATE_KEY / PASSWORD 环境变量提供凭据，不传目录。脚本只创建隔离 QA、专用样例与 localhost 服务，结束时停止自己启动的服务，结果保留。

## 最终结果

- 可复用更新脚本完整通过：`.cache/native-migration/update-tests-m9Uu6Nx0/` 六项各 1 通过、0 失败，使用生产同格式 tar.gz 和相同签名信任根。其专用 server 由 trap 正常结束。
- 最终物理输入：`first-physical-final/` 首次点击通过；`drag-all-panels/` 五处拖动及按钮操作通过。中间屏幕边缘位置下的位移失败保留为诊断证据，不算通过。
- 按钮截图：`screens/manifest.json` 对应 `compact-calendar-controls`，原导航箭头尺寸失败与修复后 32×32pt 断言成对保留。截图左侧有同一 QA 的主面板覆盖，按钮区域未遮挡；不以此声称整张日历无覆盖验收。
- 独立评审复核了真实两种签名、篡改拒绝、跳过回调及六项更新日志，没有剩余代码或本地验收阻断。
- 最终 QA 与安装包 UUID：`25258AA4-BAD2-37E1-9AFF-4CE2A2C5B06B`；原生源码摘要见 `final-source-manifest.json`。

已于 **2026-10-31T19:00:15.148171+08:00** 更新并重启 `/Users/junyu/Applications/Dotist.app`，版本 `0.1.2`，本地构建 `native-local-20261031T105607Z`。进程 PID 74344、可见主窗口 449×608pt 已核实，实际数据库句柄仍指向原路径；签名严格验证通过。

备份目录：`/Users/junyu/DevProjects/Dotist/.cache/native-migration/installed-backup-20261031-190014`。正常退出后保留旧应用、SQLite 一致性备份、settings.json 和偏好设置。更新后只读比较 tasks、task_groups、sync_outbox 三表全部一致，SQLite 完整性 ok，原有 settings.json 完全一致。没有用真实任务作操作测试，也没有把 sync_outbox 预留记录称为已实现同步。

安装与核验记录：`update-controls/installation.json`、`update-controls/installed-verification.json`。本轮 QA / XCTest 和两个额外 localhost 服务器均已结束，端口已释放；正式应用保持运行。隔离数据、trace、结果、签名产物和回退备份保留。未提交、推送或公开发布。

公开 appcast 的发布和上线验收仍待用户单独授权。本轮没有缩小 macOS 11 最低兼容范围；旧系统和 Intel 未实机复测。


## 后续公开发布与无框焦点

用户后续明确授权提交、推送并发布，前文“未提交／未发布”描述的是 19:00 本机验收阶段。现已发布 v0.1.3，提交 `7b634ae42fac11b06c58ec08263a2aaad48538d1`，CI 成功；当前应用通过公开原生更新链路安装完成并显示已是最新版本。

最新设计反馈要求移除绿色焦点框，现共享控件、日期及快捷键录制均不再画彩色焦点边框，保留选中胶囊和轻微底色提示；专项键盘和视图操作通过。

本机路径与详细调试报告未发布到 GitHub。公开说明为 docs/native-macos.md；完整本机收据位于 `.cache/native-migration/release-live/README.md`，最终备份 `/Users/junyu/DevProjects/Dotist/.cache/native-migration/installed-backup-20261031-195313`。
