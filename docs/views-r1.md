# 视图窗口第一轮

## 实现范围与入口

新增独立 `views` Webview，正常尺寸 1000×720，最小尺寸 680×480。由托盘菜单「任务视图」或应用菜单 `CmdOrCtrl+Shift+V` 打开，已存在时取消最小化、显示并聚焦。这个组合键仅是应用菜单 accelerator，没有注册成全局快捷键。主清单没有新增入口按钮。

浏览器预览运行 `npm run dev` 后访问：

```text
http://127.0.0.1:1420/?demo&views
```

保留 `?demo`、`?demo&settings`、`?demo&quick` 的原有路由。demo 在内存中维护数据，不读取真实数据库；页面重新加载会重置。原生窗口使用不带 `demo` 的 `?views`，通过 core 命令读写 SQLite。

## 视觉与交互

延续现有 tokens.css、dotist.css、app.css 的纸墨色调、Source Serif / Source Sans / Noto 字体与间距。分段控件采用 8px 圆角，按钮 6px，任务卡 8px；没有胶囊标签、纹理、玻璃边或装饰阴影。只有勾选圈使用整圆；分组以小圆点加中性色名称显示。

视图窗口使用标准原生标题栏和不透明纸色背景，跟随主题与语言。没有把悬浮清单的悬浮球、闲置淡出或毛玻璃效果复制到这个工作窗口。

- 日历按到期日排入月网格，选中日期后显示当天完整任务。42 格保持高度稳定，格内最多展示两条摘要，其余以数量提示；完整标题和操作保留在当天列表。
- 方向键移动日期与键盘焦点，跨月自动翻页；分段控件支持方向键、Home、End。
- 「未排期」与当天列表并列显示；较窄窗口下移到月网格下方。日历包含有日期的子任务，未排期也保留子任务，并明确标注「子任务」。
- 日历列表可勾选；拖放卡片或格内任务摘要到日期可调整到期日。「调整任务」中的日期输入提供非拖动方式，并可设置开始日、清空日期。
- 逾期条件为 `due_date < 本地今天 && !completed`。日历摘要使用三角形，完整卡片使用「△ 已逾期」；已完成任务使用勾选形状和删除线。
- 看板仅展示顶层任务，分待办、进行中、完成。标题旁有不同形状的状态符号，卡片显示分组、到期日、逾期提示和已完成/全部子任务数。
- 跨列拖动改变状态；「调整任务」提供可用键盘操作的状态选择、上移和下移。列内按 `position,id` 排序；跨分组位置重合时，排序事务归一化当前状态列的顶层任务位置。清单仍使用原来的分类/position 排序逻辑，同一份 position 的调整会反映到清单。
- 使用 `disable_drag_drop_handler()` 关闭新窗口的 Tauri 文件拖放拦截，以使 HTML5 任务拖放到达页面。只改变新视图窗口。
- 状态、日期、看板排序写入成功后由 Rust 广播 `dotist://tasks-changed`，复用主清单已有监听；视图窗口也监听该事件，并在聚焦和每 3 秒重读，覆盖 MCP 或其他外部写入。

新文案完整补齐项目现有四种语言：zh-CN（简体中文，即 zh-Hans）、en、zh-TW、ja。中文源文案为默认回退，没有新增缺省语言分支。原生菜单和窗口标题沿用 Rust `native_text` 的四语言表。

## 数据约定

schema v5 新增 `status`（todo/doing/done）和可空 `start_date`。v4→v5 的加列、completed 映射、索引和 `user_version=5` 在同一事务完成。重复打开不重复迁移；迁移失败会回滚列、数据和版本。

core 统一维护 `completed == (status == done)`。勾选改为 done，取消勾选改为 todo；单独修改标题或分组保留 doing。完成父任务仍完成全部子任务；子任务不会反向完成父任务。显式提供矛盾的 completed/status 会拒绝。任务与 outbox 在同一事务写入。

开始日和到期日均严格使用本地 `YYYY-MM-DD`，双向校验 start≤due。任一日期为空时允许单独设置另一日期；清空日期不影响状态。旧 outbox 的 Task JSON 经 serde 默认值读取：缺失 start_date 得到 None，缺失 status 根据 completed 推导，保留已完成语义。新增 MCP 工具 `set_task_status` 与 `set_start_date` 直接调用同一 core，现有 complete_task 同样同步状态。

没有实现 CloudKit 上传、合并或账号接入。

## 验收证据（2026-10-30）

执行命令：

```sh
npx tsc --noEmit
npm test
RUSTUP_HOME=$PWD/.toolchain/rustup CARGO_HOME=$PWD/.toolchain/cargo PATH=$PWD/.toolchain/cargo/bin:$PATH CARGO_TARGET_DIR=$PWD/.cache/core-test-target cargo test --manifest-path crates/dotist-core/Cargo.toml
RUSTUP_HOME=$PWD/.toolchain/rustup CARGO_HOME=$PWD/.toolchain/cargo PATH=$PWD/.toolchain/cargo/bin:$PATH CARGO_TARGET_DIR=$PWD/.cache/tauri-target cargo check --manifest-path src-tauri/Cargo.toml
```

最后一次完整检查均返回 exit 0，输出摘要：

```text
npx tsc --noEmit: 无 stdout/stderr，exit 0
npm test: Test Files 12 passed (12); Tests 107 passed (107)
cargo test: 27 passed, 0 failed（分布于 due/groups/mcp/mcp_views/store/views_v5 六个集成测试文件）
cargo check: Finished `dev` profile [unoptimized + debuginfo] target(s) in 0.30s
```

前端测试包含现有 React act 警告和 Node localStorage ExperimentalWarning；没有测试失败。完整日志保存在 `.cache/views-r1-{tsc,npm-test,core-test,tauri-check}.log`。

新增测试：

- `tests/views.test.tsx`：两个视图渲染与切换、顶层过滤和子任务计数、逾期与未排期、跨列拖放、非拖动状态修改、勾选联动、列内排序、日历拖放与日期输入、跨月键盘导航、写入错误保留、广播刷新。
- `crates/dotist-core/tests/views_v5.rs`：v4→v5 数据保留/完成映射/幂等/版本、失败回滚重试、状态不变量及 outbox、日期范围拒绝/原子性、旧 outbox JSON、位置重合时的看板排序。
- `crates/dotist-core/tests/mcp_views.rs`：实际 stdio MCP 进程中的状态与勾选双向联动、日期校验和非法状态拒绝；数据库由 tempfile 隔离。

本轮对原有测试的必要调整，仅限：

1. `tests/dates.test.ts`：任务夹具补 status/start_date，状态跟随夹具 completed；断言不变。
2. `tests/tray-quick.test.tsx`：同上；断言不变。
3. `tests/tags.test.tsx`：同上；断言不变。
4. `crates/dotist-core/tests/due.rs`：迁移后的最新版本断言从 4 改为 5，旧数据与到期日检查保留。
5. `crates/dotist-core/tests/store.rs`：同样只调整最终版本断言 4→5。

本轮没有编辑 App.tsx 或原日期选择器 Calendar.tsx。工作期间其他改动向主窗口加入了「管理标签…」，全量测试一度因对应菜单断言尚未同步而失败；该并发改动随后补齐断言，未由本轮修改或回退。最终日志以最后一次完整检查为准。

## 尚未完成的人工验证

Vite 本地预览实际启动失败，错误为 `listen EPERM: operation not permitted 127.0.0.1:1420`。另尝试 Vite 内存构建后由浏览器请求拦截直接提供产物，构建成功（1785 modules transformed），但 Chrome 在本环境启动即退出（SIGABRT），没有获得截图。没有提权、安装依赖、替换应用或重启现有 Dotist。

因此尚未验证真实窗口的尺寸、聚焦/复用、托盘菜单、应用快捷键、原生 WebKit 的 HTML5 拖放、主题外观，以及最小尺寸的实际绘制。悬浮清单的毛玻璃、闲置淡出和悬浮球原生行为也未在本环境重新验证；测试通过不等同于这些原生行为已验证。
