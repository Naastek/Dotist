# Dotist v4 实现交接（Handoff）

> 给执行任务的说明：把 v4 定稿落实到 `native/Sources/DotistApp`。
> 设计依据：本设计系统（组件卡片 + `tokens.json`），以及项目内的 `design-system/v4/SPEC.md` 和 `design-system/v4/*.png`。
> 写于 2026-11-01，依据当时的代码行号；行号会漂移，以函数名为准。

## 0. 先读这三条

1. **永久禁用**（任何新增 UI 都不得出现，review 时逐条检查）：
   - 按钮或标签下方的下划线指示
   - 条目前的小圆点
   - 选中项左侧的竖线
   - 用圆角矩形或胶囊底板表示选中、悬停或焦点
   - 编辑时放大字号并加下划线
   - 勾选圆上的进度弧或进度环
   - 悬浮球的进度环
   - 分组色点
   - 面板内再嵌一层玻璃按钮或玻璃标签
2. **唯一的选中表达是颜色加字重**：
   - 选中：ink + Medium（Sans）或 Semibold（Serif）
   - 未选中：ink-faint + Regular
   - 悬停：ink-muted，或从 muted 变为 ink
   - 键盘焦点：图标和文字变 accent，勾选圆的描边变 accent
3. **对齐只有四条竖线**：16 / 42 / 64 / 348，详见“Alignment”卡片。图标按字形边缘对齐，不按点击区。

## 1. 约束

- macOS 26，SwiftUI + AppKit，Liquid Glass API：
  - `glassEffect`
  - `GlassEffectContainer`
  - `glassEffectID`
  - `ConcentricRectangle`
- 字体：沿用 `DotistDesign.font(_:weight:serif:language:)`。Serif 只用于“名字”：标题、组名、菜单里的组名、输入栏组名。其余一律 Sans。
- 颜色只使用 `DotistDesign` 已有的动态色。只有一处需要修改，见 §2.1。
- 不改数据模型和 `AppModel` 的行为；改动只在视图层。
- 保持现有的可访问性标签、`accessibilityIdentifier`、键盘行为（↑↓、⌥↑↓、Tab 缩进、Return、Esc）不变。删除的 UI 如果带有 identifier（例如 `group-tab:*`），需要把对应的 UI 测试一起迁移到新的标题菜单上。

## 2. 任务清单（按建议顺序）

### P1 · 基础（Design/）

**2.1 `DotistDesign.swift`**

- [ ] `faint` 的深色值由 `0xb0b0b8` 改为 `0x8e8e96`；`highDark` 保持 `0xc8c8cf` 不变。
  原因：原值与 ink（`0xeeeef0`）几乎分不开，深色下靠颜色表达选中会失效。
- [ ] 新增 `static let checkStroke = dynamic(0x9a9aa0, 0x77777f)`，作为未完成勾选圆的描边色。
- [ ] `DotistFocusRing`：删除 `RoundedRectangle … fill(rule.opacity(…))` 这层底色。
  - 改为通过 `@FocusState` 把 `foregroundStyle` 切到 `accent`。
  - 或者新增一个 `DotistFocusTint` 修饰符，按同样方式实现。
  - 两种做法都要保留 `.focusEffectDisabled()`。
- [ ] `DotistGlassTabs`：
  - 删除胶囊选中块（`matchedGeometryEffect` 那段）。
  - 删除外层 `DotistControlGlass`。
  - 改为纯文字切换：Sans 13，间距 16，选中 ink + Medium，其他 ink-faint。
  - `DotistTabFocusDecoration` 同样去掉底色，焦点时文字改为 accent。
- [ ] `DotistActionStyle`：面板和视图窗口内的用法都改为纯文字或纯图标按钮。
  - 删除 `.background(DotistControlGlass())`。
  - 颜色：主按钮 accent，普通按钮 ink；按下时 opacity 0.6。
  - `DotistControlGlass` 改为只给浮层使用，如果没有使用者就删掉。
- [ ] `FloatingMaterial`：`.clear.interactive()` 改为 `.regular`，paper 叠层保留。
  - 注意：代码注释提到，首次收起时 clear 切换到 regular.interactive 会出现冷启动卡顿。
  - 做法：先改为 `.regular.interactive()` 并保持不变（只换 clear 为 regular），确认收起和展开没有卡顿。
  - 如果改了反而卡顿，回退到原值并在 PR 里说明。这一项不是硬性要求。

**2.2 `DotistIcon.swift`**

- [ ] 只保留 Logo（如果别处需要）。下表中的调用点全部换成 SF Symbols：

| 旧 | 新 SF Symbol | 尺寸 |
|---|---|---|
| `.search` | `magnifyingglass` | 14pt，点击区 28×28 |
| `.views` | `rectangle.split.2x1` | 14pt，点击区 28×28 |
| `.collapse` | `arrow.down.right.and.arrow.up.left` | 14pt，点击区 28×28 |
| `.close` | `xmark` | 14pt，点击区 28×28 |
| `.calendar` | `calendar` | 13pt，点击区 24×24 |
| `.pin` / `.lock` | 移入“更多”菜单 | — |

- 调用点：
  - `MainWindow.toolbarButton`
  - `dateFilters`
  - `CommandPalette.swift:42,48`

### P2 · 主面板结构（MainWindow.swift）

**2.3 顶部两行**

- [ ] 删除 `groupTabs`（约第 166–183 行）和 `FolderGroupTab`（约第 695–719 行），并从 `body` 中移除调用。
- [ ] `header` 改为以下结构：
  - 左侧：标题 `Menu`。label 为当前分组名，“全部”时显示“全部”；Serif 18 Semibold，后接 9pt `chevron.down`（faint）。
  - 右侧：工具图标，依次为搜索、视图、更多（`ellipsis`）、收起；面板为独立面板时再加关闭。
  - padding：左 16，右 10，高 44。
- [ ] 标题 `Menu` 的菜单项：
  - 全部分组（总数）
  - Divider
  - 各组（未完成数）
  - Divider
  - 在独立面板中打开（子菜单，列出各组）
  - 管理分组…
  - 管理标签…
  - 当前项用系统勾选标出，例如 `Button { } label: { Label(name, systemImage: selected ? "checkmark" : "") }`，或用 `Picker(.inline)`。
- [ ] “更多”菜单：
  - 置顶窗口（勾选态）
  - 固定窗口（勾选态）
  - 键盘快捷键…（新增：弹出说明；或暂时只放一个 `Text` 列表）
  - 任务视图
  - 收起为悬浮球
  - 同时删除 `headerHovered` 控制的透明度逻辑。
- [ ] 删除 Logo 兼任搜索按钮的写法（约第 144–151 行），搜索改用 `magnifyingglass`。
- [ ] 日期范围行 `dateFilters`：
  - 高 30，padding：左 16，右 11，底 4；`HStack(spacing: 16)`。
  - `DraggableFilterButton` 改为统一 Sans 13：选中 `.medium` + ink，其他 `.regular` + faint，悬停 muted。
  - 槽宽按 Medium 13 量取。保留拖动窗口手势。
  - 删除按 distance 变化字号、透明度的逻辑，删除 serif 和 17 bold。
  - 日历按钮：13pt / 24×24。
- [ ] `tagBar`：
  - 高 24，padding 左右 16（原来是 22）。
  - 选中改为 ink + Medium（原来是 accent），其余 faint。

**2.4 列表与组头**

- [ ] `LazyVStack(alignment: .leading, spacing: 24)` 改为 `spacing: 0`。每个组加 `.padding(.top, isFirst ? 6 : 20)`；`todayList` 的分区之间同样用 20。
- [ ] 组头：
  - 改为 `HStack(alignment: .firstTextBaseline, spacing: 6)`。
  - 组名 Serif **15** Semibold，颜色 **ink**（原来是 14、muted）；空组用 faint。
  - 数量 `Text` 移到组名后面（Sans 12，faint），删除前面的 `Spacer`。
  - 操作按钮放进右对齐的 overlay，悬停时出现，规格 11pt / 22×22，颜色 faint。
  - 高 30，`.padding(.top, 4)`。
- [ ] 空组：删除“还没有任务”和“先放进 Inbox，稍后再整理”这两个 `Text`。
- [ ] 组内添加任务的 `QuickInput`：
  - padding 保持 26（正文对齐 42）；子任务模式由 52 改为 **48**（正文对齐 64）。
  - 行高：任务 32，子任务 28。
- [ ] “已完成 N”折叠按钮：
  - 箭头仍放在 `frame(width: 18)` 中，`HStack(spacing: 8)`。
  - 文字 Sans 12，颜色 faint（原来是 muted），行高 28。
  - `todayList` 里的“接下来 7 天”“已完成”使用同样的样式。
- [ ] `todaySection`：
  - 与组头使用同一个组件：Serif 15 + 紧跟的数量。
  - “已逾期”用 danger，“今天”用 ink（原来是 muted）。

**2.5 任务行 `taskRow`**

- [ ] `HStack(alignment: .firstTextBaseline, spacing: 6)` 改为 `spacing: 8`。
- [ ] 勾选圆：
  - **删除整个分段弧分支**（`children.count > 1` 的 `ForEach … trim`），以及单子任务的叠圈。
  - 未完成：`Circle().strokeBorder(DotistDesign.checkStroke, lineWidth: 1.25)`。
  - 完成：`Circle().fill(accent)` + `checkmark`，字号 `sub ? 7.5 : 9`，`.heavy`，颜色 on-accent（深色用 paper）。
  - 尺寸：圆为 `sub ? 13 : 16`；frame 为 `width: sub ? 14 : 18, height: 20`。
  - 对齐：用 `.alignmentGuide(.firstTextBaseline)` 让圆心落在 20pt 行盒中心。
  - 键盘焦点时（`focusedTask == task.id`），描边改为 accent。
- [ ] 正文：
  - 完成态删除 `.strikethrough(task.completed)`，颜色改为 faint（原来是 muted）。
  - 行内标签：选中改为 ink + Medium（原来是 accent），其余 faint。
- [ ] 元信息：
  - 跨组视图的组名改为 Serif 12 Semibold + faint（原来是 11 medium + muted）。
  - 子任务计数的箭头由 10pt 改为 8pt semibold。
- [ ] 行操作：
  - 由 20×24 + 11pt 改为 **22×22 + 11pt**，颜色 muted。
  - 显示时**隐藏元信息**：元信息加 `.opacity(actionsVisible ? 0 : 1)`；操作改为 `.overlay(alignment: .trailing)`，不再追加在 HStack 末尾，避免占位。
  - 最右字形对齐 348，即 overlay 加 `.offset(x: 5)`，或用 `.padding(.trailing, -5)`。
- [ ] 编辑态：
  - 删除提示 `Text("Return 保存 · ⇧Return 换行 · Tab 缩进")`。
  - 删除 `.opacity(editing != nil && editing != task.id ? 0.45 : 1)`。
  - `TaskEditor` 的光标色设为 accent：`editor.insertionPointColor = NSColor(DotistDesign.accent)`。
- [ ] 落点线：
  - 删除 `Circle().fill(accent).frame(5,5)`。
  - 改为 `Capsule().fill(accent).frame(height: 1.5).padding(.leading, sub ? 22 : 26)`。（taskRow 自身已在缩进内，所以子任务用 22 即可落在 64；请实测。）
- [ ] 行高保持 `minHeight: sub ? 28 : 32`；子任务 `.padding(.leading, 26)`（在 `taskTree` 中）不变。

**2.6 输入栏 `composerBar` / `ComposerLayout`**

- [ ] padding 由 `h 20 / v 12` 改为：左 16，右 11，高 52；顶部加 0.5pt `rule` 线，用 `Divider` 或 overlay 均可。
- [ ] 组名：
  - Serif 13 Semibold + muted（原来是 12 + ink），后接 9pt `chevron.down`。
  - 选择器由 popover + `GroupPickerRow` 改为原生 `Menu`（系统 ✓）。“管理分组…”“管理标签…”放在菜单末尾。
- [ ] 到期按钮移到最右侧，顺序变为“组名 → 正文 → [日期文字] + calendar 13pt / 24×24”。
  - 日期文字：Sans 12，accent；没有日期时只显示图标（muted）。
  - 同步修改 `ComposerLayout` 中 `subviews` 的顺序和测量。
- [ ] `ComposerInput` 加 `.tint(DotistDesign.accent)`，或设置 `insertionPointColor`。
- [ ] 标签补全：
  - 删除 `.background(paper).cornerRadius(8)` 和选中项的 `surface` 底。
  - 改为浮起的玻璃：`.glassEffect(.regular, in: .rect(cornerRadius: 12))`。
  - 当前项 ink + Medium，其余 muted。

**2.7 撤销提示**

- [ ] 删除 `.background(surface).cornerRadius(8)`。
- [ ] 改为 `.glassEffect(.regular, in: .capsule)`：高 36，padding 左 16、右 6；作为 overlay 浮在输入栏上方 12pt，不再插入 VStack。
- [ ] 文案用 Sans 13 + muted；“撤销”用 Medium + accent；关闭用 `xmark` 11pt / 22×22。
- [ ] 与输入栏放进同一个 `GlassEffectContainer(spacing: 12)`。

**2.8 拖动时的分组架（新增）**

- [ ] 条件：`model.dragId != nil && model.dragScope` 属于列表。
- [ ] 拖动时用分组架替换输入栏，两者共用 `glassEffectID("composer", in: ns)`。
- [ ] 分组架：
  - 胶囊，高 48，水平内边距 22；组名用 Serif 14 Semibold。
  - 每个组名都是 `onDrop(GroupDrop)` 的目标；悬停目标为 ink，其余 faint。
  - 最右侧“＋ 新分组”：落下后新建分组，并把任务移进去。
- [ ] 如果第一轮来不及做，可以跳过，**不影响其他项验收**；但要在 PR 里说明。

### P3 · 其他视图

**2.9 `PanelMotion.swift` · `FloatingBubble`**

- [ ] 删除两个 `Circle`：track（`rule` 2.5）和 trim（accent 3）。
- [ ] 分组面板：组名前两字改为 Serif 15 Semibold（原来是 Sans 12）。
- [ ] 数字由 Sans 20 `.bold` 改为 `.semibold`，加 `.monospacedDigit()`。
- [ ] 横条：
  - 文字改为两行：下一件任务（13 Medium）+“组 · 到期”（12 muted）。
  - 如果 `title` 只有一行数据，就保持一行。
- [ ] 球体玻璃保持 `.interactive()`（这是唯一允许 interactive 的常驻元素）。

**2.10 `RangeCalendar.swift`**

- [ ] 删除端点的 `Circle().fill(accent).frame(24)`，以及“有任务”的 `RoundedRectangle 6×2` 标记（约第 78、82 行）。
- [ ] 日期颜色和字重：

| 状态 | 颜色 | 字重 |
|---|---|---|
| 普通 | muted | regular |
| 有任务 | ink | regular |
| 今天 | ink | semibold |
| 区间内 | accent | regular |
| 端点 / 单选 | accent | semibold |
| 他月 | faint | regular |

- [ ] 他月不再用 `opacity(0.6)`，直接用 faint 色。
- [ ] 快捷项（第 43 行一带）：选中改为 ink + Medium，其余 faint。

**2.11 `ViewsWindow.swift`**

- [ ] `DotistGlassTabs` 在 P1 已改为纯文字切换，这里只检查效果。
- [ ] 日期头的今天 / 选中日胶囊底（约第 125、211 行）：
  - 删除 `.background(Capsule()…)`。
  - 今天：accent + semibold；选中：ink + semibold；其余：ink + regular。
- [ ] `DotistActionStyle` 的三个用法（约第 172、201、300 行），随 P1 一起变成纯文字或纯图标按钮。
- [ ] 卡片 `surface` 底（约第 485 行）、甘特条（约第 651、689 行）是**内容容器和数据图形**，不属于选中态，保留。

**2.12 `GroupManager.swift`、`TagManager.swift`、`CommandPalette.swift`**

- [ ] GroupManager 的“新分组”输入框（约第 48 行）：
  - 删除 `.background(surface).cornerRadius(8)`。
  - 改为与列表一致的一行：正文对齐 42（`.padding(.leading, 26)`），占位文字 faint。
- [ ] TagManager：检查同类写法，按同样规则修改。
- [ ] CommandPalette：
  - 搜索框底（约第 52 行，`ConcentricRectangle … rule.opacity(0.35)`）删除，改为纯输入加下方 0.5pt `rule` 分隔线。
  - 结果行的当前项改为 ink + Medium、其余 muted，不加底。
  - 图标换成 SF Symbols（见 2.2）。

## 3. 验收清单

逐项截图比对设计系统里的卡片：Panel、Alignment、Header、TitleMenu、GroupHeader、TaskRow、InlineEdit、DragAndDrop、Composer、UndoToast、Bubble、CalendarPopover、Icons。

- [ ] 全局搜索以下关键词，确认在面板和弹层的选中、悬停、焦点场景中都没有残留：
  - `cornerRadius(` + `surface`
  - `Capsule().fill(`
  - `Circle().fill(` 用作标记的情况
  - `.trim(`
  - `strikethrough`
  - `opacity(0.45`
- [ ] 浅色和深色两种模式下，日期范围的选中项都一眼可辨（深色 faint 已改为 `0x8e8e96`）。
- [ ] 打开辅助功能里的**提高对比度**、**减少透明度**、**减少动态效果**，逐一检查：
  - 面板变为 paper 实色。
  - 文字层级仍然成立。
  - 动效只剩淡入淡出。
- [ ] 截图叠加网格检查：标题、日期、组名、勾选圆左缘落在 16；正文落在 42；子任务正文落在 64；元信息和最右图标的字形右缘落在 348。
- [ ] 编辑一条任务时，文字不发生任何位移（可叠图对比）。
- [ ] 有 1 个、3 个、13 个子任务的父任务，勾选圆完全一样，进度只在“1/3 ⌄”里体现。
- [ ] 悬浮球在剩余 0、5、99 件时显示正确，没有环。
- [ ] 键盘：Tab / ↑↓ 移动焦点时能看清当前项（accent 描边或文字），并且没有灰底。
- [ ] 中、英、日、繁四种界面语言下，标题菜单、日期行、输入栏都不截断，也不换行。截断时使用省略号。

## 4. 不在本次范围

- 分组切换的 ⌘1…⌘9 快捷键。
- 设置窗口的视觉调整：保留系统 `Picker(.segmented)`，它是系统控件。
- App 图标、菜单栏图标（已定稿，见 Logo 卡片）。
- 数据、同步、MCP 相关的任何改动。
