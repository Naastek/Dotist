# 2026-10-31 原生交互与控件修整

> **历史记录，部分内容已被取代。** 当前原生架构见 [native-macos.md](native-macos.md)，当前 UI 决定以 [ui-decisions.md](ui-decisions.md) 为准；以下保留当时方案与验收证据。

这是 SwiftUI 迁移后的用户反馈修复，保留 Rust / SQLite / MCP 与任务语义。用户明确授权验证后直接更新本机应用；没有提交、推送或公开发布授权。

## 本轮确认的设计调整

本轮截图和明确反馈覆盖旧文档的圆点、下划线和旧分段控件规则：

- 分组名称前的装饰圆点全部移除；历史 `group_colors=dot` 与 `text` 均按彩色名称展示，`none` 保持普通文字。不自动迁移已有设置值。颜色管理仍可选择颜色，以小方块表达功能性选择。
- 分组菜单使用纯文字行、选中勾选和轻量悬停，不把每个选项画成灰色按钮条。
- 设置与视图切换共用玻璃胶囊，选中项为中性浅灰胶囊，沿用原字体和文字层次。原生 Toggle / Slider 保持 Dotist 强调色；Menu 使用显式玻璃背景，因为 ButtonStyle 不会自动改变 Menu 的外观。
- 顶部不再绘制冗余的大“任务视图”标题，保留系统交通灯位置。日／周／月、看板／甘特切换统一控件语言。
- 周视图改为七天纵列，任务直接显示在所属日期内；没有小时数据，因此不创造小时安排。未排期折叠为入口。日历任务标题单独占满行宽，完成与编辑放在下方操作行，避免窄窗仅剩一字宽。
- 原来常驻的“调整任务”横条改为省略号或日历任务标题入口；状态、日期、排序功能仍可操作。
- 系统蓝色焦点圈由细绿色焦点提示替换，保留键盘可达性。日历只聚焦日期头／数字，不把整列框住。胶囊方向键同步选中项与唯一焦点绑定，避免按 Space 切回旧选项。

## 首次收起的证据和修复

先前原生构建的首轮收起有 41.67 ms hitch。符号化采样确认首次插入 `BubbleWindow` 时发生字体级联、文本布局、Swift 泛型元数据创建。因此圆球内容改为稳定常驻，隐藏时关闭命中和无障碍暴露；圆球内容固定 48 pt 布局，不再跟随窗口每一帧宽度重新排版。

第一轮复测（`animation-native-v9cd4tdn`）首轮峰值 33.33 ms，旧的 `BubbleWindow` / `nativeFont` / CoreText 字体冷路径在切换窗口中为 0 个样本。新采样定位到 `.clear` → `.regular.interactive()` 的首次材质与交互元数据，以及无变化主任务内容的日期格式化工作。因此当前候选保持 `.clear.interactive()` 与同一组用户 opacity/frost 覆盖层贯穿三种形态，并用稳定内容包装隔离窗口状态变化；任务内容仍由 `MainWindow` 内部观察 `AppModel` 正常刷新。中间构建 `animation-native-giolu61p` 同条件四轮复测：首次收起区间最长 hitch 为 8.33 ms，四轮最大 16.67 ms。该统计来自 Animation Hitches 的目标进程事件，观测窗口包含 XCTest 等待，不是 FPS 或逐帧渲染时间；最终候选的独立录制结果见下文“最终动画测量”。

点击收起后不再根据“鼠标恰好仍位于新圆球内”自动展开横条；需要先移出再进入才显示详情。已有 8 项真实界面回归通过，包括这一动作、重复收放布局与主菜单焦点。后续补充了胶囊方向键、日期方向键及窄窗口拖放的验证。

## 本地验收与证据

候选为 `qa-build-szFd5CV7`（日志 `polish-build8.log`），本地正式包为 `native-local-6BXC7mFi/Dotist.app`、构建 `native-local-20261031T100029Z`。两者 Mach-O UUID 均为 `2DD7B439-B416-3A65-BA84-65722EB2B6F2`；源码摘要保存在 `.cache/native-migration/polish-source-manifest.json`，最低系统版本仍为 macOS 11。

| 验收层 | 已核实结果 | 证据（相对 `.cache/native-migration/`） |
| --- | --- | --- |
| Rust / Swift | Rust 桥接 3 项、Swift 核心与悬浮拖动 5 项通过 | `polish-bridge.log` |
| 核心 UI 回归 | 前一构建 8 项通过，包括收起后不自动悬停、完成、四次重复收放布局、主题与视图切换；日期专项随后单独修正并重跑 | `ui-tests-n4u052oc/results.xcresult` |
| 最终控件 UI | 日期方向键的选中／取消选中、胶囊方向键＋Space、异步主题持久化、日／周／月／看板／甘特切换，3 项通过 | `polish-final-controls-retry.xcresult` |
| 最终日历与窄窗 | 真实鼠标拖动改期、实际 Command-A／日期输入／Return 保存、原分组与起始日期保留、680pt 周视图、600pt 设置，完整流程通过 | `review-polish-flow-i8tv673d/results.xcresult` |
| 最终圆球与窗口 | 150 字长标题省略号、左侧圆心固定、点击后保持圆球／移出再进入、真实拖动不误展开、主窗口两条边缩放及收放后尺寸恢复，3 项通过 | `review-bubble-left-pvsium1e/`、`review-bubble-drag-26hdda72/`、`review-resize-pruee81o/` |
| 最终收放录制 | 四轮收放操作通过，Animation Hitches trace 完整归档 | `animation-native-bankoo3t/` |
| 正式包 MCP | 隔离数据完成 16 工具枚举、创建、完成、删除、恢复、同 ID 读回和 SQLite 完整性检查 | `polish-packaged-mcp.json` |
| 独立评审 | 焦点、常驻隐藏内容、长标题限宽、Equatable 刷新边界及并发贴边拖动改动无剩余可证实问题 | 本聊天独立叶子评审记录 |

日期专项早期失败的原因是 SwiftUI 容器未暴露 `Group.value`：诊断截图及 AX 层级已显示日期正确移动。现将选中 trait 放在实际日期按钮，最终测试明确验证新按钮选中、旧按钮取消选中。日期输入使用带前台／焦点归属检查的真实键盘事件，并检查 SQLite 中的最终值。早期锁屏、并发 QA 冲突和自动化辅助失败均不计为产品通过或性能数据；未删除、放松业务断言。

同工作区另一用户聊天的悬浮球贴边修改已保留在最终候选：圆球拖动不再进入系统 `performDrag`，并保留原有跨桌面／全屏辅助窗口能力。经用户授权协调后，对方退出了自己的 QA 并暂缓桌面操作，本轮未停止或覆盖其资源。

## 最终动画测量

同一台 Apple Silicon Mac、macOS 27、同一块 Retina 显示器与 2× 缩放，浅色中文、相同隔离样例、364×620pt 主面板与同一固定背景。悬停详情关闭，冷启动后连续收放四轮。使用 Instruments Animation Hitches，统计目标进程非系统 hitch 与“发出点击至控件确认”区间的交集。

| 指标 | 此前安装的原生版本 | 本次最终候选 |
| --- | ---: | ---: |
| 首次收起区间最长 hitch | 41.67 ms | 8.33 ms |
| 四轮收放中的最长 hitch | 41.67 ms | 16.67 ms |
| 四轮区间 hitch 合计 | 608.35 ms | 341.67 ms |
| 四轮区间事件数 | 53 | 35 |

最终首次收起区间为 trace 的 0.913615–2.611264s，4 个 hitch；最终全部四轮没有边界重复计数，区间外另有一次 16.67ms。中间稳定材质构建也观测到首次 8.33ms。可以确认此次复现没有再出现原来的 33／42ms 首次大停顿；这不是 FPS，也不是逐帧耗时或“零卡顿”保证，单次启动四轮不能代表所有场景。

原始 trace、XML、逐轮 JSON 及独立复算均保留：`animation-native-bankoo3t/`、`polish-animation-comparison.json`、`collapse-profile-final-review.md`。

## 视觉对照与边界

截图入口：[本轮验收页](../.cache/native-migration/polish-acceptance/index.html)。主面板使用相同示例数据、尺寸、主题、显示缩放和背景对照旧网页基线；分组色点、下划线与分段控件的差异来自本轮明确的设计调整。周视图、窄窗口、日期编辑、设置浅深主题、菜单和键盘焦点单独留图；`screens.json` 记录测试来源，不以编译或截图替代交互及性能验证。

- 周视图借鉴 Apple Calendar 的日期列层次，Dotist 只有日期语义，未虚构小时安排。
- 普通任务内容保持原有可读性，Liquid Glass 用于浮动外壳和控件。减少动态效果／透明度与高对比度回退继续保留。
- 本轮实机覆盖 macOS 27 Apple Silicon；macOS 11–25 与 Intel 没有实机复测，兼容声明不等于已逐系统验收。
- 本地包为 ad hoc 签名，原生生产更新源仍未配置；这次不包含 Git 提交、推送或公开发布。

## 安装与资源

已于 **2026-10-31 18:19:25（Asia/Shanghai）** 更新 `/Users/junyu/Applications/Dotist.app` 并重新启动。版本仍为 `0.1.2`，本地构建标识为 `native-local-20261031T100029Z`。正式进程 PID 65564 可见，打开的数据库仍是 `~/Library/Application Support/com.dotist.app/tasks.sqlite`；安装包签名验证与 Mach-O UUID 一致性核对通过。

更新前正常退出旧应用，备份目录为：

`.cache/native-migration/installed-backup-20261031-181925/`

其中保留旧 `Dotist.app`、SQLite 一致性备份、`settings.json`、偏好设置及 manifest。更新后只读比较原数据库的全部 3 张业务表与备份，记录摘要一致；数据库完整性 `ok`，设置 JSON 也完全一致。没有在真实任务上做新增／完成／改期测试。安装与只读核验记录分别为 `installation.json`、`polish-installed-verification.json`，此前安装记录亦留存。

可以直接使用当前打开的 Dotist，或从 `~/Applications/Dotist.app` 再次启动。恢复旧应用时先正常退出新应用，再用上述备份的应用包替换；不要自动回滚数据库，否则可能覆盖更新后的用户编辑。

本任务的 QA 应用、XCTest runner、录制进程、临时背景和临时防休眠进程已结束，正式应用保持运行。隔离数据、测试结果、trace、候选包与两轮安装备份均保留供复查；未提交、推送或公开发布。
