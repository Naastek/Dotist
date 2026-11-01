组头是列表里的“章名”：Serif 15 的组名，后面紧跟数量；操作只在悬停时出现。

**SwiftUI**：`MainWindow.allGroups` 的组头 `HStack`，以及 `todaySection`。

- 布局：`HStack(alignment: .firstTextBaseline, spacing: 6)`，高 30，顶部 4。
- 组名：Serif 15/22 Semibold，颜色 **ink**（原来是 muted）。数量：Sans 12，ink-faint，紧跟组名，不再放在最右侧。
- 悬停时右侧出现两个操作：`arrow.up.right.square`（在独立面板中打开）和 `plus`（添加任务）。规格 11pt / 22×22，颜色 ink-faint，字形右缘对齐 348。
- 空组：只保留这一行，组名改为 ink-faint，数量显示 0。删除“还没有任务”和“先放进 Inbox，稍后再整理”两句提示。
- 今天视图里的“已逾期”“今天”两个分区名使用同一组件；“已逾期”的组名和数量都用 danger。
- “接下来 7 天”“已完成”这类折叠行使用 TaskRow 的折叠行样式，不使用组头样式。
