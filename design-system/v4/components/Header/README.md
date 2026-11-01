面板的两行导航：第一行是“标题即分组”的标题菜单和四个工具图标，第二行是日期范围，有标签时再加一行标签。

**SwiftUI**：`MainWindow.header`、`dateFilters`、`tagBar`。`DraggableFilterButton` 改为 `ScopeButton`。

**第一行（高 44，padding 左 16 / 右 10）**
- 标题：Serif 18/24 Semibold，后接 9pt `chevron.down`（ink-faint）。整体是原生 `Menu`，见 TitleMenu。
- 工具图标依次为搜索、视图、更多（⋯）、收起，规格是 14pt / 28×28，颜色 ink-muted，悬停 ink。
- 图钉、锁定收进“更多”菜单，不再是悬停才出现的按钮。
- Logo 不再兼任搜索按钮，搜索使用 `magnifyingglass`。

**第二行（高 30，padding 左 16 / 右 11，底 4）**
- 范围间距 16，全部用 Sans 13/20。
- 选中：ink + Medium；未选中：ink-faint + Regular；悬停：ink-muted。
- 每个槽位的宽度按 Medium 字重量好后固定，切换时不抖动。
- 取消按距离衰减的字号和透明度。
- 最右侧是日历按钮，13pt / 24×24。设了自定义区间时，日历图标变为 accent。

**标签行（有标签时出现，高 24）**
- Sans 12，间距 14。
- 选中：ink + Medium，未选中：ink-faint。
- 最右侧放“管理…”。

**禁用**：选中项下划线、胶囊底、字号放大。
