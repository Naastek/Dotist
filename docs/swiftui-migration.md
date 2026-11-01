# macOS 原生迁移：实现、设计基线与验收

> **历史记录，部分内容已被取代。** 当前原生架构见 [native-macos.md](native-macos.md)，当前 UI 决定以 [ui-decisions.md](ui-decisions.md) 为准；以下保留当时方案与验收证据。

本文件记录 SwiftUI/AppKit 架构、设计映射，以及 **2026-10-31 16:41 安装的迁移基线**。前半部分已同步后续确认的实现调整；后半部分的构建、测试、性能、进程和备份仍保留该基线的历史证据。后续交互修整、最新验收及安装状态见 [原生交互与控件修整](native-polish-2026-10-31.md)。现有 React/Tauri 工作区继续保留，所有任务操作、数据库和 MCP 验收使用隔离数据。“已实现”不等同于对应路径已通过最终界面或性能验收。

## 设计基线与已确认的后续调整

迁移沿用 `design-system/`、`src/tokens.css`、`src/dotist.css`、`src/app.css`、`src/views.css` 及当前组件的布局、字体、颜色和交互语义。存在差异时，以当前实际界面及用户已确认的设计决定为准，不直接套用旧版本文档。

| 当前来源 | 原生对应 | 基线 |
| --- | --- | --- |
| `src/tokens.css`、`src/app.css` 中 v3.1 后的覆盖 | `DotistDesign` 动态颜色 | 浅色 `ink #1c1c1f`、`accent #3f6a56`、`paper #f5f5f6`；深色 `ink #eeeef0`、`accent #8dbaa2`、`paper #1c1c1e`；六种分组色使用实际覆盖值 |
| `.dt-window`、`.dt-head`、`.dt-scroll`、`.dt-composer` | AppKit 悬浮窗口及 SwiftUI 内部分区 | 默认 364×620 pt、最小 320×440 pt、头部 44 pt；窗口大小沿用既有设置 |
| `--row`、`--column`、`--indent`、`--sub-row` | 任务行及子任务 | 主行 32 pt、勾选对齐列 18 pt、子任务缩进 26 pt、子行 28 pt |
| `--font-serif`、`--font-sans`、语言覆盖 | 进程内注册字体及级联字体 | Source Serif 4 / Source Sans 3 与对应语言的 Noto SC、TC、JP；不安装或修改用户系统字体 |
| `.dt-svg`、`.dt-check` | 矢量图标与勾选控件 | 常规图标 16 pt、1.5 pt 描边、24 pt 点击区；勾选圈 18 pt；具体 SF Symbols 字形不等同于原网页图标轮廓 |
| `.dt-bubble` | 同一悬浮窗口内的悬浮球与详情横条 | 悬浮球 48 pt，保留进度环、剩余数量、拖动、屏幕边缘约束和悬停详情；分组前的装饰色点另按下方新规则移除 |
| `.dv-window`、`.dv-day`、`.dv-card`、`.dv-gantt-*` | 独立日历、看板和甘特窗口 | 默认 1000×720 pt、最小 680×480 pt；保留日／周／月、状态列、手动与按分组甘特 |
| 设置窗口 | SwiftUI 设置内容与 AppKit 窗口 | 默认 740×560 pt、最小 600×420 pt；保留既有设置分区 |
| 主题、透明度、磨砂和无障碍设置 | `FloatingMaterial` / `WindowMaterial` | 玻璃用于原有窗口与浮层，任务行和任务卡不逐个叠加玻璃 |

既有设计例外继续保留：图钉选中态填充且不旋转；设置导航、菜单和编辑任务不使用选中竖线；日历范围端点为实心圆；编辑其他任务时其余行降低透明度。区域之间原有的分隔线不等同于选中态竖线。

2026-10-31 用户先后确认去除顶部下划线、提高系统玻璃透明感、改善悬浮球／横条／面板切换，随后提供截图要求统一控件、移除分组装饰圆点并调整周视图。以下按最新明确反馈记录，覆盖旧文档对应的样式规定：

- 主窗口“今天／全部”等顶部标签用文字颜色与字重区分选中状态，提供无障碍选中标记，不再绘制选中下划线。
- 任务视图、日历、甘特尺度及分组模式、设置中的主题等切换共用 `DotistGlassTabs`：玻璃胶囊外壳与中性浅灰选中胶囊，保留键盘方向键和选中语义。macOS 11 回退到原生分段 `Picker`。`DotistControlTint` 继续让原生 Toggle／Slider 使用 Dotist 浅／深色绿色；操作按钮共用玻璃样式。macOS 14 及以上以细绿色焦点反馈替代系统蓝色焦点圈，日历仅聚焦日期头／数字，不把整列框住。
- 主面板、悬浮球和横条共用连续的玻璃背景；三种形态保持同一种 `.clear.interactive()` 材质及同一组用户 opacity／frost 覆盖层，避免首次收起切换材质和交互结构。
- 分组名前的装饰圆点移除；历史 `group_colors=dot` 与 `text` 都按彩色名称展示，`none` 保持普通文字，不自动改写已有设置值。功能性的颜色选择仍保留；48 pt 悬浮球与完成勾选控件不属于该装饰圆点规则。
- 移除顶部冗余的大“任务视图”标题；日／周视图按日期纵列直接展示任务，未排期折叠为入口。任务标题或省略号打开状态、日期、排序弹窗，替代常驻的“调整任务”横条；仅有日期的数据不虚构小时安排。
- 用户已单独授权在完成本地验收并备份后替换本机现有应用。该授权不包含提交、推送或公开发布。16:41 迁移基线的安装见本文末尾；后续安装状态见 [修整记录](native-polish-2026-10-31.md)，不以打包成功代替安装完成。

## 架构与数据语义

SwiftUI 实现任务列表、任务和分组编辑、日历、看板、甘特、设置与快速添加。AppKit 集中处理 `NSPanel` / `NSWindow`、窗口层级、尺寸和位置、菜单栏、焦点、鼠标窗口拖动；全局快捷键通过现有原生快捷键封装处理。普通内容没有重新全部改写为 AppKit 控件，也没有嵌入 WebView。

Swift 与 Rust 使用静态链接库加薄 C ABI：

```text
SwiftUI → AppModel → RustTaskStore → dotist_native_open/call/close
                                           ↓
                                  dotist-core::Store → SQLite
                                           ↑
                                dotist-mcp（独立 stdio 进程）
```

`crates/dotist-native` 对外提供不透明 store handle 和 JSON 请求／结果；Swift 使用 Codable 模型解码，返回的 C 字符串通过 `dotist_native_string_free` 释放。选择这条连接方式，是为了保留现有 Rust 业务规则与 SQLite 事务，又避免把 Rust 类型布局、WebView IPC 或额外后台服务引入原生界面。界面数据库调用由 `AppModel` 的串行队列执行，结果回到主线程；Rust store 使用互斥访问。刷新仅在数据变化时更新相应观察状态，拖动期间暂停周期刷新。

正常运行仍使用 `~/Library/Application Support/com.dotist.app/tasks.sqlite` 及其 WAL；没有新建另一套主数据库。MCP 与界面分别连接这同一数据库并调用同一个 `dotist-core`。偏好继续由共享 Rust settings 实现读写同目录 `settings.json`；窗口尺寸使用既有字段，原生窗口位置记在应用的 `UserDefaults` 中。

任务 ID、分组 ID、状态与完成标记、开始／截止日期、排序值、父子关系、删除墓碑、恢复和 revision/outbox 由 Rust 核心维护。跨分组视图的拖动和键盘排序调用核心 reorder，不修改任务所属分组。日期缺失仍用空值表达，不填入伪日期；甘特日期调整提交到核心后保留对应任务身份。outbox 只是同步预留记录，Android、iCloud/CloudKit 和其他跨设备同步没有因此实现。

## 功能实现范围

下表记录当前代码覆盖范围。16:41 基线的通过结果与本文后半部分证据对应，后续修改的验证结果以 [修整记录](native-polish-2026-10-31.md) 为准。

| 功能 | 当前原生实现 |
| --- | --- |
| 任务、子任务、分组 | 新增、编辑、完成／状态变化、删除与恢复；分组颜色、标签筛选及管理；继续由共享核心执行变更 |
| 排序 | 任务拖放、上下移动操作与键盘移动；“今天”等跨分组列表可自由排序且不改分组；子任务保留父子上下文 |
| 悬浮窗口 | 面板／悬浮球切换、悬停详情、球体和横条拖动、屏幕边缘约束、置顶、固定、自动收起与闲置淡出；点击收起后须先移出再进入，才展开横条；窗口尺寸及位置记忆 |
| 菜单与快速添加 | 菜单栏内容与动作、日期及分组快捷选择、独立快速添加窗口、前台设置菜单、可配置全局快捷键 |
| 日历 | 日／周／月视图、导航及日期选择、键盘日期操作、拖动任务改期；日／周按日期纵列展示任务，未排期入口可折叠；标题或省略号打开任务调整；浏览月份与选中日期分别保存 |
| 看板 | 按任务状态分列，拖动变更状态与同列排序 |
| 甘特 | 手动排序、按分组展示、分组展开／收起、任务条移动和端点日期调整；拖动时 Escape 取消，不提交预览日期 |
| 设置与辅助能力 | 语言、浅色／深色／跟随系统、外观、菜单栏、快捷键录入、MCP 路径与配置复制、数据位置；Button、Picker、Toggle、Slider 等原生控件及焦点／无障碍标签 |
| 开机启动 | 通过 Rust 连接复用 `auto-launch` 的系统登录项支持，正式应用使用原有 `Dotist` 名称及可执行路径；QA 使用单独名称 |
| MCP | 保留独立 stdio server；正式包路径仍为 `Dotist.app/Contents/MacOS/dotist-mcp`，由客户端自行配置连接 |
| 更新 | Sparkle 2.9.6 原生实现，支持手动检查／安装、自动检查／下载、正常退出时安装与取消已暂存的自动更新；生产 feed 与签名发布流水线已接入；公开发布仍待授权，见 docs/native-updates-2026-10-31.md |

## 材质、动效与兼容

`RootWindow` 的 `FloatingSurface` 保持同一个背景视图，随圆点、详情横条和主面板改变形状及尺寸，不在每个状态重新叠加一层独立玻璃。这里只有一个连续玻璃表面，因此没有为了模拟融合而创建多个 `GlassEffectContainer` 或额外阴影窗口。

macOS 26 及以上使用公开 SwiftUI `glassEffect`。当前三种悬浮形态均保持 `.clear.interactive()` 与同一组 opacity／frost 覆盖层，轮廓使用连续圆角；不再在首次收起时从 `.clear` 切换到 `.regular.interactive()`。系统提供玻璃折射与交互反馈，用户既有透明度／磨砂设置继续参与背景表现。独立窗口的内容背景仍使用 `NSVisualEffectView` 与设计色调，其导航和操作控件使用共享玻璃外观，任务卡片不逐个玻璃化。

系统“减少透明度”使用实色背景；增强对比度时提高背景与文字对比。系统“减少动态效果”关闭相关过渡。低于 macOS 26 的窗口使用公开 `NSVisualEffectView` 回退，低于 macOS 14 的悬停收放使用有限时长缓动，不调用较新动画完成 API。

迁移基线的布局抖动修复针对两个已定位的问题：

1. 窗口收放时，内容曾随中间窗口尺寸重复排版，导致文字与控件移动。现在面板内容在过渡期间固定为起始／目标布局尺寸；仅窗口边界和同一个背景连续变化，内容独立淡入淡出。展开目标尺寸先按屏幕可见区域计算，结束时不再切换到另一套布局尺寸。`animationInProgress` 可观察，动画结束后恢复正常实时布局。手动拖动窗口尺寸不附加全局 SwiftUI 弹簧。后续修整又让 `BubbleWindow` 稳定常驻并固定球体内容为 48 pt 布局，隐藏时关闭命中与无障碍暴露；通过 `MainWindowContent.equatable()` 隔离窗口状态变化，内部任务内容仍观察 `AppModel` 正常刷新。首次收起的后续采样结论见 [修整记录](native-polish-2026-10-31.md)。
2. 悬停展开窗口的动画会改变鼠标按下位置对应的坐标，立即拖动时出现额外横向位移。现在窗口坐标范围先到位，只让背景宽度变化；鼠标命中区域和圆点内容不参加该弹簧。收起详情等待背景动画结束及鼠标释放，再缩小窗口。悬停动画期间的面板展开请求按顺序执行。

中线附近反复进出详情时，仅在完整收成 48 pt 圆点后重新决定向左或向右展开，避免中途翻转锚点。六种悬停停留时间的实际坐标测试均为 dx=0、dy=0。

字体匹配曾在每次布局时重新访问 CoreText 字体注册表。现在按字号、字重、衬线类型和语言区域缓存不可变 `NSFont`，保持原有级联描述符；最终包的独立 CoreText probe 确认简体中文 regular 实际为 Noto Sans SC 的 wght=400，medium=500、semibold=600。

当前圆点／横条背景使用 response 0.34、dampingFraction 0.9 的 SwiftUI 弹簧；面板收放使用一次 AppKit 系统窗口动画和 `(0.22, 1, 0.36, 1)` 缓出曲线，分别为 0.28／0.34 秒。弹性放在玻璃表面上，窗口本身不做越过目标尺寸后的反弹。`NSHostingView` 放入普通 AppKit 容器，并在支持的系统关闭其自动尺寸建议，避免内容的固有尺寸覆盖独立窗口最小尺寸。

这些实现说明不能代替最终动态验收。公开系统材质不提供与 CSS blur/frost 像素值逐一对应的参数，系统玻璃的折射、背景采样及分段控件外观也不会与网页逐像素相同；应以同条件截图和实际交互评估差异。没有视觉对照时，不声称通过视觉验收。

当前构建目标为 arm64、macOS 11.0。已安装 Tauri 包的 `LSMinimumSystemVersion` 是 10.13，但 arm64 Mach-O 最低版本实际为 11.0；新包没有据此提高到 macOS 27。macOS 11 实机和 Intel 尚未验证，不能以 availability 分支或 Info 声明替代运行证据，也不能据此声称提供 Intel 发布包。

## 原生更新与本地打包

`NativeUpdater` 已实现 Sparkle 自定义用户界面与更新状态处理，复用原有更新偏好。自动下载完成后在正常退出时安装；关闭自动安装时取消暂存安装，取消失败会反馈错误并暂缓退出。QA 仅在专用 bundle ID、显式测试标记与 localhost URL 同时满足时允许本地 HTTP feed，其余更新源要求 HTTPS 和有效格式的 Ed25519 公钥。

签名本地更新流已有隔离测试证据：

- `.cache/native-migration/xcui/auto-off-regression.xcresult`：1 个测试、0 失败、0 跳过。下载暂存更新后关闭自动安装，正常退出，QA 包版本保持不变。
- `.cache/native-migration/xcui/auto-on-regression.xcresult`：1 个测试、0 失败、0 跳过。自动更新下载完成后正常退出，隔离 QA 包替换到签名测试版本。

以上只证明本地签名更新流程，不代表原生生产更新已发布。现有公开清单仍面向 Tauri，不能给 SwiftUI 包直接使用。2026-10-31 后续已接入生产 `SUFeedURL`、原有密钥对应的 Ed25519 公钥、原生签名产物和发布流水线；手动／自动更新使用隔离 QA 实测。当前公开发布仍只有旧 Tauri 资产，原生 appcast 必须在获准发布后才会在线提供。见 [原生更新验收](native-updates-2026-10-31.md)。

构建与验证入口：

```bash
bash native/scripts/test-bridge.sh
bash native/scripts/build-qa.sh
native/scripts/build-local.sh --qa-app "/path/to/Dotist-Native-QA.app" --version 0.1.2
```

`build-qa.sh` 默认 release，支持 `DOTIST_NATIVE_PROFILE=debug`。QA 主程序和 MCP 包装器只接受包旁专属 `data` 目录，缺少正确 `DOTIST_DATA_DIR` 时拒绝启动；不要把 `dotist-mcp-real` 单独指向真实数据测试。字体由固定版本下载并验证哈希，许可与运行库一起打包。

`build-local.sh` 从明确的 QA 包生成独立的 `Dotist.app`，使用正式 bundle ID 和 MCP 路径，清除 QA 更新配置，重新 ad hoc 签名并进行深度严格校验。版本由参数指定，另以 `DotistBuildLabel` 标识本地构建；脚本不安装、不启动应用、不修改任务。普通候选正常启动会访问既有数据目录，所以候选运行验收仍须明确指定隔离 `DOTIST_DATA_DIR`。正式替换前保留旧应用和需要的数据备份，不覆盖或删除无关文件。

## 已核实的自动化证据

`.cache/native-migration/bridge-final-glass.log` 记录 2026-10-31 的以下结果：

| 层级 | 实际检查 | 结果与范围 |
| --- | --- | --- |
| Rust C ABI／MCP | `bridge_rejects_malformed_requests_without_modifying_tasks`、`update_preferences_keep_the_existing_dependency_and_persist`、`real_bridge_and_mcp_share_task_identity_status_dates_and_outbox` | 3 通过、0 失败；真实 Rust 核心、隔离 SQLite 与实际 MCP 进程 |
| Swift ↔ Rust | `testSwiftCallsTheRealRustStoreAndRetainsTaskSemantics`、`testTagsUseTheSharedTaskStoreAndKeepFamilyContext` | 2 通过、0 失败；Swift 调用真实 Rust store，覆盖任务语义和标签家庭上下文 |
| 原生代码构建 | 同次 `swift test` 构建 DotistApp | 构建成功；不代表窗口或动画验收 |
| Sparkle 本地更新 | 上述 auto-off／auto-on 两份 xcresult | 各 1 通过；仅隔离签名更新，未发布生产 feed |

该日志中的 `set_update_error` 未使用警告与 SwiftPM 原生构建参数弃用警告仍存在，测试未把它们报告为失败。本节不把缺少报告的流程计入通过数量，也不将旧构建的结果当作最终候选的完整回归。

## 16:41 迁移基线的本地验收（2026-10-31）

以下构建标识、测试结果和截图仅对应当次迁移基线；后续修整的结果另见 [最新验收记录](native-polish-2026-10-31.md)，不将旧通过记录算作新候选的回归。

最终 QA：`.cache/native-migration/qa-build-RZQPWlJH/Dotist-Native-QA.app`。本地候选：`.cache/native-migration/native-local-Y3cAEjc8/Dotist.app`，版本 `0.1.2`，`DotistBuildLabel=native-local-20261031T083732Z`。两者 arm64 Mach-O UUID 均为 `CF62A7D5-59FB-3E5E-B5C3-9FA542B4F7DC`，重签名后的文件哈希不用于判断是否来自同一构建。候选通过 `codesign --verify --deep --strict`；属于本地 ad hoc 包，没有声称已 Developer ID 签名或公证。

| 证据层级 | 结果 | 可复查资源（仓库相对路径） |
| --- | --- | --- |
| Rust 核心 | 41 个测试通过 | `.cache/native-migration/core-final.log` |
| C ABI／实际 MCP 与 Swift 连接 | 3 + 2 个测试通过 | `.cache/native-migration/bridge-final-glass.log` |
| 最终原生界面 | 6 个 XCTest 通过：完成、圆点返回、日历／甘特选中日期、主题持久化、原生分段控件、4 次连续收放的长短任务布局 | `.cache/native-migration/ui-tests-p3N5AXFL/results.xcresult` |
| 最终无遮挡截图补充 | 同一最终二进制，主题与日／周／月、看板、甘特切换 2 项通过；固定背景辅助窗口已退出后重拍 | `.cache/native-migration/clean-visual-final.xcresult` |
| 最终缩放 | 实际拖动窗口边缘至 324×562 pt，再收放，尺寸与布局断言通过 | `.cache/native-migration/review-resize-hfx_6pzy/results.xcresult` |
| 中线悬停稳定性 | 停留 0.01／0.03／0.08／0.15／0.25／0.04 秒进出横条，均保持原点且收回 48 pt，再点击展开成功 | `.cache/native-migration/review-bubble-center-cvii08t3/results.xcresult` 与 `data/hover-sweep-result.json` |
| 前置实际任务流程 | 新增、编辑、完成／重开、删除／撤销；跨分组排序不改所属分组 | `.cache/native-migration/review-tasks-iqtgoivv/results.xcresult`、`review-cross-group-g62xcoc3/results.xcresult` |
| 前置视图与拖动流程 | 日／周／月，日历拖动改期，看板状态拖动，甘特分组折叠及日期拖动；圆点拖动、悬停后立即拖动、详情点击 | `.cache/native-migration/review-gantt-flow-1zazgdya/results.xcresult`、`review-bubble-drag-pxs0_e85/results.xcresult`、`review-bubble-hover-drag-u1v1bcrv/results.xcresult`、`review-bubble-details-1n164_oq/results.xcresult` |
| 最终正式包 MCP | 实际执行 initialize、tools/list、tools/call list_tasks，正常退出；使用新的隔离 SQLite | `.cache/native-migration/installation-candidate.json`、`packaged-mcp-ty3shnd1/responses.json` |
| 保留网页回归 | 173 个测试通过及构建通过；这些结果不作为原生界面证据 | `.cache/native-migration/web-tests-final.log` |

前置流程测试发生在字体缓存与强调色调整之前，表中明确区分，不将它们全部称为最终包重新执行的结果。独立评审发现并修复中线悬停锚点问题，最终字体缓存与本地替换流程也经独立只读复核。

视觉资源入口：[本地截图对照与原生截图](../.cache/native-migration/acceptance/index.html)。主面板使用相同隔离任务、364×620 pt 内容尺寸、浅色、简体中文、2×缩放及固定蓝橙背景；指针移出窗口后直接截取窗口区域。已检查文字层次、任务密度、分组／日期色、位置、玻璃、选中态与顶部去下划线。新面板背景色更可见，正常任务行没有单独玻璃卡片。

视觉差异明确保留：CoreText 与 WebKit 的文字栅格观感不同，SF Symbols 轮廓和部分内边距不是网页图标的逐像素复刻；顶部原生按钮和文字宽度略有差别；主面板系统玻璃折射及边缘高光不同于旧 CSS 模糊。主面板已做真实对照；其他页面提供原生状态截图及交互测试，尚未完成每个页面、每个主题、编辑／聚焦及所有无障碍状态的迁移前后逐像素对照，不能称为全面视觉验收。

## 16:41 迁移基线的动画性能记录

测试机器：Apple Silicon MacBook Pro，macOS 27.0（26A5425a）、2× Retina；观测时显示器为 120 Hz。旧 Tauri 与最终原生分别使用同一隔离数据库、浅色、简体中文、364×620 pt 主面板和固定背景，禁用闲置淡出、自动收起和悬停展开。Instruments `Animation Hitches` 每份记录 25 秒，由相同 XCTest 动作连续收起／展开 4 次。

下面统计目标进程的非系统 hitch 与“点击请求开始至目标控件存在确认”区间的重叠。该区间包含 XCTest 等待，长于实际窗口动画；不是应用 FPS、精确动画帧时间或窗口更新次数。Tauri 的 WebKit 子进程不计入主进程统计，因此不能据此证明两个架构的全部渲染开销差异。

| 版本 | 观测区间合计 | hitch 数量 | 最长 hitch | hitch 时长合计 |
| --- | ---: | ---: | ---: | ---: |
| Tauri 基线 | 14.644 秒 | 67 | 24.99 ms | 625.00 ms |
| 原生，字体缓存前 | 13.922 秒 | 46 | 58.33 ms | 533.33 ms |
| 最终原生 | 13.934 秒 | 53 | 41.67 ms | 608.35 ms |

该迁移基线的最终原生包首轮收起仍有 41.67 ms hitch。缓存移除了已定位的重复字体匹配，但这三份小样本不能证明统计性提速，最终原生的最长 hitch 仍高于本次旧版样本。几何位置跳变的回归断言通过，与渲染停顿是两个不同结论；不能宣称“零卡顿”或“稳定 120 FPS”。

原始记录分别为 `.cache/native-migration/animation-baseline-emxrd3jo/animation.trace`、`animation-native-799hccpo/animation.trace`、`animation-native-0bg_3h3_/animation.trace`。导出的 `toc.xml`、`hitches.xml`、`frames.xml`、动作时间及 [animation-comparison-final.json](../.cache/native-migration/animation-comparison-final.json) 均保留。分析脚本为 `.cache/native-migration/xcui/summarize-hitches.py`。

## 16:41 迁移基线的安装与恢复

本节保留当次安装、进程及备份证据；后续本机替换状态以 [修整记录](native-polish-2026-10-31.md) 为准。

已于 **2026-10-31 16:41（Asia/Shanghai）** 替换并启动 `/Users/junyu/Applications/Dotist.app`。本地构建标识为 `native-local-20261031T083732Z`，保留对外版本 `0.1.2`。已核实进程 PID `43725`、精确可执行路径、SwiftUI/AppKit 链接、深度严格签名校验及原数据库文件句柄。旧进程 `75712` 正常退出，没有强杀。

正常启动读取原数据：`/Users/junyu/Library/Application Support/com.dotist.app/tasks.sqlite`。安装前从只读连接做一致性备份，旧应用完整保留；未将真实任务用于 CRUD、排序或截图测试。备份目录：

```text
/Users/junyu/DevProjects/Dotist/.cache/native-migration/installed-backup-20261031-164118
  Dotist.app          原已安装 Tauri 0.1.2，二进制哈希与替换前一致
  tasks.sqlite       一致性备份，PRAGMA integrity_check = ok
  settings.json      原偏好备份
  manifest.json      替换前清单（若原 UserDefaults 文件存在亦复制）
```

当次核验清单：[installation.json](../.cache/native-migration/installation.json)。当次验收结束时原生应用保持运行。正常安装路径的启动命令为：

```bash
open /Users/junyu/Applications/Dotist.app
```

如需回退到本节保留的旧 Tauri 包，先核对 [后续安装与回退记录](native-polish-2026-10-31.md)，再从菜单正常退出当前 Dotist，将当前原生 `Dotist.app` 移到一个新的保留目录，再将上述备份中的旧 `Dotist.app` 放回 `/Users/junyu/Applications/Dotist.app` 并启动。**通常只需回退应用；不要把旧 SQLite 备份覆盖回正在使用的数据库**，否则会丢失安装后产生的任务变化。数据库恢复只在确认损坏及恢复范围后单独执行。

安装脚本为 `.cache/native-migration/install-validated.py`，只正常退出精确路径的旧应用；出现拒绝退出、多实例或退出超时就停止，未实施强制终止。

## 16:41 迁移基线的剩余边界与资源

- 该基线首次收起的残余 hitch 如上；系统材料无法逐像素对应 CSS 模糊，也没有声称所有页面全状态视觉一致。
- Sparkle 原生 feed／公钥及签名流水线已在后续接入，但公开 appcast 尚待单独授权发布。隔离签名更新验证通过不等于生产发布；见原生更新验收文档。
- 当前包为 Apple Silicon；macOS 11 回退、Intel、系统减少动态效果／透明度／增强对比度的实机完整覆盖尚未完成。保留公开 API 回退与无障碍语义，不以代码存在代替实机验收。
- 没有提交、推送或公开发布。工作区原有改动全部保留，没有清理归属不明文件。
- 隔离示例数据、测试结果、截图、Instruments trace 与旧应用／数据备份保留在 `.cache/native-migration/`。这些是验收与回退资源，不是用户主数据库。

该次验收结束时，QA／baseline 窗口、固定背景辅助窗口、XCTest／Instruments 录制及隔离更新 HTTP 服务均已停止；更新服务原端口 `127.0.0.1:50391` 已确认释放。正常安装的 Dotist 当时保持运行供用户使用。没有删除隔离数据库、验收产物、备份或无关资源；后续运行与资源状态以修整记录为准。
