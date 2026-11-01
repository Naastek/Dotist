任务行由三部分组成：勾选圆、正文和行尾元信息。悬停或键盘焦点时，元信息的位置换成三个操作；行本身永远没有底色。

**SwiftUI**：`MainWindow.taskRow`。

**结构**：`HStack(alignment: .firstTextBaseline, spacing: 8)` = 勾选列 18×20 + 正文（Sans 13/20）+ 元信息。

**勾选圆**
- 任务直径 16，子任务直径 13（勾选列宽 14），描边 1.25pt，颜色 `check-stroke`。
- 完成：accent 实心，中间是 9pt heavy 的 `checkmark`，颜色 on-accent。
- 键盘焦点：描边变为 accent。
- **不再画任何进度弧或进度环**，无论有几个子任务。

**元信息**（Sans 12/20，间距 8，右缘对齐 348）
- 跨组视图里的组名：Serif 12 Semibold，ink-faint。
- 到期日：今天用 accent，逾期用 danger，其他用 ink-muted。
- 子任务计数“1/3 ⌄”：ink-faint，后接 8pt 箭头。这是唯一的子任务进度表达，点击即展开或收起。
- 正文里的标签：Sans 12，ink-faint；当前筛选中的标签用 ink + Medium（不用 accent）。

**悬停与焦点**
- 元信息隐藏，原位置出现三个操作：`plus`（添加子任务）、`calendar`（到期）、`xmark`（删除）。规格 11pt / 22×22，ink-muted，最右字形对齐 348。
- 行没有底色，也不用系统 focus ring。

**子任务**
- 缩进 26（`.padding(.leading, 26)`），行高 ≥ 28，上下 4。
- 子任务勾选圆左缘落在 42，正文落在 64。
- 新增子任务的输入框缩进 48，使正文对齐 64；原来是 52。

**已完成**
- 文字 ink-faint，**去掉删除线**。
- “已完成 3”折叠行：箭头放在 18 宽的勾选列里，文字 Sans 12，ink-faint，行高 28。

**禁用**：圆角底板悬停或选中、`DotistFocusRing` 的灰底、进度弧、前置小圆点。
