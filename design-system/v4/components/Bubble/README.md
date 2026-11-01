悬浮球是面板收起后的形态，只显示剩余的件数；悬停时，同一块玻璃横向拉伸成横条，显示下一件事。

**SwiftUI**：`PanelMotion.swift` 中的 `FloatingBubble`。

**悬浮球**
- 直径 48，`.glassEffect(.regular.interactive(), in: .circle)`。
- **删除** track 圆（`rule` 2.5）和 trim 进度圆（accent 3），不再有进度环。
- 中央：剩余数用 Sans 20 Semibold，ink，tabular-nums。
- 全部完成时显示 `checkmark` 20pt semibold，accent。
- 分组面板显示组名前两个字，Serif 15 Semibold（现在是 Sans 12）。

**横条**
- 宽 250、高 48，与悬浮球共用 `glassEffectID`。
- 文字区左 padding 18：第一行是下一件任务（Sans 13 Medium，ink），第二行是“组 · 到期”（Sans 12，ink-muted）。
- 数字保持在 48 的圆位置不动。悬浮球在屏幕左侧时，横条镜像展开。
