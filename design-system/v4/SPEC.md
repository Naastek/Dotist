# Dotist v4 · 定稿规范（方案 A）

> 对应 `native/Sources/DotistApp`（SwiftUI + AppKit，macOS 26）。v3.x 及更早的 web 组件已废弃，仅作历史参考。
> 图：`spec.png`（对齐与图标）· `main-light/dark.png` · `menu.png` · `edit.png` · `drag.png` · `undo.png` · `bubble.png`

## 0. 永久禁用（任何新设计都不得出现）

| 禁用 | 当前代码中的位置 | 替换为 |
|---|---|---|
| 按钮 / 标签下方的下划线指示 | 旧 mockup；`RangeCalendar` 第 82 行 6×2 小横条 | 颜色 + 字重 |
| 条目前的小圆点 | 拖放指示 `Circle().frame(5,5)` | 一条细线 |
| 选中项左侧竖线 | 旧 mockup 菜单 | 原生 Menu ✓ |
| 圆角矩形底板表示选中 | `FolderGroupTab`、`DotistGlassTabs`、撤销提示 `surface+cornerRadius(8)` | 颜色 + 字重；提示改为玻璃胶囊 |
| 编辑时放大字号并加下划线 | 旧 InlineEdit | 原位、同字号，输入区浅色底与光标 |
| 悬浮球上的任何进度环 / 弧 | `FloatingBubble` track + trim | 删除，只显示剩余数字；任务勾选圆的子任务分段进度保留 |
| 组色点、面板内的玻璃按钮 / 玻璃标签 | `DotistActionStyle` / `DotistControlGlass` 在面板内 | 纯文字 / 纯图标 |

**选中表达：颜色 + 字重；任务选中时勾选圆描边为 accent、正文为 Medium。**

- 选中：ink，Sans Medium，或 Serif Semibold。
- 未选中：faint，Regular。
- 悬停：muted。

选中不加底板；编辑输入区使用下述浅色底。

## 1. 网格与尺寸

面板 364 × 620，圆角 20（`DotistDesign.windowCornerRadius`）。

| 竖线 | x | 用途 |
|---|---|---|
| 左缘 | 16 | 日期行、组名、顶层勾选圆左缘、输入栏组名 |
| 正文层级 0–4 | 42 / 64 / 86 / 108 / 130 | 各层正文左缘；下一层勾选圆左缘对齐上一层正文 |
| 右缘 | 348 | 元信息和最右图标字形右缘 |

最多 5 层（d=0..4）。`textX(d)=42+22d`；`circleX(0)=16`，`circleX(d≥1)=textX(d-1)`。换行续行仍对齐本层 textX；勾选圆圆心与整个文字块垂直居中。

| 行 | 高 | 备注 |
|---|---|---|
| 第一行：工具 | 44 | padding 左 16 / 右 10 |
| 第二行：日期范围 | 30 | 底部 4 |
| 组头 | 30 | 第一个组距顶 6，组间距 20 |
| 任务 | ≥ 32 | 上下 6，正文行高 20 |
| 子任务 | ≥ 28 | 上下 4 |
| 已完成折叠行 | 28 | |
| 输入栏 | 52 | 顶部 0.5pt rule |

空组只占一行组头（组名为 faint，不显示数量），不再显示“还没有任务”。

## 2. 字体

| 角色 | 字体 | 字号 / 行高 | 字重 | 颜色 |
|---|---|---|---|---|
| 组名 / 今天视图分区名 | Serif | 15 / 22 | Semibold | ink；空组 faint；“已逾期” danger |
| 任务 / 子任务正文 | Sans | 13 / 20 | Regular | ink；已完成 faint（不加删除线） |
| 日期范围 | Sans | 13 / 20 | 选中 Medium | 选中 ink，其他 faint |
| 到期日 | Sans | 12 / 20 | Regular | muted；今天 accent；逾期 danger |
| 子任务计数 `1/3 ⌄` | Sans | 12 / 20 | Regular | faint |
| 跨组视图中的组名 | Serif | 12 / 20 | Semibold | faint |
| 输入栏组名 | Serif | 13 / 20 | Semibold | muted |
| 输入栏正文 | Sans | 13 / 20 | Regular | ink；占位 faint；光标 accent（`.tint(DotistDesign.accent)`） |

日期范围行的字号统一为 13，取消 17 / 13 / 12 的跳变。每个槽位的宽度按 Medium 字重预先量好，切换选中时不会抖动。

## 3. 图标（统一为 SF Symbols，`.regular`，不再混用自绘路径）

Logo 只出现在菜单栏和 App 图标里，不再兼任面板里的搜索按钮。

| 位置 | Symbol | 字号 | 点击区 | 颜色 |
|---|---|---|---|---|
| 顶栏：搜索 | `magnifyingglass` | 14pt（视觉约 16） | 28 × 28 | muted，悬停 ink |
| 顶栏：视图 | `rectangle.split.2x1`（或现有 views 字形） | 14pt | 28 × 28 | 同上 |
| 顶栏：更多 | `ellipsis` | 14pt | 28 × 28 | 同上；“固定”“锁定”收进这里 |
| 顶栏：收起 | `arrow.down.right.and.arrow.up.left` | 14pt | 28 × 28 | 同上 |
| 日期行 / 输入栏：日历 | `calendar` | 13pt | 24 × 24 | muted |
| 行操作（悬停或键盘焦点时） | `plus`、`calendar`、`xmark` | 11pt | 22 × 22 | muted；**替换**右侧元信息，不叠加、不加底色 |
| 组头操作（悬停时） | `arrow.up.right.square`、`plus` | 11pt | 22 × 22 | faint |
| 展开箭头 | `chevron.down` / `chevron.right` | 8–9pt，semibold | 随文字 | faint，与文字基线对齐 |
| 菜单勾选 | 系统 ✓ | — | — | 原生 `Menu` / `Picker`，不自绘 |

对齐规则：

- 图标按**字形**对齐，而不是按 frame 对齐。顶栏 frame 右缘在 354，字形右缘在 348。
- 竖向用 `.frame(height:)` 居中到所在行的文本行盒，即 20pt 行高的中心。

## 4. 勾选圆

- 尺寸：任务 16pt，放在 18 × 20 的框里；子任务 13pt，放在 14 × 20 的框里。
- 描边：1.25pt，颜色为 rule 的加深灰：浅色 `#9a9aa0`，深色 `#77777f`。
- 完成：accent 实心，内含 9pt 勾（`checkmark`，heavy，白色；深色模式用 paper 色）。
- 键盘焦点：描边变为 accent。不加底板，不用系统的 focus ring。
- 有直接子任务时，勾选圆分为 N 段（N 为直接子任务数），段间约 8°；N=1 为整圆。已完成子任务的段用 accent 描边或填色，未完成的段用 checkStroke。自身完成时仍用实心 accent 圆加对勾。行尾保留 `1/3 ⌄`，点击展开 / 收起。

## 5. 各组件

**分组切换与工具栏**

- 顶部不显示分组标题或下拉箭头。分组切换使用面板左缘外的便签标签：静止时露出窄边，指针靠近时整体滑出显示全称。
- 右上工具栏仅“收起”常驻，其余工具悬停显示；设置中可配置顺序和可见性，按住 ⌘ 可左右拖动排序。
- 悬停提示使用系统 tooltip（`.help`），不显示底部提示行。

**日期范围行**：今天 · 全部 · 明天 · 本周 · 已逾期，右侧放日历按钮。选中项只做颜色 + 字重的变化。

**任务行**

- 结构：按层级的 circleX 和 textX 布局，勾选圆与整个文字块垂直居中；正文换行保持左缘。
- 悬停：元信息隐藏，行操作出现在同一位置，行背景不变。

**原位编辑**

- 同一个位置、同样 13 / 20、同样颜色，光标为 accent。
- 输入区用 `rule` 18% 不透明度的浅色底，圆角 6，左右各外扩 6；文字不位移，不加下划线、不放大。
- 其他行不再变暗，也不再显示提示行（快捷键放在“⋯ → 键盘快捷键”）。

**多选与缩进**：Shift+点击选择范围，⌘+点击增减，Shift+↑/↓ 扩展选择；选中态为勾选圆描边 accent、正文 Medium，不加底。Tab 将选中任务全部归为选中集合之前最近一个未选中的同级任务的子任务；⇧Tab 提升一级；Esc 清除选择；Return 在行上新建同级任务。层级限制为 0..4。

**已完成折叠**：`›` 放在 18 宽的勾选列里居中，文字“已完成 3”为 faint、12pt。

**拖放**

- 参考 Tic：被拖行块浮起，仅沿垂直方向跟随光标；其余行约 0.18s 快速平移让开。
- 目标处显示同高 ghost 占位行，勾选圆描边和文字均为 35% 透明度。水平拖动超过一个缩进步长（22pt）的 70% 才改变层级；ghost 缩进同步变化，目标父任务的勾选圆描边变 accent 提示。
- 松手一次性提交，Esc 取消；多选时整组一起拖。靠近列表上下边缘 24pt 自动滚动。层级限制为 0..4。
- 拖动时输入栏可变形为分组架：玻璃胶囊，高 48，组名为 Serif 14。悬停目标 ink，其余 faint。

**撤销提示**

- 玻璃胶囊（`.glassEffect(.regular, in: .capsule)`），高 36，浮在输入栏上方 12。
- 文字为 muted、13pt；“撤销”为 accent Medium。4 秒后淡出。

**输入栏**：`Inbox`（Serif 13，muted，无下箭头）→ 正文 → 日历图标，左右 padding 16 / 11。日历图标仅悬停显示，日期文字仅显式设置日期时显示。标签建议使用浮起的玻璃，不用 surface 底板。

**日历弹层（RangeCalendar）**

- 今天：ink Semibold。
- 选中的端点：accent Semibold。
- 区间内的日期：ink。
- 其他日期：muted；不在本月的日期：faint。
- 删除实心圆和底部小横条。

**视图窗口（ViewsWindow）**：`DotistGlassTabs` 改为与日期行相同的文字切换；`DotistActionStyle` 的玻璃按钮改为纯文字按钮（accent）。设置窗口保留系统 `Picker(.segmented)`，因为那是系统控件。

**悬浮球 / 横条**

- 直径 48（与代码一致），`.glassEffect(.regular.interactive(), in: .circle)`。
- 中间只显示剩余数量，Sans Semibold 20；全部完成显示 0。
- 悬停时，同一块玻璃（共用 `glassEffectID`）横向拉伸成 250 × 48 的横条：左侧是下一件任务（13 Medium）加上“组 · 到期”（12 muted），数字保持在右侧原位。
- **无任何进度环或弧，只显示剩余数字。**

## 6. Liquid Glass 分层

1. 面板是唯一常驻的玻璃：`.glassEffect(.regular, in: .rect(cornerRadius: 20))`。用户的透明度设置只调节叠在上面的 paper 色浓度。面板本身不加 `.interactive()`。
2. 内容直接印在玻璃上；编辑输入区使用 rule 18% 浅色底。
3. 临时浮层各自是独立的玻璃：菜单、日历、分组架、撤销提示、搜索、悬浮球。它们放在 `GlassEffectContainer` 里，以便融合和变形。
4. 任何一点最多叠两层玻璃。开启“减少透明度”时，改用 paper 实色。

## 7. 代码改动清单（供实现）

| 文件 | 改动 |
|---|---|
| MainWindow.swift | 左缘便签切换分组；工具栏配置与悬停；五层对齐、子任务分段进度、多选与拖放；编辑浅色底；输入栏和组头更新 |
| DotistDesign.swift | 删除 `DotistGlassTabs` 的胶囊选中，改为文字切换；面板内不再使用 `DotistActionStyle`；`DotistFocusRing` 改为只变色 |
| DotistIcon.swift | 顶栏改用 SF Symbols；仅保留 Logo 字形 |
| PanelMotion.swift | `FloatingBubble` 删除 track 和 trim 两个圆 |
| RangeCalendar.swift | 删除端点实心圆和小横条，改为颜色 + 字重 |
| ViewsWindow.swift | `DotistGlassTabs` / `DotistActionStyle` 按上表替换 |
