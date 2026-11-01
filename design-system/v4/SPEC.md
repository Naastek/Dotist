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
| 编辑时放大字号并加下划线 | 旧 InlineEdit | 原位、同字号、仅出现光标 |
| 勾选圆上的进度环 / 分段弧 | `taskRow` 多子任务分段弧 | 删除，保留 `1/3 ⌄` 文本 |
| 悬浮球进度环 | `FloatingBubble` track + trim | 删除，只显示剩余数字 |
| 组色点、面板内的玻璃按钮 / 玻璃标签 | `DotistActionStyle` / `DotistControlGlass` 在面板内 | 纯文字 / 纯图标 |

**唯一的选中表达：颜色 + 字重。**

- 选中：ink，Sans Medium，或 Serif Semibold。
- 未选中：faint，Regular。
- 悬停：muted。

不加任何附加形状。

## 1. 网格与尺寸

面板 364 × 620，圆角 20（`DotistDesign.windowCornerRadius`）。

| 竖线 | x | 用途 |
|---|---|---|
| 左缘 | 16 | 标题、日期行、组名、勾选圆左缘、输入栏组名 |
| 任务正文 | 42 | = 16 + 勾选框 18 + 间距 8；子任务勾选圆左缘也在这里 |
| 子任务正文 | 64 | = 42 + 14 + 8 |
| 右缘 | 348 | 元信息右缘、最右图标的**字形**右缘（不是点击区右缘） |

| 行 | 高 | 备注 |
|---|---|---|
| 第一行：标题 + 工具 | 44 | padding 左 16 / 右 10 |
| 第二行：日期范围 | 30 | 底部 4 |
| 组头 | 30 | 第一个组距顶 6，组间距 20 |
| 任务 | ≥ 32 | 上下 6，正文行高 20 |
| 子任务 | ≥ 28 | 上下 4 |
| 已完成折叠行 | 28 | |
| 输入栏 | 52 | 顶部 0.5pt rule |

空组只占一行组头（组名为 faint，后面跟 0），不再显示“还没有任务”。

## 2. 字体

| 角色 | 字体 | 字号 / 行高 | 字重 | 颜色 |
|---|---|---|---|---|
| 面板标题（分组切换） | Serif | 18 / 24 | Semibold | ink |
| 组名 / 今天视图分区名 | Serif | 15 / 22 | Semibold | ink；空组 faint；“已逾期” danger |
| 组内计数 | Sans | 12 / 16 | Regular | faint，紧跟组名，间距 6 |
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
- **不再有任何进度弧。** 子任务进度只看行尾的 `1/3 ⌄`，点击即展开 / 收起。

## 5. 各组件

**标题菜单（方案 A）**

- “全部 ⌄”是原生 `Menu`，自带玻璃效果。
- 菜单项依次为：全部分组 / 各组（Serif 14）/ 分隔线 / 在独立面板中打开… / 管理分组…
- 当前项用系统 ✓ 标出，计数靠右显示为 faint。
- 原来的分组标签行整行删除。

**日期范围行**：今天 · 全部 · 明天 · 本周 · 已逾期，右侧放日历按钮。选中项只做颜色 + 字重的变化。

**任务行**

- 结构：`HStack(alignment: .firstTextBaseline, spacing: 8)` = 勾选框 18 + 正文 + 元信息（间距 8）。
- 悬停：元信息隐藏，行操作出现在同一位置，行背景不变。

**原位编辑**

- 同一个位置、同样 13 / 20、同样颜色，只多出 accent 光标。
- 无底板、无下划线、无放大。
- 其他行不再变暗，也不再显示提示行（快捷键放在“⋯ → 键盘快捷键”）。

**子任务**：缩进 26，勾选圆左缘位于 42，正文位于 64。

**已完成折叠**：`›` 放在 18 宽的勾选列里居中，文字“已完成 3”为 faint、12pt。

**拖放**

- 拖起的任务变成一块玻璃，并带 1.2° 的倾斜。
- 落点指示是一条 1.5pt 的 accent 细线：起点在目标层级的正文列（42 或 64），终点在 348，两端圆角。**没有圆点。**
- 拖动时输入栏变形为分组架：玻璃胶囊，高 48，组名为 Serif 14。悬停目标 ink，其余 faint。

**撤销提示**

- 玻璃胶囊（`.glassEffect(.regular, in: .capsule)`），高 36，浮在输入栏上方 12。
- 文字为 muted、13pt；“撤销”为 accent Medium。4 秒后淡出。

**输入栏**：`Inbox ⌄`（Serif 13，muted）→ 正文 → 日历图标，左右 padding 16 / 11。标签建议使用浮起的玻璃，不用 surface 底板。

**日历弹层（RangeCalendar）**

- 今天：ink Semibold。
- 选中的端点：accent Semibold。
- 区间内的日期：ink。
- 其他日期：muted；不在本月的日期：faint。
- 删除实心圆和底部小横条。

**视图窗口（ViewsWindow）**：`DotistGlassTabs` 改为与日期行相同的文字切换；`DotistActionStyle` 的玻璃按钮改为纯文字按钮（accent）。设置窗口保留系统 `Picker(.segmented)`，因为那是系统控件。

**悬浮球 / 横条**

- 直径 48（与代码一致），`.glassEffect(.regular.interactive(), in: .circle)`。
- 中间显示剩余数量，Sans Semibold 20。全部完成时显示 accent `checkmark`，20pt。分组面板显示组名前两个字，Serif Semibold 15。
- 悬停时，同一块玻璃（共用 `glassEffectID`）横向拉伸成 250 × 48 的横条：左侧是下一件任务（13 Medium）加上“组 · 到期”（12 muted），数字保持在右侧原位。
- **无进度环。**

## 6. Liquid Glass 分层

1. 面板是唯一常驻的玻璃：`.glassEffect(.regular, in: .rect(cornerRadius: 20))`。用户的透明度设置只调节叠在上面的 paper 色浓度。面板本身不加 `.interactive()`。
2. 内容直接印在玻璃上，没有底块和描边。
3. 临时浮层各自是独立的玻璃：菜单、日历、分组架、撤销提示、搜索、悬浮球。它们放在 `GlassEffectContainer` 里，以便融合和变形。
4. 任何一点最多叠两层玻璃。开启“减少透明度”时，改用 paper 实色。

## 7. 代码改动清单（供实现）

| 文件 | 改动 |
|---|---|
| MainWindow.swift | 删 groupTabs / `FolderGroupTab`；标题改为 `Menu`；日期行统一 13pt；删除分段弧和环；删除拖放圆点；编辑态去掉变暗和提示行；空组改为一行；撤销提示改为玻璃；输入栏加 `.tint`；悬停时行操作替换元信息；左缘统一为 16 / 42 / 64 |
| DotistDesign.swift | 删除 `DotistGlassTabs` 的胶囊选中，改为文字切换；面板内不再使用 `DotistActionStyle`；`DotistFocusRing` 改为只变色 |
| DotistIcon.swift | 顶栏改用 SF Symbols；仅保留 Logo 字形 |
| PanelMotion.swift | `FloatingBubble` 删除 track 和 trim 两个圆 |
| RangeCalendar.swift | 删除端点实心圆和小横条，改为颜色 + 字重 |
| ViewsWindow.swift | `DotistGlassTabs` / `DotistActionStyle` 按上表替换 |
