撤销提示：删除任务后浮在输入栏上方的一块玻璃胶囊，4 秒后淡出。

**SwiftUI**：`MainWindow.body` 中的 `if let undo = model.undo`。

- `.glassEffect(.regular, in: .capsule)`，高 36，左 padding 16，右 padding 6。
- 浮在输入栏顶线上方 12pt，用 overlay，不占列表空间。
- 与输入栏放在同一个 `GlassEffectContainer(spacing: 12)` 里。
- 文案“已删除“{title}””：Sans 13，ink-muted，标题过长时截断。
- “撤销”：Sans 13 Medium，accent。
- 关闭按钮：`xmark` 11pt / 22×22。
- 替换现在的 `surface + cornerRadius(8)` 底块。
